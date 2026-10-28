import {finiteServerVariableValues} from './server_semantics';
import {requestOperation} from './execution';
import type {ReferenceGraph} from './reference_graph';
import type {Resource} from './engine';
import {serverTemplate} from './derived_bundle';

function formSignatures(media:any):unknown {
    const type=media.mediaType.split(';')[0].trim().toLowerCase(),multipart=type==='multipart/form-data';
    if(!multipart&&type!=='application/x-www-form-urlencoded')return;
    const content=(shape:any)=>shape?.defaultContentType??'text/plain';
    const signature=(name:string,shape:any,rule:any,styled:boolean)=>{
        const types=shape?.types??[],array=types.includes('array'),object=types.includes('object');
        const style=rule?.style??'form',explode=rule?.explode??(style==='form');
        if(styled&&(array||object))return {name,mode:'style',style,explode,allowReserved:multipart?false:rule?.allowReserved===true};
        const contentType=styled?'text/plain':rule?.contentType??content(array?shape.items:shape);
        // Text-based array contents are repeated primitive fields. JSON
        // contents keep their media representation instead of becoming style.
        if(!multipart&&array&&contentType==='text/plain')return {name,mode:'style',style:'form',explode:true,allowReserved:false};
        return {name,mode:'content',array,contentType};
    };
    if(media.swaggerForm)return media.swaggerForm.map((parameter:any)=>{
        const array=parameter.type==='array',format=parameter.collectionFormat??'csv';
        const shape={types:[parameter.type],defaultContentType:parameter.type==='file'?'application/octet-stream':'text/plain',items:{defaultContentType:'text/plain'}};
        if(array&&!(multipart&&format==='multi'))return signature(parameter.name,shape,{style:format==='ssv'?'spaceDelimited':format==='pipes'?'pipeDelimited':'form',explode:format==='multi'},true);
        return signature(parameter.name,shape,undefined,false);
    }).sort((a:any,b:any)=>a.name.localeCompare(b.name));
    return Object.entries(media.form?.shape?.properties??{}).map(([name,shape])=>{
        const rule=media.encoding?.[name],styled=(!multipart||media.form.multipartStyle)&&['style','explode','allowReserved'].some(field=>Object.hasOwn(rule??{},field));
        // Repeated primitive form fields have the same decoded values as
        // content-based parts; the remaining style cases retain separators.
        if(multipart&&styled&&(rule.style??'form')==='form'&&(rule.explode??true)===true)return signature(name,shape,{contentType:'text/plain'},false);
        return signature(name,shape,rule,styled);
    }).sort((a:any,b:any)=>a.name.localeCompare(b.name));
}

/** Representation-sensitive checks supplement native target validation. The
 * signature contains API declarations, never environments or credentials. */
export function migrationRequestSignatures(graph:ReferenceGraph,resources:Resource[]):string[] {
    return graph.operations().filter(operation=>operation.role==='operation').map(operation=>{
        const plan=requestOperation({root:graph.root,resources,snapshot:'migration-invariant',resource:operation.source.resource,pointer:operation.source.pointer,occurrence:operation.occurrence});
        const normalize=(value:any):any=>Array.isArray(value)?value.map(normalize):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).filter(name=>!['source','definition','base','origin','sources'].includes(name)).sort().map(name=>[name,normalize(value[name])])):value;
        const parameters=plan.parameters.map((parameter:any)=>({name:parameter.name,in:parameter.in,required:parameter.required,
            style:parameter.style,explode:['array','object'].includes(parameter.type)?parameter.explode:false,allowReserved:parameter.allowReserved})).sort((a:any,b:any)=>JSON.stringify(a).localeCompare(JSON.stringify(b)));
        const media=(values:any[])=>values.map(value=>value.mediaType).sort();
        return JSON.stringify(normalize({method:plan.operation.method,path:plan.operation.path,
            servers:plan.servers.map((server:any)=>{
                const source=server.urlSource??server.source;
                const variables=Object.fromEntries(Object.entries(server.variables).map(([name,definition])=>{
                    if(definition===null||typeof definition!=='object'||Array.isArray(definition))throw new Error('Expected captured Server variable semantics');
                    const choices=finiteServerVariableValues(definition);
                    return [name,{...Object.fromEntries(Object.entries(definition).filter(([field])=>field!=='enum'&&field!=='defaultOutsideEnumAllowed')),...(choices?{enum:[...choices].sort()}: {})}];
                }));
                return {url:serverTemplate(server.url,server.base,server.variables,source),variables};
            }),
            parameters,security:plan.security,body:plan.requestBody?{required:plan.requestBody.required,media:media(plan.requestBody.content),forms:plan.requestBody.content.map((value:any)=>({mediaType:value.mediaType,fields:formSignatures(value)})).sort((a:any,b:any)=>a.mediaType.localeCompare(b.mediaType))}:undefined,
            responses:plan.responses.map((response:any)=>({status:response.status,headers:response.headers.map((header:any)=>({name:header.name,required:header.required})),bodyAllowed:response.bodyAllowed??response.content.length>0,media:response.bodyAllowed===false?[]:media(response.content)}))}));
    }).sort();
}
