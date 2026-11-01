import {schemaContext} from './schema_context';
import {SourceError,escape,type Range} from './document';
import {record} from './engine_worker_client';
import {supportedSchemaDialect,type ReferenceGraph,type GraphTarget} from './reference_graph';
import {modernFamily} from './specification';
export type SchemaSampleLocation=Readonly<{resource:string;pointer:string}>;
export type SchemaSampleSource=Readonly<{resource:string;pointer:string;range:Range}>;
type SchemaLocation=SchemaSampleLocation;
type SourceLocation=SchemaSampleSource;

export type SchemaSample={raw:string;source:SourceLocation};
type Suggestions=(schema:SchemaLocation)=>{samples:SchemaSample[];limit?:SourceLocation};
type ObjectShape={properties:Map<string,GraphTarget[]>;required:Set<string>};

/** Bounded construction of suggestions, never schema evaluation. The caller
 * proves every completed value against the captured whole response schema. */
export class SchemaSampleCandidates {
    private readonly references=new Map<string,ReferenceGraph['references']>();
    constructor(private readonly graph:ReferenceGraph,private readonly failurePrefix='schema.sample') {
        for(const edge of graph.references)if(edge.kind==='schema'&&!edge.connection) {
            const key=JSON.stringify([edge.resource,edge.pointer]);
            this.references.set(key,[...(this.references.get(key)??[]),edge]);
        }
    }

    candidates(schema:SchemaLocation,suggestions:Suggestions,existing:readonly SchemaSample[]=[]):{samples:SchemaSample[];limit?:SourceLocation} {
        const allocated=new Set(existing.map(sample=>sample.raw));
        let work=0,bytes=[...allocated].reduce((sum,raw)=>sum+Buffer.byteLength(raw),0),limit:SourceLocation|undefined;
        const memo=new Map<string,SchemaSample[]>();
        const source=(target:GraphTarget):SourceLocation=>{
            const node=this.graph.docs.get(target.resource)?.dataNode(target.pointer);
            return {resource:target.resource,pointer:target.pointer,range:node?.range??[0,0]};
        };
        const step=(target:GraphTarget)=>{
            if(work>=32768){limit??=source(target);return false;}
            work++;
            return true;
        };
        const admit=(raw:string,origin:SourceLocation)=>{
            if(allocated.has(raw))return true;
            if(bytes+Buffer.byteLength(raw)>8*1024*1024){limit??=origin;return false;}
            bytes+=Buffer.byteLength(raw);allocated.add(raw);return true;
        };
        const resolved=(target:GraphTarget)=>
            (this.references.get(JSON.stringify([target.resource,target.pointer]))??[])
                .filter(edge=>['$ref','$dynamicRef'].includes(edge.keyword)&&edge.resolution==='resolved')
                .map((edge):GraphTarget=>({resource:edge.targetResource!,pointer:edge.targetPointer!,kind:'schema'}));
        const locations=(target:GraphTarget,seen=new Set<string>(),depth=0):GraphTarget[]=>{
            const key=JSON.stringify([target.resource,target.pointer]);
            if(seen.has(key))return [];
            if(depth>=128||!step(target)){limit??=source(target);return [];}
            seen.add(key);
            const scope=schemaContext(this.graph,target.resource,target.pointer);
            if(!scope||!supportedSchemaDialect(scope)) {
                const origin=source(target);
                throw new SourceError(this.failurePrefix+'.dialect','Nested sample construction requires the captured supported dialect',origin.range,'unsupported',origin);
            }
            const node=this.graph.docs.get(target.resource)?.dataNode(target.pointer);
            if(!node||!record(node.value))return [];
            const edges=resolved(target);
            if(this.graph.referenceObject(node.value,scope))return edges.flatMap(value=>locations(value,seen,depth+1));
            const result=[target,...edges.flatMap(value=>locations(value,seen,depth+1))];
            const allOf=node.children.get('allOf');
            if(allOf?.kind==='array')for(const index of allOf.children.keys())
                result.push(...locations({...target,pointer:target.pointer+'/allOf/'+index},seen,depth+1));
            return result;
        };
        const build=(target:GraphTarget,path:Set<string>,depth:number):SchemaSample[]=>{
            const key=JSON.stringify([target.resource,target.pointer]);
            if(path.has(key)){limit??=source(target);return [];}
            const cached=memo.get(key);if(cached)return cached;
            if(depth>=128||!step(target)){limit??=source(target);return [];}
            const origin=source(target),output:SchemaSample[]=[],values=new Set<string>();
            const add=(raw:string,candidateSource=origin)=>{
                if(values.has(raw))return true;
                if(depth===0&&existing.some(sample=>sample.raw===raw))return true;
                if(output.length>=(depth===0?256-existing.length:256)||!step(target)||!admit(raw,candidateSource)){limit??=candidateSource;return false;}
                values.add(raw);output.push({raw,source:candidateSource});return true;
            };
            const authored=suggestions(target);
            limit??=authored.limit;
            for(const candidate of authored.samples)if(!add(candidate.raw,candidate.source))break;
            const next=new Set(path).add(key),scopes=locations(target);
            const object:ObjectShape={properties:new Map(),required:new Set()};
            let hasObject=false;
            for(const location of scopes) {
                if(!step(location))break;
                const doc=this.graph.docs.get(location.resource)!,node=doc.dataNode(location.pointer)!;
                const value=node.value,scope=schemaContext(this.graph,location.resource,location.pointer)!;
                const types=typeof value.type==='string'?[value.type]:Array.isArray(value.type)?value.type:[];
                const properties=node.children.get('properties');
                if(types.includes('object')||properties||node.children.has('required'))hasObject=true;
                if(properties?.kind==='object')for(const name of properties.children.keys()) {
                    const property={...location,pointer:location.pointer+'/properties/'+escape(name)};
                    if(!step(property))break;
                    object.properties.set(name,[...(object.properties.get(name)??[]),property]);
                }
                if(Array.isArray(value.required))for(const name of value.required) {
                    if(!step(location))break;
                    if(typeof name==='string')object.required.add(name);
                }
                for(const keyword of ['oneOf','anyOf']) {
                    const array=node.children.get(keyword);
                    if(scope.family!=='2.0'&&array?.kind==='array')for(const index of array.children.keys())
                        for(const candidate of build({...location,pointer:location.pointer+'/'+keyword+'/'+index},next,depth+1))
                            if(!add(candidate.raw,candidate.source))break;
                }
                for(const keyword of ['minimum','maximum'])if(node.children.has(keyword)) {
                    const bound=doc.dataNode(location.pointer+'/'+keyword);
                    if(bound?.kind==='number')add(doc.dataJson(bound.pointer),source({...location,pointer:bound.pointer}));
                }
                if(types.includes('string')) {
                    add('""');
                    const length=value.minLength??1;
                    if(!Number.isSafeInteger(length)||length<0||length>65536)limit??=source(location);
                    else for(const character of ['a','A','0'])add(JSON.stringify(character.repeat(length)));
                }
                if(types.some(type=>type==='number'||type==='integer'))for(const raw of ['0','1','-1'])add(raw);
                if(types.includes('boolean'))for(const raw of ['false','true'])add(raw);
                if(types.includes('null')||(scope.family==='3.0'&&typeof value.type==='string'&&value.nullable===true))add('null');
                if(types.includes('array')||node.children.has('items')||node.children.has('prefixItems')) {
                    const count=value.minItems??0;
                    if(!Number.isSafeInteger(count)||count<0||count>256){limit??=source(location);continue;}
                    const items:SchemaSample[][]=[];
                    for(let index=0;index<count;index++) {
                        const prefix=modernFamily(scope.family)?node.children.get('prefixItems'):undefined;
                        const item=prefix?.kind==='array'&&prefix.children.has(String(index))
                            ?{...location,pointer:location.pointer+'/prefixItems/'+index}
                            :node.children.has('items')?{...location,pointer:location.pointer+'/items'}:undefined;
                        const choices=item?build(item,next,depth+1):[{raw:'null',source:origin}];
                        items.push(choices);
                    }
                    if(items.some(choices=>!choices.length))continue;
                    add('['+items.map(choices=>choices[0].raw).join(',')+']');
                    let arrays=[''];
                    for(let index=0;index<items.length;index++) {
                        const combined:string[]=[],choices=items[index];
                        for(const before of arrays)for(const candidate of choices) {
                            if(combined.length>=256||!step(location)){limit??=source(location);break;}
                            const raw=before+(index?',':'')+candidate.raw;
                            if(admit(raw,source(location)))combined.push(raw);
                        }
                        arrays=combined;
                        if(!arrays.length)break;
                    }
                    for(const raw of arrays)if(!add('['+raw+']'))break;
                }
            }
            if(hasObject) {
                add('{}');
                const fields:{name:string;choices:SchemaSample[]}[]=[];
                for(const name of object.required) {
                    const properties=object.properties.get(name);
                    const choices=properties?properties.flatMap(property=>build(property,next,depth+1)):[{raw:'null',source:origin}];
                    fields.push({name,choices});
                }
                if(fields.some(field=>!field.choices.length)) {
                    memo.set(key,output);return output;
                }
                add('{'+fields.map(({name,choices})=>JSON.stringify(name)+':'+choices[0].raw).join(',')+'}');
                let objects=[''];
                for(const {name,choices} of fields) {
                    const combined:string[]=[],unique=new Set<string>();
                    for(const before of objects)for(const candidate of choices) {
                        if(combined.length>=256||!step(target)){limit??=origin;break;}
                        const raw=before+(before?',':'')+JSON.stringify(name)+':'+candidate.raw;
                        if(!unique.has(raw)&&admit(raw,origin)){unique.add(raw);combined.push(raw);}
                    }
                    objects=combined;
                }
                for(const raw of objects)if(!add('{'+raw+'}'))break;
            }
            memo.set(key,output);
            return output;
        };
        const samples=build({...schema,kind:'schema'},new Set(),0);
        return {samples,...(limit?{limit}:{})};
    }
}

