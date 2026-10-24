import {escape} from './document';
import type {GraphReference,ReferenceGraph} from './reference_graph';

export type FormShape={types?:string[];format?:string;contentEncoding?:string;properties?:Record<string,FormShape>;items?:FormShape;defaultContentType?:string};

export const formLiteralType=(shape:FormShape):string|undefined=>{
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
        };
        return {...shape,defaultContentType:formContentType(shape,scope.family)};
    }

    media(family:string,resource:string,pointer:string){
        return {multipartStyle:family!=='3.0',legacyBinary:family==='3.0',
            defaultContentType:formContentType({},family),
            styles:['form','spaceDelimited','pipeDelimited','deepObject',...(family==='3.2'?['tabDelimited']:[])],
            shape:{defaultContentType:formContentType({},family),...this.shape(resource,pointer+'/schema')}};
    }
}
