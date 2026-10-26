import {createHash} from 'node:crypto';
import {interpret,BASIC} from '@hyperjump/json-schema/experimental';
import type {CompiledSchema} from '@hyperjump/json-schema/experimental';
import type {Output} from '@hyperjump/json-schema';
import {SourceDocument,SourceError} from './document';
import type {ReferenceGraph} from './reference_graph';
import type {SchemaEvaluationScope} from './swagger_schema';
import {FormSemantics} from './form_semantics';
import {createExactNumericAdapter} from './exact_numbers';
import {decodeRuntimeMedia,runtimeMediaBytes} from './runtime_media';
import {decodeRuntimeForm,type RuntimeFormTarget,type RuntimeFormData,type FormCheck} from './runtime_form';
import {swaggerWireShape,swaggerWireValues,type SwaggerHeaderTarget} from './swagger_wire';
import {headerValueParts} from './header_values';
import {capturedRuntimeHeaders,type RuntimeHeaderTarget} from './runtime_headers';
import {capturedRuntimeMedia,type RuntimeMediaTarget} from './runtime_media_owner';
import {swaggerFileSchemas} from './swagger_file';

type SchemaLocation={resource:string;pointer:string};
type RuntimeInstance={text:string;subject:string;location:string;schema?:SchemaLocation;itemSchema?:SchemaLocation;media?:RuntimeMediaTarget;mediaType?:string;mediaBase64?:boolean;unicodeSerialization?:boolean;form?:RuntimeFormTarget;alternatives?:string[];swaggerHeader?:SwaggerHeaderTarget;header?:RuntimeHeaderTarget};
type Finding=Record<string,unknown>;
type Owner={snapshot:string;graph:ReferenceGraph;scopes:ReadonlyMap<string,SchemaEvaluationScope>;
 exact:ReturnType<typeof createExactNumericAdapter>;compile:(scope:SchemaEvaluationScope)=>Promise<CompiledSchema|undefined>;schemaReady:(scope:SchemaEvaluationScope)=>boolean;
 producer:{name:string;version:string};observeFailure?:(error:unknown)=>void};

function suppliedInstance(value:unknown):RuntimeInstance {
 if(value===null||typeof value!=='object')throw new SourceError('runtime.instance','Expected a runtime instance');
 const item=value as Record<string,unknown>;
 const schema=(location:unknown):location is SchemaLocation=>location!==null&&typeof location==='object'&&
  'resource' in location&&typeof location.resource==='string'&&'pointer' in location&&typeof location.pointer==='string';
 const header=(value:unknown)=>schema(value)&&'name' in value&&typeof value.name==='string'&&value.name.length<=4096&&
  'values' in value&&Array.isArray(value.values)&&value.values.length>0&&value.values.length<=2048&&value.values.every(value=>typeof value==='string');
 const shapes=(value:unknown)=>value!==null&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).length<=2048&&Object.values(value).every(shape=>shape==='single'||shape==='array');
 if(typeof item.text!=='string'||item.text.length>64*1024*1024||typeof item.subject!=='string'||item.subject.length>1024||
  typeof item.location!=='string'||item.location.length>4096||item.schema!==undefined&&!schema(item.schema)||
  item.itemSchema!==undefined&&!schema(item.itemSchema)||item.mediaType!==undefined&&(typeof item.mediaType!=='string'||item.mediaType.length>16384)||
  item.media!==undefined&&(!schema(item.media)||item.mediaType===undefined&&item.subject!=='response-body'||item.form!==undefined||!['request-body','response-body'].includes(item.subject))||
  item.form!==undefined&&(!schema(item.form)||'occurrence' in item.form&&(typeof item.form.occurrence!=='string'||item.form.occurrence.length>4096)||'fileShapes' in item.form&&(!shapes(item.form.fileShapes)||item.subject!=='request-body')||item.mediaType===undefined)||
  item.mediaBase64!==undefined&&typeof item.mediaBase64!=='boolean'||item.mediaBase64===true&&item.mediaType===undefined&&item.media===undefined||
  item.unicodeSerialization!==undefined&&typeof item.unicodeSerialization!=='boolean'||item.unicodeSerialization===true&&(item.mediaType===undefined||item.mediaBase64===true)||
  item.alternatives!==undefined&&(!Array.isArray(item.alternatives)||item.alternatives.length>255||!item.alternatives.every(text=>typeof text==='string'&&text.length<=64*1024*1024)||
   item.mediaType!==undefined||item.itemSchema!==undefined||item.media!==undefined||item.form!==undefined||item.mediaBase64===true)||
  item.swaggerHeader!==undefined&&(!header(item.swaggerHeader)||item.subject!=='response-header'||item.alternatives!==undefined||item.mediaType!==undefined||item.itemSchema!==undefined||item.form!==undefined||item.mediaBase64===true)||
  item.header!==undefined&&(!header(item.header)||item.subject!=='response-header'||item.text!==''||item.schema!==undefined||item.swaggerHeader!==undefined||item.alternatives!==undefined||item.mediaType!==undefined||item.itemSchema!==undefined||item.form!==undefined||item.mediaBase64===true))
  throw new SourceError('runtime.instance','Runtime conformance requires bounded text, media, subject, location and schema identities');
 return item as RuntimeInstance;
}

/** The existing evaluator compiles captured schemas; this owner only maps
 * finite HTTP representations into their data instances and attributes results.
 * It has no acquisition, transport, credential or source-writing capability. */
async function evaluateRuntimeValues(runtime:unknown,owner:Owner,diagnostics?:{omit:ReadonlySet<string>;representative:ReadonlySet<string>}) {
 if(!Array.isArray(runtime)||runtime.length>2048)throw new SourceError('limit.runtime.instances','Runtime conformance input exceeds 2048 instances');
 const evaluations:Finding[]=[],findings:Finding[]=[];
 let complete=true,instances=0,work=0,findingsLimited=false;
 const forms=new FormSemantics(owner.graph,new Map(owner.graph.references.map(edge=>[JSON.stringify([edge.resource,edge.pointer,edge.keyword]),edge])));
 const mediaOwner=capturedRuntimeMedia(owner.graph);
 const fileSchemaFor=swaggerFileSchemas(owner.graph);
 const diagnosed=new Set<string>();
 const add=(finding:Finding)=>{
  // Alternative candidates are internal proofs, not separate user fields.
  // Retain one representative failure per field; all candidate evaluations and
  // unsupported/error states still contribute to their complete schema proof.
  if(diagnostics&&typeof finding.location==='string'){
   if(diagnostics.omit.has(finding.location))return;
   if(diagnostics.representative.has(finding.location)){
    if(diagnosed.has(finding.location))return;
    diagnosed.add(finding.location);
   }
  }
  if(findings.length>=200){complete=false;findingsLimited=true;return;}
  findings.push({version:1,category:'runtime',producer:owner.producer.name,producerVersion:owner.producer.version,snapshot:owner.snapshot,...finding});
 };
 for(let index=0;index<runtime.length;index++){
  let supplied=suppliedInstance(runtime[index]);
  let decoded:ReturnType<typeof decodeRuntimeMedia>;
  let fileSchema:SchemaEvaluationScope|undefined;
  let form:RuntimeFormData|undefined;
  try{
   const captured=supplied.media&&mediaOwner(supplied.media);
   if(captured){
    for(const key of ['schema','itemSchema'] as const){
     const requested=supplied[key],actual=captured[key];
     if(requested&&(requested.resource!==actual?.resource||requested.pointer!==actual?.pointer))throw new SourceError('runtime.media.owner','The body schema does not belong to its captured media declaration',[0,0],'unsupported',{...supplied.media,range:owner.graph.docs.get(supplied.media.resource)?.dataNode(supplied.media.pointer)?.range??[0,0]});
    }
    supplied={...supplied,schema:captured.schema,itemSchema:captured.itemSchema};
   }
   if(captured?.bodyAllowed===false){
    const valid=runtimeMediaBytes(supplied.text,supplied.mediaBase64===true).length===0;
    evaluations.push({subject:supplied.subject,location:supplied.location,complete:true,valid,syntax:'no-response-content'});instances++;
    if(!valid)add({code:'runtime.response.body.forbidden',severity:'error',subject:supplied.subject,location:supplied.location,pointer:'',source:captured.source,range:captured.source.range,message:'The captured response declares no response content.'});
    continue;
   }
   if(captured&&supplied.mediaType===undefined)throw new SourceError('runtime.media.type','A response with declared content requires its actual media type',captured.source.range,'unsupported',captured.source);
   const scope=supplied.schema&&owner.scopes.get(supplied.schema.resource+'#'+supplied.schema.pointer),family=scope?.family??captured?.family;
   const fileTarget=scope&&supplied.subject==='response-body'?fileSchemaFor(scope):undefined;
   fileSchema=fileTarget&&owner.scopes.get(fileTarget.resource+'#'+fileTarget.pointer);
   const shape=scope&&!fileSchema&&(family==='2.0'||family==='3.0')?forms.shape(scope.resource,scope.pointer):undefined;
   const octets=shape?.types?.includes('string')===true&&shape.format==='binary';
   const identity=createHash('sha256').update(JSON.stringify([owner.snapshot,index,supplied.subject,supplied.mediaType])).digest('hex');
   // A Swagger response file has no internal form data model (§6.4.12).
   // Its captured schema takes precedence over the media type's usual codec.
   if(supplied.form&&!fileSchema){form=decodeRuntimeForm(supplied.text,'urn:busyapi:runtime:'+identity,supplied.mediaType!,supplied.mediaBase64===true,supplied.form,supplied.subject,owner.graph);decoded=form;}
   else decoded=decodeRuntimeMedia(supplied.text,'urn:busyapi:runtime:'+identity,supplied.mediaType,supplied.mediaBase64,fileSchema?'file':octets?'octets':family==='2.0'||family==='3.0'?'legacy-octets':family==='3.1'||family==='3.2'?'binary':'unsupported');
   // OAS 3.2 §4.19.2.3 requires a defined Unicode serialization. Opaque
   // binary instances, including nested parts, cannot supply that proof.
   if(supplied.unicodeSerialization===true&&((decoded.binaryInstances?.size??0)>0||form?.checks.some(check=>(check.binary?.size??0)>0)))
    throw new SourceError('runtime.media.unicode.unsupported','A serialized Unicode example contains an opaque binary representation; use an external serialized resource',[0,0],'unsupported');
  }catch(error){
   const limited=error instanceof SourceError&&error.code.startsWith('limit.');
   const unsupported=error instanceof SourceError&&error.kind==='unsupported';
   const known=error instanceof SourceError;
   if(limited||unsupported||!known)complete=false;
   if(!known)owner.observeFailure?.(error);
   evaluations.push({subject:supplied.subject,location:supplied.location,complete:known&&!limited&&!unsupported,valid:false,
    reason:limited?'instance-limit':unsupported?'unsupported-representation':known?(supplied.mediaType===undefined?'invalid-json':'invalid-media'):'decoding-failed'});
   const limitation=unsupported?(supplied.subject==='request-body'?'runtime.request.body.unchecked':supplied.subject==='response-body'?'runtime.response.body.unchecked':'runtime.media.unsupported'):undefined;
   const source=supplied.schema??supplied.itemSchema,formSource=supplied.form;
   add({code:limited?'runtime.body.limit':unsupported?limitation:known?'runtime.body.syntax':'runtime.media.incomplete',
    ...(unsupported?{kind:'unsupported',reason:'unsupported-representation'}:{}),
    ...(source?{schema:{...source,range:owner.graph.docs.get(source.resource)?.dataNode(source.pointer)?.range}}:{}),
    ...(!source&&formSource?{source:{resource:formSource.resource,pointer:formSource.pointer,range:owner.graph.docs.get(formSource.resource)?.dataNode(formSource.pointer)?.range}}:{}),
    ...(error instanceof SourceError?{detailCode:error.code,...(error.source?{source:error.source}:{})}:{}),
    severity:limited||unsupported||!known?'warning':'error',subject:supplied.subject,location:supplied.location,
    pointer:'',range:error instanceof SourceError?error.range:[0,0],
    message:limited?'The runtime representation exceeds a bounded decoding limit; its schema check was not performed.':
     unsupported?'This media representation has no native decoder; no complete schema result is claimed.':
     known?'The runtime representation is not valid for its selected media type.':'Runtime decoding did not complete; no clean schema result is claimed.'});
   continue;
  }
  const checks:FormCheck[]=[{document:decoded.document,schema:supplied.schema,prefix:''},...(form?.checks??[])];
  for(const issue of form?.issues??[]){
   if(issue.severity==='error')evaluations.push({subject:supplied.subject,location:supplied.location,pointer:issue.pointer,complete:true,valid:false,representation:decoded.kind});
   add({...issue,subject:supplied.subject,location:supplied.location});
  }
  if(supplied.itemSchema!==undefined){
   if(decoded.items===undefined){
    complete=false;
    add({code:'runtime.media.items.unsupported',severity:'warning',subject:supplied.subject,location:supplied.location,pointer:'',range:[0,0],
     message:'itemSchema requires a supported sequential media representation; no item checks were claimed.'});
   }else checks.push(...decoded.items.map((document,index)=>({document,schema:supplied.itemSchema,prefix:'/'+index})));
  }
  for(const check of checks){
   if(++work>2048){
    complete=false;add({code:'runtime.body.limit',severity:'warning',subject:supplied.subject,location:supplied.location,pointer:check.prefix,range:[0,0],message:'Runtime evaluation exceeds 2048 whole-value and item checks.'});break;
   }
   if(check.schema===undefined){evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:true,valid:true,syntax:check.file?'file-part-presence-and-framing':decoded.kind});instances++;continue;}
   const scope=owner.scopes.get(check.schema.resource+'#'+check.schema.pointer);
   if(scope?.kind!=='schema'){
    complete=false;evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:false,valid:false,reason:'schema-unavailable'});continue;
   }
   try{
    if(fileSchema&&decoded.kind==='file'){
     if(!owner.schemaReady(scope)||!owner.schemaReady(fileSchema)){complete=false;evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:false,valid:false,reason:'schema-incomplete'});continue;}
     evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:true,valid:true,syntax:'file-entity-bytes',schema:check.schema});instances++;continue;
    }
    const ast=await owner.compile(scope);
    if(!ast){complete=false;evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:false,valid:false,reason:'schema-incomplete'});continue;}
    owner.exact.setDirection(supplied.subject.startsWith('request-')?'request':supplied.subject.startsWith('response-')?'response':undefined);
    let result:Output;
    try{result=interpret(ast,owner.exact.exactInstance(check.document,'',undefined,false,check.binary??decoded.binaryInstances?.get(check.document)),BASIC);instances++;}
    finally{owner.exact.setDirection(undefined);}
    evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:true,valid:result.valid,representation:decoded.kind,schema:check.schema});
    if(result.valid===false){
     if(!result.errors?.length)throw new SourceError('runtime.protocol','Invalid schema output omitted its findings');
     for(const error of result.errors.slice(0,32)){
     const pointer=decodeURIComponent(new URL(error.instanceLocation).hash.slice(1));
     add({code:'runtime.schema.incompatible',severity:'error',subject:supplied.subject,location:supplied.location,pointer:check.prefix+pointer,
      range:check.document.dataNode(pointer)?.range??[0,0],representation:decoded.kind,
      message:'The runtime value does not satisfy the captured response or input schema.',keyword:error.keyword,
      schema:{...check.schema,range:owner.graph.docs.get(scope.resource)?.dataNode(scope.pointer)?.range}});
     }
    }
   }catch(error){
    owner.observeFailure?.(error);complete=false;evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:false,valid:false,reason:'evaluation-failed'});
   }
  }
 }
 if(findingsLimited)findings.push({version:1,category:'runtime',code:'limit.runtime.findings',severity:'warning',message:'Runtime findings reached the bounded limit; shown checks are not exhaustive.',producer:owner.producer.name,producerVersion:owner.producer.version,snapshot:owner.snapshot});
 return {complete,evaluations,findings,instances};
}

/** A wire codec can supply several data inversions; the original schema must
 * prove at least one for each individual field. Candidates share one bounded
 * evaluator job, resource graph and dialect. This is not a transformed schema
 * or a union of independent fields, and discarded candidates cannot leak their
 * findings into a successful proof. Media framing remains a single assertion. */
export async function evaluateRuntimeInstances(runtime:unknown,owner:Owner) {
 if(!Array.isArray(runtime)||!runtime.some(value=>value!==null&&typeof value==='object'&&(value.alternatives!==undefined||value.swaggerHeader!==undefined||value.header!==undefined)))return evaluateRuntimeValues(runtime,owner);
 if(runtime.length>2048)throw new SourceError('limit.runtime.instances','Runtime conformance input exceeds 2048 instances');
 const entries=runtime.map(suppliedInstance),expanded:RuntimeInstance[]=[],groups:({entry:RuntimeInstance;locations:string[];representationsComplete:boolean}|{entry:RuntimeInstance;failure:SourceError}|{entry:RuntimeInstance;unconstrained:true})[]=[];
 const decodeHeader=capturedRuntimeHeaders(owner.graph);
 for(const [index,supplied]of entries.entries()){
  let entry=supplied,representationsComplete=true;
  if(entry.header){
   try{
    const decoded=decodeHeader(entry.header);
    if(!decoded){groups.push({entry,unconstrained:true});continue;}
    representationsComplete=decoded.complete;
    entry={...entry,...decoded.instance,location:entry.location,header:undefined};
   }catch(error){
    if(!(error instanceof SourceError)||error.code==='runtime.instance')throw error;
    groups.push({entry,failure:error});continue;
   }
  }
  if(entry.swaggerHeader){
   const header=entry.swaggerHeader,scope=owner.scopes.get(header.resource+'#'+header.pointer);
   if(scope?.family!=='2.0'||scope.objectKind!=='header'||entry.schema&&(entry.schema.resource!==header.resource||entry.schema.pointer!==header.pointer))
    throw new SourceError('runtime.instance','Swagger header evaluation requires its original captured Header Object');
   try{
    const shape=swaggerWireShape(owner.graph.docs.get(header.resource)?.dataNode(header.pointer)?.value);
    if(header.name.toLowerCase()==='set-cookie'&&(header.values.length>1||shape.type==='array'))throw new SourceError('runtime.swagger.header.unchecked','This Set-Cookie representation requires OpenAPI 3.2 multiline rules',[0,0],'unsupported');
    if(header.values.length>1&&(shape.type!=='array'||shape.collectionFormat!=='csv'))throw new SourceError('runtime.swagger.header.unchecked','Repeated scalar or non-CSV header fields require an explicit interpretation',[0,0],'unsupported');
    const values=shape.type==='array'&&shape.collectionFormat==='csv'?[header.values.join(',')]:header.values;
    const texts=swaggerWireValues(values,shape,{commas:headerValueParts});
    entry={...entry,schema:{resource:header.resource,pointer:header.pointer},text:texts[0],...(texts.length>1?{alternatives:texts.slice(1)}:{}),swaggerHeader:undefined};
   }catch(error){
    if(!(error instanceof SourceError))throw error;
    groups.push({entry,failure:error});continue;
   }
  }
  const texts=[entry.text,...(entry.alternatives??[])];
  if(expanded.length+texts.length>2048){groups.push({entry,failure:new SourceError('limit.runtime.instances','Runtime alternatives exceed 2048 instances',[0,0],'unsupported')});continue;}
  const locations=texts.map((text,choice)=>{
   const location=JSON.stringify(['native-runtime-alternative',index,choice]);
   expanded.push({...entry,text,location,alternatives:undefined});return location;
  });
  groups.push({entry,locations,representationsComplete});
 }
 const alternateGroups=groups.filter((group):group is Extract<typeof group,{locations:string[]} >=>'locations' in group&&group.locations.length>1);
 const diagnostics={omit:new Set(alternateGroups.flatMap(group=>group.locations.slice(1))),representative:new Set(alternateGroups.map(group=>group.locations[0]))};
 const result=await evaluateRuntimeValues(expanded,owner,diagnostics),evaluations:Finding[]=[],findings:Finding[]=[];
 const byLocation=new Map<string,Finding[]>(),notes=new Map<string,Finding[]>();
 for(const value of result.evaluations){const location=String(value.location);byLocation.set(location,[...(byLocation.get(location)??[]),value]);}
 for(const finding of result.findings){
  if(typeof finding.location!=='string'){findings.push(finding);continue;}
  notes.set(finding.location,[...(notes.get(finding.location)??[]),finding]);
 }
 let complete=result.complete;
 for(const group of groups){
  const {entry}=group;
  if('unconstrained' in group){
   evaluations.push({subject:entry.subject,location:entry.location,pointer:'',complete:true,valid:true,representation:'unconstrained-header'});continue;
  }
  if('failure' in group){
   const failure=group.failure,unsupported=failure.kind==='unsupported'||failure.code.startsWith('limit.')||failure.code==='mock.validation.protocol';
   const header=entry.swaggerHeader!==undefined||entry.header!==undefined;
   if(unsupported)complete=false;
   const target=entry.header??entry.swaggerHeader??entry.schema;
   evaluations.push({subject:entry.subject,location:entry.location,pointer:'',complete:!unsupported,valid:false,reason:unsupported?'unsupported-representation':header?'invalid-header':'incompatible-alternatives'});
   findings.push({version:1,category:'runtime',producer:owner.producer.name,producerVersion:owner.producer.version,snapshot:owner.snapshot,
    code:header?(unsupported?'runtime.response.header.unchecked':'runtime.response.header.serialization'):'runtime.schema.alternatives.unchecked',severity:unsupported?'warning':'error',...(unsupported?{kind:'unsupported'}:{}),
    subject:entry.subject,location:entry.location,pointer:'',message:failure.message,detailCode:failure.code,
    ...(target?{schema:{resource:target.resource,pointer:target.pointer,range:owner.graph.docs.get(target.resource)?.dataNode(target.pointer)?.range}}:{})});continue;
  }
  const {locations}=group;
  const choices=locations.map(location=>({location,values:byLocation.get(location)??[]}));
  if(entry.alternatives===undefined&&group.representationsComplete){
   evaluations.push(...choices[0].values.map(value=>({...value,location:entry.location})));
   findings.push(...(notes.get(locations[0])??[]).map(value=>({...value,location:entry.location})));continue;
  }
  const proven=choices.find(choice=>choice.values.length&&choice.values.every(value=>value.complete===true&&value.valid===true));
  if(proven){
   evaluations.push({...proven.values[0],location:entry.location,complete:true,valid:true,alternatives:choices.length,chosen:locations.indexOf(proven.location)});continue;
  }
  const checked=group.representationsComplete&&choices.every(choice=>choice.values.length&&choice.values.every(value=>value.complete===true));
  complete=complete&&checked;
  evaluations.push({subject:entry.subject,location:entry.location,pointer:'',complete:checked,valid:false,alternatives:choices.length,reason:checked?'incompatible-alternatives':'alternatives-incomplete'});
  findings.push(...(notes.get(locations[0])??[]).map(value=>({...value,location:entry.location})));
  if(!checked)findings.push({version:1,category:'runtime',producer:owner.producer.name,producerVersion:owner.producer.version,snapshot:owner.snapshot,
   code:!group.representationsComplete&&entry.subject==='response-header'?'runtime.response.header.unchecked':'runtime.schema.alternatives.unchecked',severity:'warning',subject:entry.subject,location:entry.location,pointer:'',
   message:'The bounded wire interpretations could not be completely evaluated; no valid interpretation was proved.',
   ...(entry.schema?{schema:{...entry.schema,range:owner.graph.docs.get(entry.schema.resource)?.dataNode(entry.schema.pointer)?.range}}:{})});
 }
 if(!complete&&!findings.some(value=>value.severity==='warning'))findings.push({version:1,category:'runtime',producer:owner.producer.name,producerVersion:owner.producer.version,snapshot:owner.snapshot,
  code:'runtime.schema.alternatives.unchecked',severity:'warning',message:'The bounded runtime alternative evaluation did not complete; no complete result is claimed.'});
 return {complete,evaluations,findings,instances:result.instances};
}
