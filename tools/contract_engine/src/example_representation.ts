import {runtimeMediaDescription} from './runtime_media';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import {SourceError,segments} from './document';
import {capturedRuntimeMedia} from './runtime_media_owner';

export type ExampleValueField='example'|'value'|'dataValue'|'serializedValue'|'swagger-response';
export type ExampleRepresentation='json'|'serialized';

/** OAS 3.0 §4.7.19.1 embeds non-JSON media examples as strings. Preserve that
 * representation instead of validating XML/form/stream text as a JSON string.
 * JSON string values and explicit 3.2 dataValue remain schema-ready data. */
export function exampleRepresentation(field:ExampleValueField,value:unknown,mediaType?:string):ExampleRepresentation {
 if(field==='serializedValue')return 'serialized';
 if(field==='dataValue'||typeof value!=='string'||mediaType===undefined)return 'json';
 const media=runtimeMediaDescription(mediaType);
 return media.dataModelStatus==='classified'&&media.dataModel==='json'?'json':'serialized';
}

/** Reusable Media Type names carry no format. Classify their literal values
 * from graph-proven content occurrences; never infer JSON from a component name. */
export function mediaExampleRepresentations(graph:ReferenceGraph) {
 const bindings=new Map<string,Set<string>>(),capture=capturedRuntimeMedia(graph);
 const identity=(resource:string,pointer:string)=>JSON.stringify([resource,graph.docs.get(resource)?.dataNode(pointer)?.pointer??pointer]);
 for(const owner of graph.scopes.values()){
  if(owner.kind!=='media')continue;
  const parts=segments(owner.pointer);if(parts.at(-2)!=='content')continue;
  try{
   const source=capture(owner).source,key=identity(source.resource,source.pointer);
   let types=bindings.get(key);if(!types){types=new Set();bindings.set(key,types);}types.add(parts.at(-1)!);
  }catch(error){
   // The canonical graph and serialization owner report the unresolved origin;
   // it cannot establish a format for this projection.
   if(!(error instanceof SourceError)||error.kind!=='unsupported')throw error;
  }
 }
 return (owner:GraphScope,field:ExampleValueField,value:unknown)=>{
  if(field==='dataValue'||typeof value!=='string')return {data:true,serialized:false,contextMissing:false};
  const parts=segments(owner.pointer),types=parts.at(-2)==='content'?[parts.at(-1)!]:[...bindings.get(identity(owner.resource,owner.pointer))??[]];
  if(!types.length)return {data:false,serialized:false,contextMissing:true};
  const forms=new Set(types.map(type=>exampleRepresentation(field,value,type)));
  return {data:forms.has('json'),serialized:forms.has('serialized'),contextMissing:false};
 };
}
