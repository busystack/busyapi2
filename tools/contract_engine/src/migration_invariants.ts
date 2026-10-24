import {requestOperation} from './execution';
import type {ReferenceGraph} from './reference_graph';
import type {Resource} from './engine';
import {serverTemplate} from './derived_bundle';

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
            servers:plan.servers.map((server:any)=>({url:serverTemplate(server.url,server.base,server.variables),variables:server.variables})),
            parameters,security:plan.security,body:plan.requestBody?{required:plan.requestBody.required,media:media(plan.requestBody.content)}:undefined,
            responses:plan.responses.map((response:any)=>({status:response.status,headers:response.headers.map((header:any)=>({name:header.name,required:header.required})),media:media(response.content)}))}));
    }).sort();
}
