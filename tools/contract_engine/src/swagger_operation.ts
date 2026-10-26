import {escape,SourceError} from './document';
import type {ReferenceGraph} from './reference_graph';
import {swaggerFileSchemas} from './swagger_file';
import {exampleRepresentation} from './example_representation';

export type LocatedSource={resource:string;pointer:string;generation:number;range:number[]};
type Locate=(resource:string,pointer:string)=>LocatedSource;

/** OAS 2.0 §6.4.1/6.4.7: operation overrides are independent of Path Items.
 * These located execution values never become authored 3.x objects. */
export function swaggerMedia(graph:ReferenceGraph,resource:string,pointer:string,field:'consumes'|'produces'):string[] {
    const operation=graph.docs.get(resource)!.dataNode(pointer)!,root=graph.docs.get(graph.root)!;
    const selected=operation.children.has(field)?operation.value[field]:root.root.value[field];
    if(selected===undefined||Array.isArray(selected)&&!selected.length)return ['*/*'];
    if(!Array.isArray(selected)||selected.some(value=>typeof value!=='string'))throw new SourceError('request.media','The effective Swagger '+field+' declaration must be a string array');
    return selected;
}
export function swaggerServers(graph:ReferenceGraph,resource:string,pointer:string,locate:Locate) {
    const root=graph.docs.get(graph.root)!,operation=graph.docs.get(resource)!.dataNode(pointer)!,retrieval=graph.retrievals.get(graph.root)!;
    const base=new URL(retrieval),host=root.root.value.host??(base.protocol==='http:'||base.protocol==='https:'?base.host:undefined);
    const declared=operation.children.has('schemes')?operation.value.schemes:root.root.value.schemes;
    const schemes=declared?.length?declared:[base.protocol==='http:'||base.protocol==='https:'?base.protocol.slice(0,-1):undefined];
    const path=root.root.value.basePath??'/';
    return schemes.map((scheme:string|undefined)=>({url:host?(scheme?scheme+':':'')+'//'+host+path:path,variables:{},base:retrieval,
        origin:operation.children.has('schemes')?'operation':'root',source:locate(root.id,''),
        sources:['host','basePath','schemes'].filter(field=>root.root.children.has(field)).map(field=>locate(root.id,'/'+field))}));
}
export function swaggerFlat(value:any,source:LocatedSource) {
    const collectionFormat=value.collectionFormat??'csv';
    return {family:'2.0',type:value.type,collectionFormat,
        items:value.items?{type:value.items.type,collectionFormat:value.items.collectionFormat??'csv',items:swaggerItems(value.items.items)}:undefined,
        style:({ssv:'spaceDelimited',tsv:'tabDelimited',pipes:'pipeDelimited'} as Record<string,string>)[collectionFormat]??(value.in==='query'||value.in==='formData'?'form':'simple'),
        explode:collectionFormat==='multi',schema:{...source,kind:'schema',file:value.type==='file',unconstrained:false}};
}
function swaggerItems(value:any):any {
    return value?{type:value.type,collectionFormat:value.collectionFormat??'csv',items:swaggerItems(value.items)}:undefined;
}
/** Native response examples are media-keyed data, including null/false/zero.
 * No Reference Object interpretation is applied inside the payload. */
export function swaggerResponseContent(graph:ReferenceGraph,resource:string,pointer:string,media:string[],locate:Locate) {
    const doc=graph.docs.get(resource)!,node=doc.dataNode(pointer)!,value=node.value;
    const examples=doc.dataNode(pointer+'/examples');
    const names=[...new Set([...media,...(examples?.children.keys()??[])])];
    const scope=graph.scopes.get(resource+'#'+pointer+'/schema');
    let file=false,fileIssue:{code:string;message:string;source:LocatedSource}|undefined;
    if(scope)try{file=swaggerFileSchemas(graph)(scope)!==undefined;}catch(error){
        if(!(error instanceof SourceError)||error.kind!=='unsupported')throw error;
        fileIssue={code:error.code,message:error.message,source:locate(scope.resource,scope.pointer)};
    }
    return names.map(mediaType=>{
        const examplePointer=pointer+'/examples/'+escape(mediaType),entry=doc.dataNode(examplePointer);
        const representation=entry?exampleRepresentation('swagger-response',entry.value,mediaType):undefined;
        const example=entry?{mediaType,source:locate(resource,examplePointer),raw:representation==='serialized'?entry.value:doc.dataJson(examplePointer),text:typeof entry.value==='string'?entry.value:doc.dataJson(examplePointer),dataKind:typeof entry.value==='string'?'string':entry.kind,representation,level:'media'}:undefined;
        return {mediaType,source:locate(resource,pointer),definition:locate(resource,pointer),schema:Object.hasOwn(value,'schema')?{...locate(resource,pointer+'/schema'),kind:'schema',file,...(fileIssue?{fileIssue}:{}),unconstrained:Object.keys(value.schema??{}).length===0}:undefined,example,examples:example?[example]:[]};
    });
}
