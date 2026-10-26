import {escape,SourceError,type Range} from './document';
import {ReferenceGraph,supportedSchemaDialect,type GraphReference,type GraphTarget} from './reference_graph';

type MultipartSource={resource:string;pointer:string;range:number[]};
export type MultipartTransfer={encoding?:string;schemaEncoded:boolean;instanceEncoding?:'octets';instanceSource?:MultipartSource;source?:MultipartSource};
export type MultipartHeaderCandidate={name:string;values:string[];implicit:boolean;literalExample:boolean;source:GraphTarget}&({schema:GraphTarget;header?:never}|{header:GraphTarget;schema?:never});
export type MultipartSchemaStep={property:string}|{item:number|undefined};

/** MIME codecs implemented by the native transport. This is a serialization
 * capability list, not a restriction on JSON Schema content annotations. */
export const multipartTransferEncodings=['binary','7bit','8bit','base64','quoted-printable','base64url','base16','base32','base32hex','identity'] as const;
export const supportsMultipartTransfer=(encoding:string):boolean=>multipartTransferEncodings.some(value=>value===encoding.toLowerCase());

/** Contextual projection of named multipart parts. References and Schema Object
 * boundaries belong to the captured graph; transport never resolves them.
 * OAS 3.0 §4.7.15.3; 3.1 §4.8.15.3; 3.2 §4.15.4.2. */
export class MultipartEncoding {
    private edges:Map<string,GraphReference>;
    constructor(private graph:ReferenceGraph){
        this.edges=new Map(graph.references.map(edge=>[JSON.stringify([edge.resource,edge.pointer,edge.keyword]),edge]));
    }

    failure(code:string,message:string,target:Pick<GraphTarget,'resource'|'pointer'>,unsupported=false):never {
        const node=this.graph.docs.get(target.resource)?.dataNode(target.pointer),range:Range=node?.range??[0,0];
        throw new SourceError(code,message+' at '+target.pointer,range,unsupported||code.endsWith('.unsupported')?'unsupported':undefined,{resource:target.resource,pointer:node?.pointer??target.pointer,range});
    }

    follow(target:GraphTarget,kind:string):GraphTarget {
        const seen=new Set<string>();
        for(let depth=0;depth<128;depth++){
            const key=JSON.stringify([target.resource,target.pointer]);
            if(seen.has(key))this.failure('request.reference.cycle','A multipart declaration contains a reference cycle',target);
            seen.add(key);
            const node=this.graph.docs.get(target.resource)?.dataNode(target.pointer);
            if(!node)this.failure('request.reference','A multipart declaration is unavailable',target);
            if(typeof node.value?.$ref!=='string')return target;
            const edge=this.edges.get(JSON.stringify([target.resource,target.pointer,'$ref']));
            if(edge?.kind!==kind||edge.resolution!=='resolved')this.failure('request.reference','A multipart reference is unresolved',target);
            target={resource:edge.targetResource!,pointer:edge.targetPointer!,kind};
        }
        return this.failure('limit.request.references','Multipart reference depth exceeds 128',target);
    }

    /** Only annotations that apply to the same part instance participate. No
     * keywords are read from payload examples or from another schema dialect. */
    schemaEncoding(schema:GraphTarget,name:string,array:boolean,instanceKind?:'string'|'other'):MultipartTransfer {
        return this.schemaPathEncoding(schema,[{property:name},...(array?[{item:undefined}]:[])],instanceKind);
    }

    schemaPathEncoding(schema:GraphTarget,path:MultipartSchemaStep[],instanceKind?:'string'|'other'):MultipartTransfer {
        // Content annotations and the legacy binary/byte formats only describe
        // string instances. They cannot change an object's MIME representation.
        if(instanceKind==='other')return {schemaEncoded:false};
        const values=new Map<string,GraphTarget>();
        let binary:GraphTarget|undefined;
        let work=0;
        const visit=(target:GraphTarget,path:MultipartSchemaStep[],active:ReadonlySet<string>,conditional=false):void=>{
            if(++work>2048)this.failure('limit.request.encoding','Multipart schema inspection exceeds 2048 locations',target);
            const key=JSON.stringify([target.resource,target.pointer,path]);
            if(active.has(key))return;
            active=new Set(active).add(key);
            const node=this.graph.docs.get(target.resource)?.dataNode(target.pointer),scope=this.graph.scopes.get(target.resource+'#'+target.pointer);
            if(!scope||!supportedSchemaDialect(scope))this.failure('request.multipart.dialect.unsupported','The part schema has no supported captured dialect',target);
            const value=node?.value;
            if(typeof value==='boolean')return;
            if(!value||typeof value!=='object'||Array.isArray(value))this.failure('request.multipart.schema','The part schema is unavailable',target);
            if(typeof value.$dynamicRef==='string')this.failure('request.multipart.encoding.unsupported','Dynamic part annotations require evaluation before serialization',target);
            if(typeof value.$ref==='string'){
                const edge=this.edges.get(JSON.stringify([target.resource,target.pointer,'$ref']));
                if(edge?.kind!=='schema'||edge.resolution!=='resolved')this.failure('request.reference','A multipart schema reference is unresolved',target);
                visit({resource:edge.targetResource!,pointer:edge.targetPointer!,kind:'schema'},path,active,conditional);
                if(scope.family==='3.0')return;
            }
            for(const [index]of (Array.isArray(value.allOf)?value.allOf:[]).entries())
                visit({...target,pointer:target.pointer+'/allOf/'+index},path,active,conditional);
            for(const keyword of ['anyOf','oneOf'])for(const [index]of (Array.isArray(value[keyword])?value[keyword]:[]).entries())
                visit({...target,pointer:target.pointer+'/'+keyword+'/'+index},path,active,true);
            for(const keyword of ['if','then','else'])if(value[keyword]!==undefined)
                visit({...target,pointer:target.pointer+'/'+keyword},path,active,true);
            for(const key of Object.keys(value.dependentSchemas??{}))
                visit({...target,pointer:target.pointer+'/dependentSchemas/'+escape(key)},path,active,true);
            if(path.length){
                const [field,...rest]=path;
                if('item' in field){
                    if(field.item!==undefined&&Array.isArray(value.prefixItems)&&field.item<value.prefixItems.length)
                        visit({...target,pointer:target.pointer+'/prefixItems/'+field.item},rest,active,conditional);
                    else if(value.items!==undefined&&!Array.isArray(value.items))visit({...target,pointer:target.pointer+'/items'},rest,active,conditional);
                }else if(Object.hasOwn(value.properties??{},field.property))visit({...target,pointer:target.pointer+'/properties/'+escape(field.property)},rest,active,conditional);
                return;
            }
            const encoding=scope.family==='3.0'?value.format==='byte'?'base64':undefined:typeof value.contentEncoding==='string'?value.contentEncoding:undefined;
            if(scope.family==='3.0'&&value.format==='binary'){
                if(conditional)this.failure('request.multipart.encoding.unsupported','Conditional binary part representations need an explicit part-shape selection',target);
                binary={...target,pointer:target.pointer+'/format'};
            }
            if(encoding!==undefined){
                if(conditional)this.failure('request.multipart.encoding.unsupported','Conditional part encodings need an explicit serialized representation',target);
                values.set(encoding,{...target,pointer:target.pointer+(scope.family==='3.0'?'/format':'/contentEncoding')});
            }
        };
        visit(schema,path,new Set());
        if(values.size>1||binary&&values.size)this.failure('request.multipart.encoding.undefined','Applicable part schemas specify conflicting binary or encoded representations',binary??schema,true);
        const first=values.entries().next().value;
        if(!first){
            if(!binary)return {schemaEncoded:false};
            const source={resource:binary.resource,pointer:binary.pointer,range:this.graph.docs.get(binary.resource)!.dataNode(binary.pointer)!.range};
            return {schemaEncoded:false,instanceEncoding:'octets',instanceSource:source,source};
        }
        const [encoding,source]=first;
        return {encoding,schemaEncoded:true,source:{resource:source.resource,pointer:source.pointer,range:this.graph.docs.get(source.resource)!.dataNode(source.pointer)!.range}};
    }

    header(media:GraphTarget,name:string,implicit:MultipartTransfer,formData=true):MultipartHeaderCandidate|undefined {
        const at=media.pointer+'/encoding/'+escape(name),value=this.graph.docs.get(media.resource)?.dataNode(at)?.value;
        if(value===undefined)return;
        if(!value||typeof value!=='object'||Array.isArray(value)||value.encoding!==undefined||value.prefixEncoding!==undefined||value.itemEncoding!==undefined)
            this.failure('request.multipart.encoding','This part requires nested multipart serialization',{...media,pointer:at},true);
        const headers=value.headers;
        if(headers===undefined)return;
        if(!headers||typeof headers!=='object'||Array.isArray(headers))this.failure('request.multipart.headers','Part headers must be a Header Object map',{...media,pointer:at+'/headers'});
        let candidate:MultipartHeaderCandidate|undefined;
        for(const key of Object.keys(headers)){
            const source={...media,pointer:at+'/headers/'+escape(key),kind:'header'};
            if(key.toLowerCase()==='content-type')continue;
            if(key.toLowerCase()!=='content-transfer-encoding'){
                if(formData)this.failure('request.multipart.headers','multipart/form-data forbids this additional part header',source);
                continue;
            }
            if(candidate)this.failure('request.multipart.headers','Part header names must be unique without regard to case',source);
            const target=this.follow(source,'header'),header=this.graph.docs.get(target.resource)!.dataNode(target.pointer)!.value;
            if(header.content===undefined&&!Object.hasOwn(header,'schema'))this.failure('request.multipart.headers','The transfer header has no Schema Object',target);
            let values:string[];
            if(implicit.encoding!==undefined)values=[implicit.encoding];
            else if(typeof header.example==='string')values=[header.example];
            else{
                // Prefer a no-op transfer when permitted. Every candidate is
                // checked by the family evaluator; examples never grant validity.
                const own=header.schema,extra=[own?.const,own?.default,...(Array.isArray(own?.enum)?own.enum:[])].filter(value=>typeof value==='string');
                values=[...new Set([...extra.filter(supportsMultipartTransfer),...multipartTransferEncodings,...extra])];
            }
            candidate={name,values,...(header.content!==undefined?{header:target}:{schema:{...target,pointer:target.pointer+'/schema',kind:'schema'}}),implicit:implicit.encoding!==undefined,literalExample:typeof header.example==='string',source};
        }
        return candidate;
    }
}
