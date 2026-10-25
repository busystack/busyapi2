import {escape,segments,SourceError} from './document';
import type {GraphReference,ReferenceGraph} from './reference_graph';
import {mediaTypeOptions,mediaTypes} from './media_types';
import type {SpecificationFamily} from './specification';

export type FormBinding='urlencoded'|'multipart-named';

/** OAS 3.0 §4.7.15.3 permits named generic multipart. This policy keeps the
 * older property/name correlation; 3.2 generic multipart uses array positions. */
export function formBinding(family:SpecificationFamily,contentType:string):FormBinding|undefined {
    const essence=contentType.split(';')[0].trim().toLowerCase();
    if(essence==='application/x-www-form-urlencoded')return 'urlencoded';
    if(essence==='multipart/form-data'||essence.startsWith('multipart/')&&(family==='3.0'||family==='3.1'))return 'multipart-named';
}

export type FormShape={types?:string[];literalType?:string;format?:string;contentEncoding?:string;properties?:Record<string,FormShape>;items?:FormShape;prefixItems?:FormShape[];defaultContentType?:string};

export const formLiteralType=(shape:FormShape):string|undefined=>{
    // Literal input remains a string when a union permits strings; exact JSON
    // data input retains its own kind instead. Null-only fields use "null".
    if(shape.types?.length===1&&shape.types[0]==='null')return 'null';
    if(shape.types?.includes('string'))return 'string';
    const types=shape.types?.filter(type=>type!=='null');
    return types?.length===1?types[0]:undefined;
};

export function formContentType(shape:FormShape,family:string):string {
    const type=formLiteralType(shape);
    if(type==='array'&&family!=='3.2')return shape.items?.defaultContentType??(family==='3.0'?'text/plain':'application/octet-stream');
    if(type==='string'&&(family==='3.0'?['binary','byte'].includes(shape.format??''):shape.contentEncoding!==undefined))return 'application/octet-stream';
    return type==='object'||type==='array'?'application/json':type===undefined&&family!=='3.0'?'application/octet-stream':'text/plain';
}

/** Transport hints are projections of the existing graph, not a resolver or
 * validator. Exact instance evaluation remains with the captured Schema Object.
 * OAS 3.0 §4.7.15 and 3.1 §4.8.15 differ on multipart RFC6570 fields. */
export class FormSemantics {
    constructor(private readonly graph:ReferenceGraph,private readonly references:ReadonlyMap<string,GraphReference>){}

    shape(resource:string,pointer:string,seen:ReadonlySet<string>=new Set(),depth=0):FormShape {
        const key=resource+'#'+pointer;
        if(depth>128||seen.has(key))return {};
        seen=new Set(seen).add(key);
        const node=this.graph.docs.get(resource)?.dataNode(pointer),value=node?.value;
        if(!value||typeof value!=='object'||Array.isArray(value))return {};
        const scope=this.graph.scope(resource,pointer);
        let inherited:FormShape={};
        if(typeof value.$ref==='string'){
            const edge=this.references.get(JSON.stringify([resource,pointer,'$ref']));
            if(edge?.kind==='schema'&&edge.resolution==='resolved')inherited=this.shape(edge.targetResource!,edge.targetPointer!,seen,depth+1);
            if(scope.family==='3.0')return inherited;
        }
        const shapes:FormShape[]=[inherited,...(Array.isArray(value.allOf)?value.allOf.map((_:unknown,index:number)=>this.shape(resource,pointer+'/allOf/'+index,seen,depth+1)):[])];
        const types=typeof value.type==='string'?[value.type]:Array.isArray(value.type)?value.type.filter((type:unknown)=>typeof type==='string'):undefined;
        const properties:Record<string,FormShape>=Object.assign(Object.create(null),...shapes.map(shape=>shape.properties??{}));
        if(value.properties&&typeof value.properties==='object')for(const name of Object.keys(value.properties))properties[name]=this.shape(resource,pointer+'/properties/'+escape(name),seen,depth+1);
        const shape:FormShape={
            types:types??shapes.find(shape=>shape.types)?.types,
            format:typeof value.format==='string'?value.format:shapes.find(shape=>shape.format)?.format,
            contentEncoding:typeof value.contentEncoding==='string'?value.contentEncoding:shapes.find(shape=>shape.contentEncoding)?.contentEncoding,
            properties,
            items:value.items&&typeof value.items==='object'&&!Array.isArray(value.items)?this.shape(resource,pointer+'/items',seen,depth+1):shapes.find(shape=>shape.items)?.items,
            prefixItems:Array.isArray(value.prefixItems)?value.prefixItems.map((_:unknown,index:number)=>this.shape(resource,pointer+'/prefixItems/'+index,seen,depth+1)):shapes.find(shape=>shape.prefixItems)?.prefixItems,
        };
        return {...shape,literalType:formLiteralType(shape),defaultContentType:formContentType(shape,scope.family)};
    }

    media(family:string,resource:string,pointer:string,mediaType:string){
        const value=this.graph.docs.get(resource)?.dataNode(pointer)?.value,shape=this.shape(resource,pointer+'/schema');
        const parts=Object.fromEntries([...new Set([...Object.keys(shape.properties??{}),...Object.keys(value?.encoding??{})])].map(name=>{
            const rule=value?.encoding?.[name],property=shape.properties?.[name],item=property?.types?.includes('array')?property.items:property;
            const multipart=mediaType.split(';')[0].trim().toLowerCase().startsWith('multipart/');
            const styled=(!multipart||family!=='3.0')&&['style','explode','allowReserved'].some(key=>Object.hasOwn(rule??{},key));
            const doc=this.graph.docs.get(resource)!;
            const at=[pointer+'/encoding/'+escape(name)+'/contentType',pointer+'/encoding/'+escape(name),pointer+'/schema/properties/'+escape(name),pointer+'/schema',pointer].find(at=>doc.dataNode(at))!;
            const node=doc.dataNode(at)!;
            let options:ReturnType<typeof mediaTypeOptions>|{error:string}|undefined;
            try{options=styled?undefined:mediaTypeOptions(rule?.contentType??item?.defaultContentType??formContentType({},family));}
            catch(error){if(!(error instanceof SourceError))throw error;options={error:error.message};}
            return [name,{name,styled,...options,source:{resource,pointer:at,range:node.range}}];
        }));
        return {multipartStyle:family!=='3.0',legacyBinary:family==='3.0',
            defaultContentType:formContentType({},family),
            styles:['form','spaceDelimited','pipeDelimited','deepObject'],
            shape:{defaultContentType:formContentType({},family),...shape},parts};
    }
}

export function formMediaIssues(graph:ReferenceGraph){
    const issues:{resource:string;pointer:string;code:string;message:string;incomplete?:boolean;severity?:string}[]=[];
    for(const scope of graph.scopes.values()){
        if(scope.family==='3.0'&&scope.kind==='media'){
            let parent=scope.pointer,owner:string|undefined;
            while(parent){parent=parent.slice(0,parent.lastIndexOf('/'));const kind=graph.scopes.get(scope.resource+'#'+parent)?.kind;if(kind&&['request-body','response','parameter','header'].includes(kind)){owner=kind;break;}}
            if(owner==='request-body'){
                try{
                    const types=mediaTypes(segments(scope.pointer).at(-1)!);
                    if(types.length===1&&types[0].type==='multipart'&&!graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.children.has('schema'))
                        issues.push({...scope,code:'media.multipart.schema.required',message:'OpenAPI 3.0 multipart input content requires a schema (4.7.15.3)'});
                }catch(error){
                    // The shared media declaration check reports this at the
                    // actual key; do not duplicate it as a multipart finding.
                    if(!(error instanceof SourceError))throw error;
                }
            }
        }
        if(scope.kind!=='encoding')continue;
        const value=graph.docs.get(scope.resource)?.dataNode(scope.pointer)?.value?.contentType;
        if(typeof value!=='string')continue;
        try{mediaTypes(value);}catch(error){
            if(!(error instanceof SourceError))throw error;
            if(error.code==='request.form.media-parameters.unsupported')continue;
            issues.push({...scope,pointer:scope.pointer+'/contentType',code:error.code,message:error.message});
        }
    }
    return issues;
}
