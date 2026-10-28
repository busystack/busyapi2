import {SourceDocument,SourceError,escape,segments} from './document';
import type {GraphScope,GraphTarget,ReferenceGraph} from './reference_graph';
import type {NativeRuntimeInstance} from './mock_projection';
import {capturedRuntimeMedia} from './runtime_media_owner';
import {runtimeFormMedia} from './runtime_media';
import {isNativeFamily} from './specification';
import {exampleHeaderName} from './runtime_headers';
import {exampleRepresentation} from './example_representation';
import {parameterSerializationEvaluator,type SerializationCheck} from './serialized_parameter_examples';

type Location={resource:string;pointer:string};
type Finding=Record<string,unknown>;
type Check=SerializationCheck;
type MediaExampleField='example'|'value'|'serializedValue'|'swagger-response';
type Example={document:SourceDocument;pointer:string;owner:GraphScope;mediaType:string;text:string;field:MediaExampleField};
type SerializedExampleOwner={media:Location;mediaType:string;field:MediaExampleField;parameter?:never;header?:never}
 |{parameter:Location;media?:never;mediaType?:never;header?:never;field?:never}
 |{header:Location;media?:never;mediaType?:never;parameter?:never;field?:never};
export type SerializedExampleEvaluation=Location&SerializedExampleOwner&{occurrencePointer?:string;complete:boolean;valid:boolean};
export type SerializedExampleFinding={document:SourceDocument;pointer:string;code:string;message:string;incomplete:boolean;severity?:'warning'|'information';details?:Record<string,unknown>};

/** OAS 3.2 §4.19.2.4: serialization compatibility uses the same captured media
 * codecs and exact schema proofs as HTTP. This owner acquires no resources and
 * keeps each scalar's physical/occurrence provenance for the caller's findings. */
export async function evaluateSerializedExamples(graph:ReferenceGraph,evaluate:(instances:NativeRuntimeInstance[])=>Promise<Check>) {
 const parameterExamples:{document:SourceDocument;pointer:string;owner:GraphScope;text:string}[]=[];
 const examples:Example[]=[],evaluations:SerializedExampleEvaluation[]=[],findings:SerializedExampleFinding[]=[];
 const capturedSerializations=new Map<string,Set<string>>(),boundMediaDefinitions=new Set<string>(),boundHeaderDefinitions=new Set<string>();
 const context=(owner:GraphTarget)=>JSON.stringify([owner.resource,owner.pointer]);
 const physical=(owner:GraphTarget)=>JSON.stringify([owner.resource,graph.docs.get(owner.resource)?.dataNode(owner.pointer)?.pointer??owner.pointer]);
 const associate=(values:Map<string,Set<string>>,identity:string,owner:GraphTarget)=>{
  let contexts=values.get(identity);if(!contexts){contexts=new Set();values.set(identity,contexts);}
  const before=contexts.size;contexts.add(context(owner));return contexts.size!==before;
 };
 const capture=capturedRuntimeMedia(graph),edges=new Map(graph.references.filter(edge=>edge.keyword==='$ref').map(edge=>[edge.resource+'#'+edge.pointer,edge]));
 let complete=true,instances=0,unbound=0;
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
 const captureString=(source:SourceDocument,pointer:string,owner:GraphScope,mediaType:string,field:'example'|'value'|'serializedValue'|'swagger-response')=>{
  const node=source.dataNode(pointer);if(!node)return;
  if(field!=='serializedValue'&&typeof node.value!=='string')return;
  if(exampleRepresentation(field,node.value,mediaType)!=='serialized')return;
  if(examples.length>=20000)throw new SourceError('limit.examples.serialized','Serialized examples exceed 20000 captured values',[0,0],'unsupported');
  if(!source.dataSyntaxSafe(pointer)||typeof node.value!=='string')throw new SourceError('example.serialization.source','The serialized example is not a complete Unicode string',[0,0],'unsupported');
  associate(capturedSerializations,JSON.stringify([source.id,node.pointer]),owner);
  examples.push({document:source,pointer,owner,mediaType,text:node.value,field});
 };
 for(const owner of graph.scopes.values())if(owner.family==='2.0'&&owner.kind==='response'){
  const source=graph.docs.get(owner.resource)!,named=source.dataNode(owner.pointer+'/examples');
  if(named?.kind!=='object')continue;
  for(const [mediaType]of named.children)try{captureString(source,owner.pointer+'/examples/'+escape(mediaType),owner,mediaType,'swagger-response');}catch(error){fail(source,owner.pointer+'/examples/'+escape(mediaType),error);}
 }
 for(const owner of graph.scopes.values()){
  if(!isNativeFamily(owner.family)||owner.family==='2.0'||owner.kind!=='media')continue;
  const parts=segments(owner.pointer);
  // Reusable Media Type Object names are not media types. Each actual content
  // occurrence supplies its own key and reference chain instead.
  if(parts.at(-2)!=='content')continue;
  const document=graph.docs.get(owner.resource)!;
  try{
   const target=follow(owner),selected=graph.docs.get(target.resource)!,named=selected.dataNode(target.pointer+'/examples');
   boundMediaDefinitions.add(physical(target));
   captureString(selected,target.pointer+'/example',owner,parts.at(-1)!,'example');
   if(named?.kind!=='object')continue;
   for(const [name]of named.children){
    const occurrence=target.pointer+'/examples/'+escape(name);
    try{
     const example=follow({...target,pointer:occurrence,kind:'example'}),source=graph.docs.get(example.resource)!;
     captureString(source,example.pointer+'/value',owner,parts.at(-1)!,'value');
     if(source.dataNode(example.pointer+'/serializedValue')){
      if(graph.scope(example.resource,example.pointer).family!=='3.2')throw new SourceError('example.serialization.family','The captured Example Object family does not define serializedValue',[0,0],'unsupported');
      captureString(source,example.pointer+'/serializedValue',owner,parts.at(-1)!,'serializedValue');
     }
    }catch(error){fail(selected,occurrence,error);}
   }
  }catch(error){fail(document,owner.pointer,error);}
 }
 for(const owner of graph.scopes.values()){
  if(owner.kind!=='header')continue;
  if(exampleHeaderName(graph,owner)===undefined)continue;
  try{boundHeaderDefinitions.add(physical(follow(owner)));}catch(error){fail(graph.docs.get(owner.resource)!,owner.pointer,error);}
 }
 // Example compatibility needs an associated representation (3.0 §4.7.19,
 // 3.1 §4.8.19, 3.2 §4.19). A free reusable Example has no schema or media
 // assertion; keep it distinct from a reusable Media Type with an unchecked
 // serialization. Reference chains retain the physical scalar owner.
 const associated=new Map<string,Set<string>>();let associations=0;
 for(const owner of graph.scopes.values()){
  if(!['media','parameter','header'].includes(owner.kind))continue;
  const document=graph.docs.get(owner.resource)!;
  let definition:GraphTarget;
  try{definition=follow(owner);}catch(error){fail(document,owner.pointer,error);continue;}
  if(owner.kind==='media'&&segments(owner.pointer).at(-2)!=='content'&&boundMediaDefinitions.has(physical(definition)))continue;
  if(owner.kind==='header'&&exampleHeaderName(graph,owner)===undefined&&boundHeaderDefinitions.has(physical(definition)))continue;
  const selected=graph.docs.get(definition.resource)!,named=selected.dataNode(definition.pointer+'/examples');
  const unboundMedia=owner.kind==='media'&&segments(owner.pointer).at(-2)!=='content';
  const missingFormat=(source:SourceDocument,pointer:string)=>{
   if(typeof source.dataNode(pointer)?.value==='string')fail(source,pointer,new SourceError('example.serialization.context-unchecked','A reusable Media Type literal example needs a captured content-type occurrence',[0,0],'unsupported'));
  };
  if(unboundMedia)missingFormat(selected,definition.pointer+'/example');
  if(named?.kind!=='object')continue;
  for(const [name]of named.children){
   const pointer=definition.pointer+'/examples/'+escape(name);
   try{
    const target=follow({...definition,pointer,kind:'example'}),source=graph.docs.get(target.resource)!;
    if(unboundMedia)missingFormat(source,target.pointer+'/value');
    for(const field of ['externalValue','serializedValue']){
     const node=source.dataNode(target.pointer+'/'+field);
     if(node&&associate(associated,JSON.stringify([source.id,node.pointer]),owner))associations++;
     if(node&&field==='serializedValue'&&['parameter','header'].includes(owner.kind)&&graph.scope(target.resource,target.pointer).family==='3.2'){
      if(parameterExamples.length>=20000)throw new SourceError('limit.examples.serialized','Serialized examples exceed 20000 captured values',[0,0],'unsupported');
      if(!source.dataSyntaxSafe(target.pointer+'/'+field)||typeof node.value!=='string')throw new SourceError('example.serialization.source','The serialized example is not a complete Unicode string',[0,0],'unsupported');
      associate(capturedSerializations,JSON.stringify([source.id,node.pointer]),owner);
      parameterExamples.push({document:source,pointer:target.pointer+'/'+field,owner,text:node.value});
     }
    }
    if(associations>20000)throw new SourceError('limit.examples.serialized','Serialization associations exceed 20000 captured values',[0,0],'unsupported');
   }catch(error){fail(selected,pointer,error);}
   if(associations>20000)break;
  }
  if(associations>20000)break;
 }
 // A dataValue proof does not prove its external or serialized representation
 // (3.2 §4.19.2.4). Only canonical Example Object scopes establish these fields;
 // similarly named payload members remain ordinary data in every family.
 const inspected=new Set<string>();
 let firstUnbound:{document:SourceDocument;pointer:string}|undefined;
 for(const scope of graph.scopes.values()){
  if(scope.kind!=='example'||scope.family==='2.0')continue;
  const document=graph.docs.get(scope.resource)!;
  if(graph.referenceObject(document.dataNode(scope.pointer)?.value,scope))continue;
  for(const field of ['externalValue','serializedValue']){
   if(field==='serializedValue'&&scope.family!=='3.2')continue;
   const pointer=scope.pointer+'/'+field,node=document.dataNode(pointer);
   if(!node)continue;
   const identity=JSON.stringify([document.id,node.pointer]);
   if(inspected.has(identity))continue;
   inspected.add(identity);
   if(inspected.size>20000){
    fail(document,pointer,new SourceError('limit.examples.serialized','Serialization coverage exceeds 20000 captured values',[0,0],'unsupported'));
    break;
   }
   const contexts=associated.get(identity),captured=capturedSerializations.get(identity);
   if(!contexts?.size){unbound++;firstUnbound??={document,pointer};continue;}
   if([...contexts].every(value=>captured?.has(value)))continue;
   fail(document,pointer,new SourceError(field==='externalValue'?'example.external-value.unavailable':'example.serialization.context-unchecked',
    field==='externalValue'?'The external example serialization was not acquired and evaluated; its compatibility is incomplete.':'This example serialization has an unevaluated associated representation; its compatibility is incomplete.',node.range,'unsupported'));
  }
  if(inspected.size>20000)break;
 }
 if(firstUnbound)findings.push({...firstUnbound,code:'example.serialization.unbound',severity:'information',message:'No parameter, header, or media definition uses this reusable example. Its metadata was checked; serialization compatibility was not evaluated.',incomplete:false,details:{unboundSerializations:unbound,interpretation:'unbound-example-metadata'}});
 const subject=(owner:GraphScope)=>{
  if(owner.kind==='response')return 'response-body';
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
     instance.form=media.source;instance.schema=media.schema;instance.itemSchema=media.itemSchema;
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
   evaluations.push({resource:example.document.id,pointer:physical,...(physical!==example.pointer?{occurrencePointer:example.pointer}:{}),media:{resource:example.owner.resource,pointer:example.owner.pointer},mediaType:example.mediaType,field:example.field,complete:checked,valid});
   if(!valid)findings.push({document:example.document,pointer:example.pointer,code:checked?'example.serialization.incompatible':'example.serialization.incomplete',message:checked?'This supplied serialized example does not satisfy its captured media representation and schema assertions.':'The serialized example could not be completely evaluated under its captured media representation.',incomplete:!checked,
    details:{interpretation:'authored-serialization',media:{resource:example.owner.resource,pointer:example.owner.pointer},details:notes.map(note=>({code:note.code,detailCode:note.detailCode,pointer:note.pointer,schema:note.schema,source:note.source}))}});
  }
 }
 const evaluateParameter=parameterSerializationEvaluator(graph,evaluate),parameterFindings=new Map<string,{source:Location;details:Finding[]}[]>();
 for(const example of parameterExamples){
  try{
   const result=await evaluateParameter(example.owner,example.text);
   instances+=result.instances;if(!result.complete)complete=false;
   const pointer=example.document.dataNode(example.pointer)!.pointer,source={resource:example.owner.resource,pointer:example.owner.pointer};
   evaluations.push({resource:example.document.id,pointer,...(pointer!==example.pointer?{occurrencePointer:example.pointer}:{}),
    ...(example.owner.kind==='header'?{header:source}:{parameter:source}),complete:result.complete,valid:result.valid,...(result.omission?{omission:result.omission}:{})});
   if(!result.valid){
    const code=result.complete?'example.serialization.incompatible':'example.serialization.incomplete',identity=JSON.stringify([example.document.id,pointer,code]);
    const context={source,details:result.findings.map(note=>({code:note.code,detailCode:note.detailCode,pointer:note.pointer,schema:note.schema,source:note.source}))};
    const existing=parameterFindings.get(identity);
    if(existing)existing.push(context);
    else{
     const contexts=[context];parameterFindings.set(identity,contexts);
     findings.push({document:example.document,pointer:example.pointer,code,
      message:result.complete?'This serialized example does not satisfy its captured parameter or header representation and schema assertions.':'This serialized parameter or header example could not be completely evaluated.',incomplete:!result.complete,
      details:{interpretation:'authored-serialization',contexts}});
    }
   }
  }catch(error){fail(example.document,example.pointer,error);}
 }
 return {complete,evaluations,findings,instances,unbound};
}
