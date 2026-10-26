import {SourceError,escape} from './document';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import {isNativeFamily} from './specification';
import {ParameterSemantics,parameterStyle} from './parameter_semantics';
import {capturedRuntimeMedia,type CapturedRuntimeMedia,type RuntimeMediaTarget} from './runtime_media_owner';
import {capturedExampleHeaders,exampleHeaderName} from './runtime_headers';
import {FormSemantics} from './form_semantics';
import {validateMockParameters} from './mock_request_parameters';
import type {NativeRuntimeInstance,NativeRuntimeCheck} from './mock_projection';

export type SerializationCheck={complete:boolean;evaluations:Record<string,unknown>[];findings:Record<string,unknown>[];instances:number};
type ExampleMedia={mediaType:string;definition:RuntimeMediaTarget}&Pick<CapturedRuntimeMedia,'schema'|'itemSchema'>;
type Evaluate=(instances:NativeRuntimeInstance[])=>Promise<SerializationCheck>;
export type ParameterSerializationCheck={complete:boolean;valid:boolean;findings:Record<string,unknown>[];instances:number};

/** OAS 3.2 §§4.12.4 and 4.19.2: a parameter-level serialization includes its
 * name and escaping, unlike an example inside its Media Type Object. Reuse
 * native HTTP inversion and exact evaluation over the original graph owner. */
export function parameterSerializationEvaluator(graph:ReferenceGraph,evaluate:Evaluate) {
 const parameters=new ParameterSemantics(graph),header=capturedExampleHeaders(graph),capture=capturedRuntimeMedia(graph);
 const shapes=new FormSemantics(graph,new Map(graph.references.map(edge=>[JSON.stringify([edge.resource,edge.pointer,edge.keyword]),edge])));
 return async (owner:GraphScope,text:string):Promise<ParameterSerializationCheck>=>{

 if(owner.kind==='header'){
  const name=exampleHeaderName(graph,owner);
  if(name===undefined)throw new SourceError('example.header.context','This Header example needs an actual response field occurrence',[0,0],'unsupported');
  // Set-Cookie values are separate field lines; ordinary fields use one line.
  const values=name.toLowerCase()==='set-cookie'?text.replace(/\r?\n$/u,'').split(/\r?\n/u):[text];
  let decoded:ReturnType<typeof header>;
  try{
   if(values.some(value=>/[\x00-\x08\x0a-\x1f\x7f]/u.test(value)))throw new SourceError('runtime.response.header.serialization','The serialized header contains a prohibited HTTP field control');
   decoded=header({resource:owner.resource,pointer:owner.pointer,name,values});
  }catch(error){
   if(!(error instanceof SourceError)||error.code!=='runtime.response.header.serialization'||error.kind==='unsupported')throw error;
   return {complete:true,valid:false,findings:[{code:error.code,severity:'error',message:error.message}],instances:0};
  }
  if(!decoded)throw new SourceError('example.header.schema','This header representation has no captured evaluable schema',[0,0],'unsupported');
  const instance=decoded.instance;
  let subject='authored-example',pointer=owner.pointer;
  while(true){
   const kind=graph.scopes.get(owner.resource+'#'+pointer)?.kind;
   if(kind==='request-body'){subject='request-header';break;}
   if(kind==='response'){subject='response-header';break;}
   if(!pointer)break;pointer=pointer.slice(0,pointer.lastIndexOf('/'));
  }
  const checked=await evaluate([{...instance,subject,...(instance.mediaType?{unicodeSerialization:true}:{}),location:'example'}]);
  const valid=checked.complete&&checked.evaluations.length>0&&checked.evaluations.every(value=>value.valid===true);
  const complete=checked.complete&&checked.evaluations.length>0&&(decoded.complete||valid);
  return {complete,valid,findings:checked.findings,instances:checked.instances};
 }
 const occurrence=parameters.occurrence(owner),target=occurrence.definition;
 if(occurrence.state!=='resolved'||!target||occurrence.name===undefined||!occurrence.location)
  throw new SourceError('example.parameter.context','The captured Parameter example has no resolved native declaration',[0,0],'unsupported');
 const document=graph.docs.get(target.resource)!,node=document.dataNode(target.pointer)!,family=graph.scope(target.resource,target.pointer).family;
 if(!isNativeFamily(family)||family==='2.0')throw new SourceError('example.parameter.family','This Parameter declaration has no supported Example Object representation',[0,0],'unsupported');
 const value=node.value,name=occurrence.name,location=occurrence.location;
 const content:ExampleMedia[]=[];
 const media=document.dataNode(target.pointer+'/content');
 if(media?.kind==='object')for(const [type]of media.children){
  if(type.startsWith('x-'))continue;
  const source={resource:target.resource,pointer:target.pointer+'/content/'+escape(type)},selected=capture(source);
  content.push({mediaType:type,schema:selected.schema,itemSchema:selected.itemSchema,definition:source});
 }
 const declaration={name,in:location,family,...parameterStyle(family,location,value),required:value.required===true||location==='path',allowEmptyValue:value.allowEmptyValue===true,
  definition:{resource:target.resource,pointer:target.pointer,range:node.range},...(node.children.has('schema')?{schema:{resource:target.resource,pointer:target.pointer+'/schema'}}:{}),content};
 let instances=0,proofs=0;
 const result=await validateMockParameters(graph,{parameters:[declaration]},'/'+(location==='path'?'{'+name+'}':''),location==='path'?'/'+text:'/',
  location==='query'||location==='querystring'?text:'',location==='header'?{[name.toLowerCase()]:text}:location==='cookie'?{cookie:text}:{},async values=>{
   const checked=await evaluate(values.map(value=>({...value,...(value.mediaType?{unicodeSerialization:true}:{})})));instances+=checked.instances;proofs+=checked.evaluations.length;
   const evaluations=checked.evaluations.map(item=>{
    if(typeof item.subject!=='string'||typeof item.location!=='string'||typeof item.complete!=='boolean'||typeof item.valid!=='boolean')
     throw new SourceError('example.evaluation.protocol','The captured parameter evaluation returned an incomplete result identity');
    return {subject:item.subject,location:item.location,complete:item.complete,valid:item.valid};
   });
   return {complete:checked.complete,valid:checked.complete&&evaluations.every(item=>item.valid),evaluations,findings:checked.findings} satisfies NativeRuntimeCheck;
  },shapes);
 if(result.complete&&proofs===0&&result.findings.length===0&&text!=='')return {complete:true,valid:false,instances:0,
  findings:[{code:'runtime.request.parameter.serialization',severity:'error',message:'This serialization does not contain its named parameter value.'}]};
 const complete=result.complete&&(proofs>0||result.findings.some(finding=>finding.severity==='error'));
 return {complete,valid:complete&&result.valid,findings:result.findings,instances};
 };
}
