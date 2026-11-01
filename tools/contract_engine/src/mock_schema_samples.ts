import {schemaContext} from './schema_context';
import {createHash,randomInt} from 'node:crypto';
import {SourceError,type Node} from './document';
import {record} from './engine_worker_client';
import {supportedSchemaDialect,type ReferenceGraph,type GraphTarget} from './reference_graph';
import {modernFamily} from './specification';
import {capturedMockResponseMedia,schemaLocation,type SchemaLocation,type SourceLocation,type NativeRuntimeInstance,type NativeRuntimeCheck} from './mock_projection';
import {SchemaSampleCandidates} from './schema_sample_candidates';

export const mockSampleProducer=Object.freeze({name:'busyapi-native-schema-samples',version:'2'});
type Sample={raw:string;source:SourceLocation};
type Evaluate=(instances:NativeRuntimeInstance[],signal:AbortSignal)=>Promise<NativeRuntimeCheck>;

/** Authored values are suggestions, not a second schema evaluator. Every
 * candidate is proved against the original whole schema before selection.
 * Numeric values move only through the source document's exact JSON view. */
export class MockSchemaSamples {
    private readonly references:Map<string,ReferenceGraph['references']>;
    private readonly proved=new Map<string,readonly Sample[]>();
    private readonly identities:ReadonlyMap<string,string>;
    private readonly shapes:SchemaSampleCandidates;

    constructor(private readonly graph:ReferenceGraph,private readonly evaluate:Evaluate,private readonly revision:string) {
        this.shapes=new SchemaSampleCandidates(graph,'mock.sample');
        this.identities=new Map([...graph.docs].map(([id,doc])=>[id,createHash('sha256').update(doc.text).digest('hex')]));
        this.references=new Map();
        for(const edge of graph.references)if(edge.kind==='schema'&&!edge.connection) {
            const key=JSON.stringify([edge.resource,edge.pointer]);
            this.references.set(key,[...(this.references.get(key)??[]),edge]);
        }
    }

    private candidates(schema:SchemaLocation,dynamic:boolean):{samples:Sample[];limit?:SourceLocation} {
        const output:Sample[]=[],seen=new Set<string>(),values=new Set<string>();
        let bytes=0,limit:SourceLocation|undefined;
        const root=this.graph.docs.get(schema.resource)?.dataNode(schema.pointer);
        const fail=(message:string,node:Node|undefined=root,source:SchemaLocation=schema):never=>{
            const range=node?.range??[0,0];
            throw new SourceError('mock.sample.limit',message,range,'unsupported',{...source,range});
        };
        const append=(resource:string,pointer:string)=>{
            const doc=this.graph.docs.get(resource)!,node=doc.dataNode(pointer);
            if(!node)return true;
            const raw=doc.dataJson(pointer);
            if(values.has(raw))return true;
            if(output.length>=256||bytes+Buffer.byteLength(raw)>8*1024*1024) {
                limit??={resource,pointer:node.pointer,range:node.range};return false;
            }
            values.add(raw);bytes+=Buffer.byteLength(raw);
            output.push({raw,source:{resource,pointer:node.pointer,range:node.range}});
            return true;
        };
        const visit=(target:GraphTarget,depth:number)=>{
            const key=JSON.stringify([target.resource,target.pointer]);
            if(seen.has(key))return;
            if(depth>=128||seen.size>=2048)fail('Captured schema sample traversal exceeds its bounded depth or work');
            seen.add(key);
            const scope=schemaContext(this.graph,target.resource,target.pointer);
            if(!scope||!supportedSchemaDialect(scope)) {
                const node=this.graph.docs.get(target.resource)?.dataNode(target.pointer),range=node?.range??[0,0];
                throw new SourceError('mock.sample.dialect','Schema sample selection requires the captured supported dialect',range,'unsupported',{resource:target.resource,pointer:target.pointer,range});
            }
            const doc=this.graph.docs.get(target.resource)!,node=doc.dataNode(target.pointer);
            if(!node||!record(node.value))return;
            const edges=this.references.get(key)??[];
            const follow=()=>{
                for(const edge of edges)if(['$ref','$dynamicRef'].includes(edge.keyword)&&edge.resolution==='resolved')
                    visit({resource:edge.targetResource!,pointer:edge.targetPointer!,kind:'schema'},depth+1);
            };
            // Legacy Schema references are Reference Objects; sibling examples
            // and defaults do not become candidates (OAS 3.0 §4.7.23.1).
            if(this.graph.referenceObject(node.value,scope)){follow();return;}
            const modern=modernFamily(scope.family);
            if(!dynamic)for(const keyword of ['example','default'])
                if(node.children.has(keyword))append(target.resource,target.pointer+'/'+keyword);
            if(modern&&node.children.has('const'))append(target.resource,target.pointer+'/const');
            for(const keyword of ['enum',...(!dynamic&&modern?['examples']:[])]) {
                const array=doc.dataNode(target.pointer+'/'+keyword);
                if(array?.kind==='array')for(const index of array.children.keys())
                    if(!append(target.resource,target.pointer+'/'+keyword+'/'+index))break;
            }
            follow();
            for(const keyword of ['allOf',...(scope.family!=='2.0'?['oneOf','anyOf']:[])]) {
                const array=doc.dataNode(target.pointer+'/'+keyword);
                if(array?.kind==='array')for(const index of array.children.keys())
                    visit({...target,pointer:target.pointer+'/'+keyword+'/'+index},depth+1);
            }
        };
        visit({...schema,kind:'schema'},0);
        return {samples:output,...(limit?{limit}:{})};
    }

    private async prove(candidates:Sample[],schema:SchemaLocation,dynamic:boolean,proved:readonly Sample[]|undefined,signal:AbortSignal):Promise<Sample|undefined> {
        if(signal.aborted)throw new SourceError('cancelled','Mock schema sample selection was cancelled');
        const offset=dynamic&&candidates.length?randomInt(candidates.length):0;
        const ordered=[...candidates.slice(offset),...candidates.slice(0,offset)];
        const known=ordered[0]&&proved?.find(sample=>sample.raw===ordered[0].raw);
        if(known)return known;
        let selected:Sample|undefined;
        if(ordered.length) {
            const checked=await this.evaluate([{
                subject:'response-body',location:'mock-schema-sample',schema,
                text:ordered[0].raw,...(ordered.length>1?{alternatives:ordered.slice(1).map(sample=>sample.raw)}:{}),
            }],signal);
            if(signal.aborted)throw new SourceError('cancelled','Mock schema sample selection was cancelled');
            if(!checked.complete) {
                const source=ordered[0].source;
                throw new SourceError('mock.sample.unchecked','The original schema could not completely evaluate captured sample candidates',source.range,'unsupported',source);
            }
            const [evaluation]=checked.evaluations;
            if(checked.evaluations.length!==1||evaluation.subject!=='response-body'||evaluation.location!=='mock-schema-sample'||!evaluation.complete)
                throw new SourceError('mock.validation.protocol','The schema sample proof omitted or repeated its captured candidate group');
            if(evaluation.valid) {
                const index=ordered.length===1?0:evaluation.chosen;
                if(typeof index!=='number'||!Number.isSafeInteger(index)||index<0||index>=ordered.length)
                    throw new SourceError('mock.validation.protocol','The schema sample proof omitted a valid original candidate identity');
                selected=ordered[index];
            }
        }
        return selected;
    }

    async response(plan:unknown,status:string,actual:string,dynamic:boolean,signal:AbortSignal):Promise<string|undefined> {
        if(signal.aborted)throw new SourceError('cancelled','Mock schema sample selection was cancelled');
        const rawMedia=capturedMockResponseMedia(plan,status,actual);
        if(!rawMedia)return;
        // Static media examples override schema suggestions. Explicit dynamic
        // generation asks for constrained candidates instead of authored data.
        // Schema-origin choices still require this owner's exact-value proof;
        // they are not authored Media Type overrides for the Prism adapter.
        if(!dynamic&&rawMedia.examples.some(example=>example.origin!=='schema'))return;
        const schema=schemaLocation(rawMedia.schema);
        if(!schema)return;
        const scope=schemaContext(this.graph,schema.resource,schema.pointer);
        const specification=this.graph.specifications.get(schema.resource)??this.graph.specifications.get(this.graph.root);
        const key=JSON.stringify([mockSampleProducer.version,this.revision,this.graph.root,
            schema.resource,this.identities.get(schema.resource),schema.pointer,
            specification?.declaredVersion,scope?.family,scope?.dialect,scope?.base,scope?.resourcePointer,dynamic]);
        const proved=this.proved.get(key);
        if(proved!==undefined&&(!dynamic||!proved.length))return proved[0]?.raw;
        const authored=this.candidates(schema,dynamic);
        let limit=authored.limit;
        let selected=await this.prove(authored.samples,schema,dynamic,proved,signal);
        if(signal.aborted)throw new SourceError('cancelled','Mock schema sample selection was cancelled');
        if(!selected&&!limit) {
            const nested=this.shapes.candidates(schema,location=>this.candidates(location,dynamic),authored.samples);
            limit=nested.limit;
            selected=await this.prove(nested.samples,schema,dynamic,proved,signal);
        }
        if(signal.aborted)throw new SourceError('cancelled','Mock schema sample selection was cancelled');
        if(!selected&&limit)
            throw new SourceError('mock.sample.limit','No captured candidate was proved within the 256-candidate / 8 MiB sample budget',limit.range,'unsupported',limit);
        if(this.proved.size>=128)this.proved.clear();
        this.proved.set(key,selected
            ?proved?.some(sample=>sample.raw===selected.raw)?proved:[...(proved??[]),selected]
            :[]);
        return selected?.raw;
    }
}
