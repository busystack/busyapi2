import {SourceDocument,SourceError,escape,segments} from './document';
import type {GraphScope,GraphTarget,ReferenceGraph} from './reference_graph';
import type {NativeRuntimeInstance} from './mock_projection';
import {capturedRuntimeMedia} from './runtime_media_owner';
import {runtimeFormMedia} from './runtime_media';
import {modernFamily} from './specification';

type Location={resource:string;pointer:string};
type Finding=Record<string,unknown>;
type Check={complete:boolean;evaluations:Finding[];findings:Finding[];instances:number};
type Example={document:SourceDocument;pointer:string;owner:GraphScope;mediaType:string;text:string};
export type SerializedExampleEvaluation=Location&{occurrencePointer?:string;media:Location;mediaType:string;complete:boolean;valid:boolean};
export type SerializedExampleFinding={document:SourceDocument;pointer:string;code:string;message:string;incomplete:boolean;details?:Record<string,unknown>};

/** OAS 3.2 §4.19.2.4: serialization compatibility uses the same captured media
 * codecs and exact schema proofs as HTTP. This owner acquires no resources and
 * keeps each scalar's physical/occurrence provenance for the caller's findings. */
export async function evaluateSerializedExamples(graph:ReferenceGraph,evaluate:(instances:NativeRuntimeInstance[])=>Promise<Check>) {
 const examples:Example[]=[],evaluations:SerializedExampleEvaluation[]=[],findings:SerializedExampleFinding[]=[];
 const capture=capturedRuntimeMedia(graph),edges=new Map(graph.references.filter(edge=>edge.keyword==='$ref').map(edge=>[edge.resource+'#'+edge.pointer,edge]));
 let complete=true,instances=0;
 const fail=(document:SourceDocument,pointer:string,error:unknown)=>{
  if(!(error instanceof SourceError))throw error;
  complete=false;findings.push({document,pointer,code:'example.serialization.incomplete',message:error.message,incomplete:true,details:{detailCode:error.code}});
 };
 const follow=(start:GraphTarget):GraphTarget=>{
  let target=start;const seen=new Set<string>();
  for(let depth=0;depth<128;depth++){
   const key=target.resource+'#'+target.pointer;
   if(seen.has(key))throw new SourceError('example.reference.cycle','The example reference chain contains a cycle',[0,0],'unsupported');seen.add(key);
   const node=graph.docs.get(target.resource)?.dataNode(target.pointer);
   if(!node)throw new SourceError('example.reference.missing','The captured example declaration is unavailable',[0,0],'unsupported');
   if(node.kind!=='object'||typeof node.value.$ref!=='string')return target;
   const edge=edges.get(key);
   if(edge?.kind!==target.kind||edge.resolution!=='resolved')throw new SourceError('example.reference.unresolved','The captured example reference is unresolved',[0,0],'unsupported');
   target={resource:edge.targetResource!,pointer:edge.targetPointer!,kind:target.kind};
  }
  throw new SourceError('limit.example.references','The example reference chain exceeds 128 declarations',[0,0],'unsupported');
 };
 for(const owner of graph.scopes.values()){
  if(!modernFamily(owner.family)||owner.kind!=='media')continue;
  const parts=segments(owner.pointer);
  // Reusable Media Type Object names are not media types. Each actual content
  // occurrence supplies its own key and reference chain instead.
  if(parts.at(-2)!=='content')continue;
  const document=graph.docs.get(owner.resource)!;
  try{
   const target=follow(owner),selected=graph.docs.get(target.resource)!,named=selected.dataNode(target.pointer+'/examples');
   if(named?.kind!=='object')continue;
   for(const [name]of named.children){
    const occurrence=target.pointer+'/examples/'+escape(name);
    try{
     const example=follow({...target,pointer:occurrence,kind:'example'}),source=graph.docs.get(example.resource)!;
     const pointer=example.pointer+'/serializedValue',node=source.dataNode(pointer);
     if(!node)continue;
     if(graph.scope(example.resource,example.pointer).family!=='3.2')throw new SourceError('example.serialization.family','The captured Example Object family does not define serializedValue',[0,0],'unsupported');
     if(examples.length>=20000)throw new SourceError('limit.examples.serialized','Serialized examples exceed 20000 captured values',[0,0],'unsupported');
     if(!source.dataSyntaxSafe(pointer)||typeof node.value!=='string')throw new SourceError('example.serialization.source','The serialized example is not a complete Unicode string',[0,0],'unsupported');
     examples.push({document:source,pointer,owner,mediaType:parts.at(-1)!,text:node.value});
    }catch(error){fail(selected,occurrence,error);}
   }
  }catch(error){fail(document,owner.pointer,error);}
 }
 const subject=(owner:GraphScope)=>{
  let pointer=owner.pointer;
  while(pointer){
   const kind=graph.scopes.get(owner.resource+'#'+pointer)?.kind;
   if(kind==='request-body'||kind==='parameter')return 'request-body';
   if(kind==='response'||kind==='header')return 'response-body';
   pointer=pointer.slice(0,pointer.lastIndexOf('/'));
  }
  return 'authored-example';
 };
 for(let offset=0;offset<examples.length;offset+=128){
  const batch=examples.slice(offset,offset+128),runtime:NativeRuntimeInstance[]=[],owners=new Map<string,Example>();
  for(const [index,example]of batch.entries()){
   try{
    const media=capture(example.owner),location=String(offset+index),direction=subject(example.owner);
    const instance:NativeRuntimeInstance={subject:direction,location,text:example.text,mediaType:example.mediaType,unicodeSerialization:true};
    if(runtimeFormMedia(example.mediaType)){
     instance.form=example.owner;instance.schema=media.schema;instance.itemSchema=media.itemSchema;
    }else if(direction==='request-body'||direction==='response-body')instance.media=example.owner;
    else{
     instance.schema=media.schema;instance.itemSchema=media.itemSchema;
     if(runtimeFormMedia(example.mediaType))instance.form=media.source;
    }
    runtime.push(instance);owners.set(location,example);
   }catch(error){fail(example.document,example.pointer,error);}
  }
  if(!runtime.length)continue;
  const result=await evaluate(runtime);instances+=result.instances;
  if(!result.complete)complete=false;
  for(const [location,example]of owners){
   const checks=result.evaluations.filter(check=>check.location===location),notes=result.findings.filter(note=>note.location===location);
   const checked=checks.length>0&&checks.every(check=>check.complete===true)&&!notes.some(note=>note.kind==='unsupported');
   const valid=checked&&checks.every(check=>check.valid===true)&&!notes.some(note=>note.severity==='error');
   if(!checked)complete=false;
   const physical=example.document.dataNode(example.pointer)!.pointer;
   evaluations.push({resource:example.document.id,pointer:physical,...(physical!==example.pointer?{occurrencePointer:example.pointer}:{}),media:{resource:example.owner.resource,pointer:example.owner.pointer},mediaType:example.mediaType,complete:checked,valid});
   if(!valid)findings.push({document:example.document,pointer:example.pointer,code:checked?'example.serialization.incompatible':'example.serialization.incomplete',message:checked?'This supplied serialized example does not satisfy its captured media representation and schema assertions.':'The serialized example could not be completely evaluated under its captured media representation.',incomplete:!checked,
    details:{interpretation:'authored-serialization',media:{resource:example.owner.resource,pointer:example.owner.pointer},details:notes.map(note=>({code:note.code,detailCode:note.detailCode,pointer:note.pointer,schema:note.schema,source:note.source}))}});
  }
 }
 return {complete,evaluations,findings,instances};
}
