import {createHash} from 'node:crypto';
import {interpret,BASIC} from '@hyperjump/json-schema/experimental';
import type {CompiledSchema} from '@hyperjump/json-schema/experimental';
import type {Output} from '@hyperjump/json-schema';
import {SourceDocument,SourceError} from './document';
import type {ReferenceGraph} from './reference_graph';
import type {SchemaEvaluationScope} from './swagger_schema';
import {FormSemantics} from './form_semantics';
import {createExactNumericAdapter} from './exact_numbers';
import {decodeRuntimeMedia} from './runtime_media';

type SchemaLocation={resource:string;pointer:string};
type RuntimeInstance={text:string;subject:string;location:string;schema?:SchemaLocation;itemSchema?:SchemaLocation;mediaType?:string;mediaBase64?:boolean};
type Finding=Record<string,unknown>;
type Owner={snapshot:string;graph:ReferenceGraph;scopes:ReadonlyMap<string,SchemaEvaluationScope>;
 exact:ReturnType<typeof createExactNumericAdapter>;compile:(scope:SchemaEvaluationScope)=>Promise<CompiledSchema|undefined>;
 producer:{name:string;version:string};observeFailure?:(error:unknown)=>void};

function suppliedInstance(value:unknown):RuntimeInstance {
 if(value===null||typeof value!=='object')throw new SourceError('runtime.instance','Expected a runtime instance');
 const item=value as Record<string,unknown>;
 const schema=(location:unknown):location is SchemaLocation=>location!==null&&typeof location==='object'&&
  'resource' in location&&typeof location.resource==='string'&&'pointer' in location&&typeof location.pointer==='string';
 if(typeof item.text!=='string'||item.text.length>64*1024*1024||typeof item.subject!=='string'||item.subject.length>1024||
  typeof item.location!=='string'||item.location.length>4096||item.schema!==undefined&&!schema(item.schema)||
  item.itemSchema!==undefined&&!schema(item.itemSchema)||item.mediaType!==undefined&&(typeof item.mediaType!=='string'||item.mediaType.length>16384)||
  item.mediaBase64!==undefined&&typeof item.mediaBase64!=='boolean'||item.mediaBase64===true&&item.mediaType===undefined)
  throw new SourceError('runtime.instance','Runtime conformance requires bounded text, media, subject, location and schema identities');
 return item as RuntimeInstance;
}

/** The existing evaluator compiles captured schemas; this owner only maps
 * finite HTTP representations into their data instances and attributes results.
 * It has no acquisition, transport, credential or source-writing capability. */
export async function evaluateRuntimeInstances(runtime:unknown,owner:Owner) {
 if(!Array.isArray(runtime)||runtime.length>2048)throw new SourceError('limit.runtime.instances','Runtime conformance input exceeds 2048 instances');
 const evaluations:Finding[]=[],findings:Finding[]=[];
 let complete=true,instances=0,work=0,findingsLimited=false;
 const forms=new FormSemantics(owner.graph,new Map(owner.graph.references.map(edge=>[JSON.stringify([edge.resource,edge.pointer,edge.keyword]),edge])));
 const add=(finding:Finding)=>{
  if(findings.length>=200){complete=false;findingsLimited=true;return;}
  findings.push({version:1,category:'runtime',producer:owner.producer.name,producerVersion:owner.producer.version,snapshot:owner.snapshot,...finding});
 };
 for(let index=0;index<runtime.length;index++){
  const supplied=suppliedInstance(runtime[index]),scope=supplied.schema&&owner.scopes.get(supplied.schema.resource+'#'+supplied.schema.pointer);
  const shape=scope?.family==='3.0'?forms.shape(scope.resource,scope.pointer):undefined;
  const octets=shape?.types?.includes('string')===true&&shape.format==='binary';
  let decoded:ReturnType<typeof decodeRuntimeMedia>;
  try{
   const identity=createHash('sha256').update(JSON.stringify([owner.snapshot,index,supplied.subject,supplied.mediaType])).digest('hex');
   decoded=decodeRuntimeMedia(supplied.text,'urn:busyapi:runtime:'+identity,supplied.mediaType,supplied.mediaBase64,octets);
  }catch(error){
   const limited=error instanceof SourceError&&error.code.startsWith('limit.');
   const unsupported=error instanceof SourceError&&error.kind==='unsupported';
   const known=error instanceof SourceError;
   if(limited||unsupported||!known)complete=false;
   if(!known)owner.observeFailure?.(error);
   evaluations.push({subject:supplied.subject,location:supplied.location,complete:known&&!limited&&!unsupported,valid:false,
    reason:limited?'instance-limit':unsupported?'unsupported-representation':known?(supplied.mediaType===undefined?'invalid-json':'invalid-media'):'decoding-failed'});
   const limitation=unsupported?(supplied.subject==='request-body'?'runtime.request.body.unchecked':supplied.subject==='response-body'?'runtime.response.body.unchecked':'runtime.media.unsupported'):undefined;
   const source=supplied.schema??supplied.itemSchema;
   add({code:limited?'runtime.body.limit':unsupported?limitation:known?'runtime.body.syntax':'runtime.media.incomplete',
    ...(unsupported?{kind:'unsupported',reason:'unsupported-representation'}:{}),
    ...(source?{schema:{...source,range:owner.graph.docs.get(source.resource)?.dataNode(source.pointer)?.range}}:{}),
    severity:limited||unsupported||!known?'warning':'error',subject:supplied.subject,location:supplied.location,
    pointer:'',range:error instanceof SourceError?error.range:[0,0],
    message:limited?'The runtime representation exceeds a bounded decoding limit; its schema check was not performed.':
     unsupported?'This media representation has no native decoder; no complete schema result is claimed.':
     known?'The runtime representation is not valid for its selected media type.':'Runtime decoding did not complete; no clean schema result is claimed.'});
   continue;
  }
  const checks:{document:SourceDocument;schema?:SchemaLocation;prefix:string}[]=[{document:decoded.document,schema:supplied.schema,prefix:''}];
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
   if(check.schema===undefined){evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:true,valid:true,syntax:decoded.kind});instances++;continue;}
   const scope=owner.scopes.get(check.schema.resource+'#'+check.schema.pointer);
   if(scope?.kind!=='schema'){
    complete=false;evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:false,valid:false,reason:'schema-unavailable'});continue;
   }
   try{
    const ast=await owner.compile(scope);
    if(!ast){complete=false;evaluations.push({subject:supplied.subject,location:supplied.location,pointer:check.prefix,complete:false,valid:false,reason:'schema-incomplete'});continue;}
    owner.exact.setDirection(supplied.subject.startsWith('request-')?'request':supplied.subject.startsWith('response-')?'response':undefined);
    let result:Output;
    try{result=interpret(ast,owner.exact.exactInstance(check.document),BASIC);instances++;}
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
