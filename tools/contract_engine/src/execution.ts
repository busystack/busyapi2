import {createHash} from 'node:crypto';

import {createGraph, propose, Resource} from './engine';
import {escape, SourceDocument, SourceError,type Range} from './document';
import {GraphTarget, ReferenceGraph, supportedSchemaDialect} from './reference_graph';
import {decimal} from './exact_numbers';
import {headerShapes} from './header_serialization';
import {ParameterOccurrence, ParameterSemantics} from './parameter_semantics';
import {responseStatusNamePolicy} from './member_names';
import {swaggerFlat,swaggerMedia,swaggerResponseContent,swaggerServers} from './swagger_operation';
import {componentLocation} from './authoring';
import {FormSemantics} from './form_semantics';
import {mediaTypeChoice} from './media_types';
import {MultipartEncoding,supportsMultipartTransfer,type MultipartTransfer,type MultipartHeaderCandidate} from './multipart_encoding';
import {evaluateSchemas} from './schema_evaluation';
import {runtimeMediaDescription} from './runtime_media';
import {ignoresRequestBody} from './operation_semantics';

const maximumItems = 2048;

/** Transport scalars from the existing strict JSON CST. Numeric leaves are
 * wire lexemes, never rounded JS (or Dart) machine-number projections. */
export function requestParameterValues(input:any) {
  if(!input.values||typeof input.values!=='object'||Array.isArray(input.values)||Object.keys(input.values).length>maximumItems)
    throw new SourceError('request.value.json','Expected bounded structured parameter values');
  const values=Object.fromEntries(Object.entries(input.values).map(([key,text])=>{
    if(typeof text!=='string')throw new SourceError('request.value.json','A structured parameter must be JSON text');
    const doc=new SourceDocument(text,'file:///busyapi-request-parameter.json');
    const visit=(node:any):any=>node.kind==='number'?doc.dataJson(node.pointer)
      :node.kind==='array'?[...node.children.values()].map(visit)
      :node.kind==='object'?Object.fromEntries([...node.children.entries()].map(([name,child])=>[name,visit(child)])):node.value;
    return [key,visit(doc.root)];
  }));
  return {version:1,values};
}

/** Exact execution data, never a contract projection. Array membership and
 * scalar kinds survive transport so a JSON string such as "0" is not silently
 * coerced to a number while preparing a form. Payload $ref keys remain data. */
export function requestFormDataValues(input:any) {
  if(typeof input.text!=='string'||Buffer.byteLength(input.text)>16*1024*1024)
    throw new SourceError('limit.request.form','Form data JSON exceeds 16 MiB');
  const doc=new SourceDocument(input.text,'file:///busyapi-form-value.json');
  if(doc.root.kind!=='object')throw new SourceError('request.form.shape','Form data must be a JSON object',doc.root.range);
  const wire=(node:any):any=>node.kind==='number'?doc.dataJson(node.pointer)
    :node.kind==='array'?[...node.children.values()].map(wire)
    :node.kind==='object'?Object.fromEntries([...node.children.entries()].map(([name,child])=>[name,wire(child)])):node.value;
  const value=(node:any):any=>({kind:node.kind,raw:doc.dataJson(node.pointer),text:node.kind==='string'?node.value:doc.dataJson(node.pointer),value:wire(node),
    ...(node.kind==='array'?{items:[...node.children.values()].map(value)}:{})});
  let count=0;
  const fields=[...doc.root.children.entries()].map(([name,node])=>{
    count+=node.kind==='array'?Math.max(1,node.children.size):1;
    if(count>maximumItems)throw new SourceError('limit.request.fields','Form data exceeds 2048 fields',node.range);
    return {name,...value(node)};
  });
  return {version:1,input:createHash('sha256').update(input.text).digest('hex'),raw:doc.dataJson(''),fields};
}

/** Saved execution inputs use the same canonical CST as manual exact values. */
export function executionCaseValues(input:any) {
  const source=input.source;
  if(!source || typeof source.text!=='string' || Buffer.byteLength(source.text)>65536) throw new SourceError('test.configuration','Expected bounded captured configuration');
  const doc=new SourceDocument(source.text,source.id),tests=doc.dataNode('/tests');
  const matches=[...(tests?.children.values()??[])].map(node=>doc.dataNode(node.pointer)!).filter(node=>node.value?.name===input.name);
  if(matches.length!==1) throw new SourceError('test.configuration','Selected case is not uniquely available');
  const selected=matches[0],parameters:any={};
  const exact=(physical:any)=>{
    const node=doc.dataNode(physical.pointer)!;
    if(typeof node.value==='string')return {text:node.value,json:false};
    const text=doc.dataJson(node.pointer),instance=new SourceDocument(text,'file:///busyapi-saved-value.json');
    for(const leaf of instance.nodes.values())if(leaf.kind==='number'){
      try {decimal(instance.dataJson(leaf.pointer));}
      catch(error){
        if(error instanceof SourceError){
          const pointer=node.pointer+leaf.pointer,original=doc.dataNode(pointer);
          throw new SourceError(error.code,source.id+' '+pointer+': '+error.message,original?.range??node.range);
        }
        throw error;
      }
    }
    return {text,json:true};
  };
  const groups=doc.dataNode(selected.pointer+'/parameters');
  if(groups&&groups.kind!=='object')throw new SourceError('test.configuration','Selected parameters must be an object',groups.range);
  for(const [location,physical] of groups?.children??[]) {
    const group=doc.dataNode(physical.pointer)!;
    if(group.kind!=='object')throw new SourceError('test.configuration','Selected parameter location '+location+' must be an object',group.range);
    for(const [name,node] of group.children) parameters[location+'\u0000'+name]=exact(node);
  }
  const body=doc.dataNode(selected.pointer+'/body/value');
  return {version:1,parameters,body:body?exact(body):undefined};
}

export function inspectExecutionJson(input:any) {
  if(typeof input.text!=='string'||Buffer.byteLength(input.text)>1024*1024) throw new SourceError('limit.inspection','JSON inspection is limited to 1 MiB');
  const doc=new SourceDocument(input.text,'file:///busyapi-inspection.json');
  let rendered=0;
  const bounded=(text:string)=>{rendered+=text.length;if(rendered>4*1024*1024)throw new SourceError('limit.inspection.output','Formatted inspection exceeds 4 MiB; use the raw preview');return text;};
  const pretty=(node:any,depth=0):string=>{
    if(depth>128) throw new SourceError('limit.inspection.depth','JSON inspection nesting exceeds 128');
    if(node.kind!=='object'&&node.kind!=='array') return bounded(doc.dataJson(node.pointer));
    const object=node.kind==='object',children=[...node.children.entries()];
    if(!children.length)return object?'{}':'[]';
    return (object?'{':'[')+'\n'+children.map(([name,child])=>bounded('  '.repeat(depth+1)+(object?JSON.stringify(name)+': ':''))+pretty(child,depth+1)).join(',\n')+'\n'+'  '.repeat(depth)+(object?'}':']');
  };
  return {version:1,pretty:pretty(doc.root),entries:[...doc.root.children.entries()].slice(0,2048).map(([name,node])=>({name,text:doc.dataJson(node.pointer)})),entriesComplete:doc.root.children.size<=2048};
}

export function planExecutionEnvironment(input:any) {
  const source=input.source;
  if(!source || typeof source.text!=='string' || Buffer.byteLength(source.text)>65536) throw new SourceError('environment.configuration','Expected captured configuration');
  const doc=new SourceDocument(source.text,source.id);
  if(typeof input.name!=='string'||!input.name.length||input.name.length>128) throw new SourceError('environment.name','Choose a bounded environment name');
  const target={resource:source.id,pointer:'',generation:source.generation,range:doc.root.range};
  const base='/environments/'+escape(input.name),actions:any[]=[];
  const set=(pointer:string,value:any)=>actions.push({kind:'set',pointer,value});
  const remove=(pointer:string)=>{if(doc.dataNode(pointer))actions.push({kind:'remove',pointer});};
  const definition=input.definition;
  if(!definition||typeof definition!=='object'||Array.isArray(definition))throw new SourceError('environment.definition','Expected environment settings');
  if(!doc.dataNode(base))set(base,definition);
  else {
    // Native setup owns its supported fields, not unrelated configuration or
    // rounded projections of existing source values. Patch canonical leaves.
    for(const [key,value] of Object.entries(definition)) {
      const pointer=base+'/'+escape(key);
      if(key==='authentication'&&value&&typeof value==='object'&&!Array.isArray(value)) {
        for(const [field,item] of Object.entries(value)) {
          if(field==='schemes'&&item&&typeof item==='object'&&!Array.isArray(item)) {
            for(const [name,settings] of Object.entries(item)) {
              const at=pointer+'/schemes/'+escape(name);
              if(settings&&typeof settings==='object'&&!Array.isArray(settings))for(const [setting,v] of Object.entries(settings))set(at+'/'+escape(setting),v);
              else set(at,settings);
            }
          } else set(pointer+'/'+escape(field),item);
        }
      } else if(key==='tls'&&value&&typeof value==='object'&&!Array.isArray(value)) {
        for(const field of ['caFile','clientCertificateFile','clientKeyFile','clientKeyPasswordRef']) {
          if(Object.hasOwn(value,field))set(pointer+'/'+escape(field),value[field]);
          else remove(pointer+'/'+escape(field));
        }
      } else set(pointer,value);
    }
    if(!Object.hasOwn(definition,'baseUrl'))remove(base+'/baseUrl');
  }
  const result=propose({...input,resources:[source],target,actions});
  let after=source.text;
  for(const edit of [...result.edits].reverse()) after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
  if(Buffer.byteLength(after)>65536)throw new SourceError('limit.manifest','Configuration exceeds 64 KiB');
  return {version:1,snapshot:input.snapshot,kind:'execution-environment',edits:result.edits,
    changes:[{resource:source.id,before:source.text,after}],usages:[],checkedRoots:[input.root],from:target,to:{resource:source.id,pointer:'/environments/'+escape(input.name)}};
}

type Located = {resource:string;pointer:string;generation:number;range:Range};

/** Resolve explicit part choices against the captured graph. No file extension,
 * payload sniffing, environment or credential participates in this decision. */
export function requestFormMediaTypes(input:any){
  if(!Array.isArray(input.parts)||input.parts.length>maximumItems||input.parts.some((name:unknown)=>typeof name!=='string')||
      !Array.isArray(input.files)||input.files.length>maximumItems||input.files.some((file:any)=>!file||typeof file.name!=='string'||typeof file.fallback!=='string'||file.selected!==undefined&&typeof file.selected!=='string')||
      !input.choices||typeof input.choices!=='object'||Array.isArray(input.choices)||Object.keys(input.choices).length>maximumItems||
      Object.values(input.choices).some(value=>typeof value!=='string'))
    throw new SourceError('request.form.content-type','Expected bounded named part media selections');
  const plan=requestOperation(input),content=plan.requestBody?.content.find((value:any)=>value.mediaType===input.mediaType);
  if(!content||!['multipart/form-data','application/x-www-form-urlencoded'].includes(input.mediaType.split(';')[0].trim().toLowerCase()))
    throw new SourceError('request.form.content-type','Select a captured form media declaration');
  const multipart=input.mediaType.split(';')[0].trim().toLowerCase()==='multipart/form-data',types:Record<string,string>=Object.create(null);
  const names=new Set<string>([...input.parts,...Object.keys(input.choices)]);
  const resolve=(name:string,choice?:string,fallback?:string)=>{
    const rule=content.encoding?.[name];
    if(choice!==undefined&&!content.swaggerForm&&!Object.hasOwn(content.form?.parts??{},name))
      throw new SourceError('request.form.content-type',`The selected part ${name} is absent from the captured form declaration`);
    const styled=(!multipart||content.form?.multipartStyle===true)&&['style','explode','allowReserved'].some(key=>Object.hasOwn(rule??{},key));
    if(styled){
      if(choice!==undefined)throw new SourceError('request.form.content-type',`Part ${name} uses style serialization; its Content-Type selection no longer applies`);
      return undefined;
    }
    if(rule?.contentType!==undefined){
      return mediaTypeChoice(rule.contentType,choice);
    }else if(choice!==undefined||fallback!==undefined){
      // An omitted contentType has its native default, rather than granting an
      // arbitrary alternative. Swagger has no per-part media restrictions.
      const property=content.form?.shape?.properties?.[name];
      const shape=property?.types?.includes('array')?property.items:property;
      return mediaTypeChoice(content.swaggerForm?'*/*':shape?.defaultContentType??content.form?.defaultContentType,choice??(content.swaggerForm?fallback:undefined));
    }
    return undefined;
  };
  for(const name of names){
    const type=resolve(name,Object.hasOwn(input.choices,name)?input.choices[name]:undefined);
    if(type!==undefined)types[name]=type;
  }
  const files=input.files.map((file:any)=>resolve(file.name,file.selected??(Object.hasOwn(input.choices,file.name)?input.choices[file.name]:undefined),file.fallback)??'text/plain');
  return {version:1,snapshot:input.snapshot,identity:plan.identity,types,files};
}

/** Resolve MIME transfer headers under their own captured Schema Objects. The
 * family evaluator checks candidate tokens; transport only implements codecs. */
export async function requestMultipartEncoding(input:any){
  if(!Array.isArray(input.parts)||input.parts.length>maximumItems||input.parts.some((part:any)=>!part||typeof part.name!=='string'||!['literal','string','other','item-string','item-other'].includes(part.kind))||
     !Array.isArray(input.files)||input.files.length>maximumItems||input.files.some((name:unknown)=>typeof name!=='string'))
    throw new SourceError('request.multipart.encoding','Expected bounded captured multipart field kinds');
  const captured=createGraph(input),plan=requestOperation(input,captured),content=plan.requestBody?.content.find((value:any)=>value.mediaType===input.mediaType);
  if(!content||input.mediaType.split(';')[0].trim().toLowerCase()!=='multipart/form-data')
    throw new SourceError('request.multipart.encoding','Select a captured named multipart declaration');
  const projection=new MultipartEncoding(captured.graph),media={...content.definition,kind:'media'},schema={...content.schema,kind:'schema'};
  const result:Record<string,{string?:MultipartTransfer;other?:MultipartTransfer}>=Object.create(null),candidates:{transfer:MultipartTransfer;header:MultipartHeaderCandidate;subjects:string[]}[]=[];
  const runtime:any[]=[];
  const part=(name:string,isString:boolean,array:boolean)=>{
    const output=result[name]??=(Object.create(null)),key=isString?'string':'other';
    if(output[key])return;
    if(content.swaggerForm){output[key]={schemaEncoded:false};return;}
    const transfer:MultipartTransfer=isString&&content.schema?projection.schemaEncoding(schema,name,array):{schemaEncoded:false};
    output[key]=transfer;
    const header=projection.header(media,name,transfer);
    if(!header){
      if(transfer.encoding!==undefined&&!supportsMultipartTransfer(transfer.encoding))projection.failure('request.multipart.encoding.unsupported','The native transport has no codec for the declared transfer encoding',transfer.source!);
      return;
    }
    const subjects=header.values.map(value=>{
      if(runtime.length>=maximumItems)throw new SourceError('limit.request.encoding','Multipart header evaluation exceeds 2048 candidates');
      const subject='multipart-header:'+runtime.length;
      runtime.push({subject,location:header.source.pointer,text:JSON.stringify(value),schema:header.schema});
      return subject;
    });
    candidates.push({transfer,header,subjects});
  };
  for(const field of input.parts){
    const property=content.form?.shape?.properties?.[field.name],array=field.kind.startsWith('item-')||field.kind==='literal'&&property?.literalType==='array',shape=array?property?.items:property;
    const literalString=!shape?.literalType||shape.literalType==='string';
    part(field.name,field.kind==='string'||field.kind==='item-string'||field.kind==='literal'&&literalString,array);
  }
  for(const name of input.files){
    const property=content.form?.shape?.properties?.[name];
    if(property?.types?.includes('array')&&property.types.some((type:string)=>type!=='array'&&type!=='null'))
      projection.failure('request.multipart.encoding.unsupported','A file under an array union requires an explicit part-shape selection',schema);
    part(name,true,property?.literalType==='array');
  }
  if(runtime.length){
    const checked=await evaluateSchemas({...input,runtimeInstances:runtime},undefined,captured);
    const evaluations=new Map(checked.runtimeEvaluations.map((value:any)=>[value.subject,value]));
    for(const {transfer,header,subjects}of candidates){
      if(subjects.some(subject=>evaluations.get(subject)?.complete!==true))projection.failure('request.multipart.encoding.unsupported','The transfer header schema could not be completely evaluated',header.source);
      const index=subjects.findIndex(subject=>evaluations.get(subject)?.valid===true);
      if(index<0)projection.failure(header.implicit?'request.multipart.encoding.undefined':header.literalExample?'request.multipart.header.invalid':'request.multipart.encoding.unsupported',header.implicit?'The explicit transfer header disallows the schema encoding':header.literalExample?'The literal transfer token does not satisfy its captured schema':'No implemented transfer token satisfies the captured header schema',header.source,header.implicit);
      const encoding=header.values[index];
      if(!supportsMultipartTransfer(encoding))projection.failure('request.multipart.encoding.unsupported','The native transport has no codec for the selected transfer token',header.source);
      transfer.encoding=encoding;
      transfer.source={resource:header.source.resource,pointer:header.source.pointer,range:captured.docs.get(header.source.resource)!.dataNode(header.source.pointer)!.range};
    }
  }
  return {version:1,snapshot:input.snapshot,identity:plan.identity,parts:result};
}

/**
 * A request plan is a located, immutable projection of one physical operation
 * occurrence.  It deliberately contains no credential or environment value.
 * Dart owns transport; this module owns OpenAPI interpretation and exact source
 * data.  In particular, examples are emitted as canonical CST JSON text rather
 * than as JavaScript values.
 */
export function requestOperation(input:any,captured?:ReturnType<typeof createGraph>) {
  const {docs,graph,family}=captured??createGraph(input);
  const generation=new Map((input.resources as Resource[]).map(resource=>[resource.id,resource.generation]));
  const operation=graph.scopes.get(input.resource+'#'+input.pointer);
  if(operation?.kind!=='operation')throw new SourceError('request.operation','Select an authored Operation Object');
  const contexts=graph.operationContexts(input.resource,input.pointer);
  const context=input.occurrence===undefined
    ?contexts.length===1?contexts[0]:undefined
    :contexts.find(candidate=>candidate.occurrence===input.occurrence);
  if(!context)throw new SourceError('request.occurrence',contexts.length?'Select the operation occurrence to execute':'The selected operation has no executable Paths occurrence');
  if(context.role!=='operation')throw new SourceError('request.role','Only a Paths operation can be sent as an HTTP request');
  const doc=docs.get(input.resource)!,node=doc.dataNode(input.pointer);
  if(!node||node.kind!=='object'||!doc.dataSyntaxSafe(input.pointer))throw new SourceError('request.operation','The selected operation is not a complete object');
  const location=(resource:string,pointer:string):Located=>{
    const owner=docs.get(resource),source=owner?.dataNode(pointer);
    if(!owner||!source)throw new SourceError('request.source','A required request declaration is unavailable');
    return {resource,pointer,generation:generation.get(resource)!,range:source.range};
  };
  const edgeIndex=new Map(graph.references.map(edge=>[JSON.stringify([edge.resource,edge.pointer,edge.keyword]),edge]));
  const forms=new FormSemantics(graph,edgeIndex);
  const follow=(target:GraphTarget,kind:string)=>{
    const seen=new Set<string>();let resource=target.resource,pointer=target.pointer;
    for(let depth=0;depth<128;depth++){
      const key=resource+'#'+pointer;if(seen.has(key))throw new SourceError('request.reference.cycle','A request declaration contains a reference cycle');seen.add(key);
      const current=docs.get(resource)?.dataNode(pointer);
      if(!current)throw new SourceError('request.source','A referenced request declaration is unavailable');
      if(typeof current.value?.$ref!=='string')return {resource,pointer,node:current,source:location(resource,pointer)};
      const edge=edgeIndex.get(JSON.stringify([resource,pointer,'$ref']));
      if(!edge||edge.kind!==kind||edge.resolution!=='resolved')throw new SourceError('request.reference','A referenced request declaration is unresolved');
      resource=edge.targetResource!;pointer=edge.targetPointer!;
    }
    throw new SourceError('limit.request.references','Request reference depth exceeds 128');
  };
  const raw=(resource:string,pointer:string)=>docs.get(resource)!.dataJson(pointer);
  const fieldRaw=(resource:string,pointer:string)=>docs.get(resource)!.dataJson(pointer,()=>undefined);
  const example=(resource:string,pointer:string,value:any,level='parameter',selectedName?:string)=>{
    const projected=(r:string,p:string,representation:string,name?:string)=>{
      const node=docs.get(r)!.dataNode(p)!;
      let conversionError:string|undefined;
      const canonical=(node:any)=>docs.get(r)!.dataNode(node.pointer)!;
      const fieldValue=(name:string,physical:any)=>{
        const child=canonical(physical);
        const rule=level==='media'?value?.encoding?.[name]:undefined;
        const styled=rule&&['style','explode','allowReserved'].some(k=>Object.hasOwn(rule,k));
        const type=styled?undefined:rule?.contentType?.split(';')[0].toLowerCase();
        if(rule&&(rule.encoding||rule.prefixEncoding||rule.itemEncoding)||type&&type!=='text/plain'&&type!=='application/json'&&!type.endsWith('+json'))
          conversionError='This data example requires an unsupported field encoding. Choose a serialized example or edit the literal representation.';
        if(type==='application/json'||type?.endsWith('+json'))return fieldRaw(r,child.pointer);
        if(child.kind==='object'||child.kind==='array'){
          const property=level==='media'?forms.shape(resource,pointer+'/schema').properties?.[name]:undefined;
          const field=docs.get(r)!.dataNode(p+'/'+escape(name));
          const shape=field?.kind==='array'?property?.items:property;
          const types=shape?.types?.filter((type:string)=>type!=='null');
          if(types?.length!==1||types[0]!==child.kind)conversionError='This structured field needs an unambiguous schema or explicit JSON encoding. Choose a serialized example or edit the literal representation.';
        }
        if(type==='text/plain'&&(child.kind==='object'||child.kind==='array'))conversionError='A structured field cannot be converted to this declared text part automatically.';
        return typeof child.value==='string'?child.value:fieldRaw(r,child.pointer);
      };
      const fields=node.kind==='object'?Object.fromEntries([...node.children.entries()].map(([name,physical])=>{const child=canonical(physical);return [name,child.kind==='array'?[...child.children.values()].map(item=>fieldValue(name,item)):[fieldValue(name,child)]];})):undefined;
      const compositeFields=node.kind==='object'&&[...node.children.values()].some(physical=>{const child=canonical(physical);return child.kind==='object'||child.kind==='array'&&[...child.children.values()].some(physical=>{const item=canonical(physical);return item.kind==='object'||item.kind==='array';});});
      return {name,level,source:location(r,p),raw:representation==='serialized'?node.value:raw(r,p),representation,compositeFields,
        text:typeof node.value==='string'?node.value:raw(r,p),dataKind:typeof node.value==='string'?'string':node.kind,fields,conversionError:level==='media'?conversionError:undefined};
    };
    const owner=docs.get(resource)!;
    if(!selectedName&&Object.hasOwn(value??{},'example'))return projected(resource,pointer+'/example','json');
    const examples=owner.dataNode(pointer+'/examples');
    if(examples?.kind==='object')for(const [name,entry] of examples.children){
      if(selectedName!==undefined&&selectedName!==name)continue;
      let r=resource,p=pointer+'/examples/'+escape(name),v=entry.value;
      if(v&&typeof v==='object'&&typeof v.$ref==='string'){
        try{const selected=follow({resource:r,pointer:p,kind:'example'},'example');r=selected.resource;p=selected.pointer;v=selected.node.value;}catch{return;}
      }
      const field=family==='3.2'&&Object.hasOwn(v??{},'dataValue')?'dataValue':Object.hasOwn(v??{},'value')?'value':family==='3.2'&&Object.hasOwn(v??{},'serializedValue')?'serializedValue':undefined;
      if(field)return projected(r,p+'/'+escape(field),field==='serializedValue'?'serialized':'json',name);
    }
  };
  const examples=(resource:string,pointer:string,value:any,level='parameter')=>[
    ...(Object.hasOwn(value??{},'example')?[example(resource,pointer,value,level)]:[]),
    ...[...(docs.get(resource)!.dataNode(pointer+'/examples')?.children.keys()??[])].map(name=>example(resource,pointer,value,level,name)),
  ].filter(value=>value!==undefined);
  const annotationOnly=(value:any)=>value===true || value && typeof value==='object' && !Array.isArray(value) && Object.entries(value).every(([key,item])=>
    key==='default' || key==='examples' && Array.isArray(item) ||
    ['title','description','$comment','format'].includes(key) && typeof item==='string' ||
    ['deprecated','readOnly','writeOnly'].includes(key) && typeof item==='boolean');
  const schema=(resource:string,pointer:string,value:any)=>Object.hasOwn(value??{},'schema')
    ?{...location(resource,pointer+'/schema'),kind:'schema',unconstrained:supportedSchemaDialect(graph.scope(resource,pointer+'/schema'))&&annotationOnly(value.schema)}
    :undefined;
  const media=(resource:string,pointer:string,value:any)=>{
    if(!value||typeof value!=='object'||Array.isArray(value))return [];
    const entries:any[]=[];
    for(const [name,item] of Object.entries(value)){
      if(name.startsWith('x-'))continue;
      if(entries.length>=maximumItems)throw new SourceError('limit.request.media','Request media choices exceed 2048');
      const at=pointer+'/'+escape(name),selected=follow({resource,pointer:at,kind:'media'},'media'),v=selected.node.value;
      const projectedExamples=examples(selected.resource,selected.pointer,v,'media').map(e=>({...e,mediaType:name,
        conversionError:['application/x-www-form-urlencoded','multipart/form-data'].includes(name.split(';')[0].trim().toLowerCase())?e.conversionError:undefined}));
      const mediaFamily=graph.scope(selected.resource,selected.pointer).family;
      entries.push({mediaType:name,...runtimeMediaDescription(name),family:mediaFamily,source:location(resource,at),definition:selected.source,schema:schema(selected.resource,selected.pointer,v),itemSchema:mediaFamily==='3.2'&&Object.hasOwn(v??{},'itemSchema')?{...location(selected.resource,selected.pointer+'/itemSchema'),kind:'schema'}:undefined,example:projectedExamples[0],examples:projectedExamples,
        form: ['application/x-www-form-urlencoded','multipart/form-data'].includes(name.split(';')[0].trim().toLowerCase())?forms.media(mediaFamily,selected.resource,selected.pointer,name):undefined,
        prefixEncoding:v?.prefixEncoding,itemEncoding:v?.itemEncoding,encoding:v?.encoding&&typeof v.encoding==='object'?Object.fromEntries(Object.entries(v.encoding).slice(0,maximumItems)):undefined});
    }
    return entries;
  };
  const parameters=new ParameterSemantics(graph).operation(input.resource,input.pointer,context.pathItem);
  if(!parameters.complete||!parameters.valid)throw new SourceError('request.parameters','Effective parameters are incomplete or invalid');
  const parameter=(entry:ParameterOccurrence)=>{
    if(entry.state!=='resolved'||!entry.definition||entry.name===undefined||!entry.location)throw new SourceError('request.parameter','An effective parameter is incomplete');
    const selected=follow(entry.definition,'parameter'),v=selected.node.value;
    const defaultStyle=entry.location==='query'||entry.location==='cookie'?'form':'simple';
    const defaultExplode=(entry.location==='query'||entry.location==='cookie')&&(v.style===undefined||v.style==='form'||family==='3.2'&&v.style==='cookie');
    const content=v.content&&typeof v.content==='object'?media(selected.resource,selected.pointer+'/content',v.content):[];
    return {name:entry.name,in:entry.location,family,type:typeof v.schema?.type==='string'?v.schema.type:undefined,description:v.description,required:v.required===true||entry.location==='path',deprecated:v.deprecated===true,
      style:typeof v.style==='string'?v.style:defaultStyle,explode:typeof v.explode==='boolean'?v.explode:defaultExplode,
      allowReserved:v.allowReserved===true,allowEmptyValue:v.allowEmptyValue===true,source:location(entry.source.resource,entry.source.pointer),definition:selected.source,
      schema:schema(selected.resource,selected.pointer,v),content,example:example(selected.resource,selected.pointer,v),examples:examples(selected.resource,selected.pointer,v),
      ...(family==='2.0'&&entry.location!=='body'?swaggerFlat(v,selected.source):{})};
  };
  const pathView=graph.pathItem(context.pathItem);
  if(!pathView.complete||!pathView.chainComplete)throw new SourceError('request.path-item','The selected Path Item inheritance is incomplete');
  const effectiveField=(name:string,root=true)=>{
    if(node.children.has(name))return {resource:input.resource,pointer:input.pointer+'/'+name,origin:'operation'};
    const inherited=pathView.fields.get(name);if(inherited)return {...inherited,origin:'path-item'};
    const rootDoc=docs.get(graph.root)!;if(root&&rootDoc.root.children.has(name))return {resource:graph.root,pointer:'/'+name,origin:'root'};
  };
  const serverField=effectiveField('servers');
  const servers:any[]=[];
  if(serverField){
    const list=docs.get(serverField.resource)!.dataNode(serverField.pointer);
    if(list?.kind!=='array')throw new SourceError('request.servers','Effective servers must be an array');
    for(const [index,server] of list.children){
      if(servers.length>=maximumItems)throw new SourceError('limit.request.servers','Server choices exceed 2048');
      if(server.kind!=='object'||typeof server.value?.url!=='string')continue;
      const pointer=serverField.pointer+'/'+index;
      servers.push({url:server.value.url,description:typeof server.value.description==='string'?server.value.description:undefined,
        variables:server.value.variables&&typeof server.value.variables==='object'?Object.fromEntries(Object.entries(server.value.variables).map(([name,value]:any)=>[name,{default:value?.default,enum:Array.isArray(value?.enum)?value.enum:undefined,description:value?.description}])):{},
        base:graph.retrievals.get(serverField.resource),source:location(serverField.resource,pointer),origin:serverField.origin});
    }
  }
  if(family==='2.0')servers.push(...swaggerServers(graph,input.resource,input.pointer,location));
  else if(!serverField || serverField.origin==='root' && docs.get(serverField.resource)!.dataNode(serverField.pointer)?.children.size===0)
    servers.push({url:'/',variables:{},base:graph.retrievals.get(graph.root),origin:'default'});
  const securityField=effectiveField('security',false)??(docs.get(graph.root)!.root.children.has('security')?{resource:graph.root,pointer:'/security',origin:'root'}:undefined);
  const schemes=new Map<string,Record<string,unknown>>();
  const requirements:any[]=[];
  if(securityField){
    const list=docs.get(securityField.resource)!.dataNode(securityField.pointer);
    if(list?.kind!=='array')throw new SourceError('request.security','Effective security requirements must be an array');
    for(const [index,requirement] of list.children){
      if(requirement.kind!=='object')throw new SourceError('request.security','A security requirement must be an object');
      const names=[...requirement.children.keys()];requirements.push({schemes:names,scopes:Object.fromEntries(names.map(name=>[name,requirement.value[name]])),source:location(securityField.resource,securityField.pointer+'/'+index)});
      for(const name of names)if(!schemes.has(name)){
        const occurrence=location(securityField.resource,securityField.pointer+'/'+index+'/'+escape(name));
        const binding=edgeIndex.get(JSON.stringify([securityField.resource,securityField.pointer+'/'+index,name]));
        if(binding?.connection!=='security'||binding.resolution!=='resolved')
          throw new SourceError('request.security.scheme','A selected security requirement names an unresolved scheme',occurrence.range,undefined,occurrence);
        const selected=follow({resource:binding.targetResource!,pointer:binding.targetPointer!,kind:'security'},'security'),v=selected.node.value;
        // The graph owns entry-name precedence, relative URI bases and capture
        // ownership (OAS 3.2 §§4.30,6.3). Do not repeat component-name lookup.
        const source=binding.targetUri===undefined?location(binding.targetResource!,binding.targetPointer!):occurrence;
        schemes.set(name,{name,type:family==='2.0'&&v?.type==='basic'?'http':v?.type,description:v?.description,source,definition:selected.source,
          ...(v?.type==='apiKey'?{in:v.in,parameterName:v.name}:{}),...(v?.type==='http'?{scheme:v.scheme,bearerFormat:v.bearerFormat}:{}),
          ...(family==='2.0'&&v?.type==='basic'?{scheme:'basic'}:{}),
          ...(v?.type==='openIdConnect'?{openIdConnectUrl:v.openIdConnectUrl}:{}),
          ...(v?.type==='oauth2'?{flows:family==='2.0'?{[({implicit:'implicit',password:'password',application:'clientCredentials',accessCode:'authorizationCode'} as Record<string,string>)[v.flow]]:{authorizationUrl:v.authorizationUrl,tokenUrl:v.tokenUrl,scopes:v.scopes,source:selected.source}}:oauthFlows(selected.resource,selected.pointer,v.flows,location)}:{}),
          ...(v?.type==='mutualTLS'?{mutualTLS:true}:{})});
      }
    }
  }
  const bodyField=node.children.has('requestBody')?{resource:input.resource,pointer:input.pointer+'/requestBody'}:undefined;
  const method=context.customMethod?context.method:context.method.toUpperCase();
  const ignoredRequestBody=bodyField&&ignoresRequestBody(operation.family,method)
    ?{method,reason:'oas30-http-method',source:location(bodyField.resource,bodyField.pointer)}:undefined;
  let requestBody:any;
  if(bodyField&&!ignoredRequestBody){const selected=follow({...bodyField,kind:'request-body'},'request-body'),v=selected.node.value;requestBody={required:v?.required===true,source:location(bodyField.resource,bodyField.pointer),definition:selected.source,content:media(selected.resource,selected.pointer+'/content',v?.content)};}
  if(family==='2.0'){
    const projected=parameters.visible.map(parameter),body=projected.find(p=>p.in==='body'),form=projected.filter(p=>p.in==='formData');
    const consumes=swaggerMedia(graph,input.resource,input.pointer,'consumes');
    if(body)requestBody={required:body.required,source:body.source,definition:body.definition,content:consumes.map(mediaType=>({mediaType,...runtimeMediaDescription(mediaType),source:body.source,definition:body.definition,schema:body.schema,examples:[]}))};
    else if(form.length)requestBody={required:form.some(p=>p.required),source:location(input.resource,input.pointer),definition:location(input.resource,input.pointer),content:consumes.map(mediaType=>({mediaType,...runtimeMediaDescription(mediaType),source:location(input.resource,input.pointer),swaggerForm:form,examples:[]}))};
  }
  const headerShape=headerShapes(graph);
  const responses:any[]=[];
  const responseNode=node.children.get('responses');
  if(responseNode?.kind!=='object')throw new SourceError('request.responses','The operation has no usable Responses Object');
  for(const [status,response] of responseNode.children){
    if(status.startsWith('x-'))continue;
    const at=input.pointer+'/responses/'+escape(status),selected=follow({resource:input.resource,pointer:at,kind:'response'},'response'),v=selected.node.value;
    const headers:any[]=[];
    if(v?.headers&&typeof v.headers==='object')for(const name of Object.keys(v.headers)){
      if(name.toLowerCase()==='content-type')continue;
      const hp=selected.pointer+'/headers/'+escape(name),header=follow({resource:selected.resource,pointer:hp,kind:'header'},'header'),hv=header.node.value;
      headers.push({name,family,required:hv?.required===true,source:location(selected.resource,hp),definition:header.source,style:hv?.style??'simple',explode:hv?.explode===true,content:media(header.resource,header.pointer+'/content',hv?.content),schema:schema(header.resource,header.pointer,hv),shape:headerShape({resource:header.resource,pointer:family==='2.0'?header.pointer:header.pointer+'/schema',kind:'schema'}),...(family==='2.0'?swaggerFlat(hv,header.source):{})});
    }
    responses.push({status,source:location(input.resource,at),definition:selected.source,description:v?.description,headers,content:family==='2.0'?swaggerResponseContent(graph,selected.resource,selected.pointer,swaggerMedia(graph,input.resource,input.pointer,'produces'),location).map(item=>({...item,...runtimeMediaDescription(item.mediaType)})):media(selected.resource,selected.pointer+'/content',v?.content)});
  }
  const identity=createHash('sha256').update(JSON.stringify([input.snapshot,input.resource,input.pointer,context.occurrence])).digest('hex');
  return {version:1,snapshot:input.snapshot,root:input.root,identity,family,operation:{method,customMethod:context.customMethod===true,path:context.path,
    operationId:typeof node.value.operationId==='string'?node.value.operationId:undefined,summary:typeof node.value.summary==='string'?node.value.summary:undefined,
    source:location(input.resource,input.pointer),occurrence:context.occurrence,pathItem:location(context.pathItem.resource,context.pathItem.pointer)},
    servers,parameters:parameters.visible.filter(entry=>family!=='2.0'||!['body','formData'].includes(entry.location!)).map(parameter),security:{requirements,schemes:Object.fromEntries(schemes),anonymous:requirements.some(requirement=>requirement.schemes.length===0)||!securityField},requestBody,ignoredRequestBody,responses,responseStatusNamePolicy:responseStatusNamePolicy(family),
    producer:'busyapi-contract-engine',producerVersion:'0.1.0',complete:true};
}

/** Feature inventory for an external semantic comparator.  This is not a
 * validity result: it prevents a quiet empty oasdiff result from being called
 * complete where the pinned adapter documents incomplete coverage. */
export function semanticDiffCoverage(input:any) {
  const {graph}=createGraph(input);
  const dynamicReferences=graph.references.filter(reference=>reference.keyword==='$dynamicRef').map(reference=>({resource:reference.resource,pointer:reference.pointer}));
  const reusablePathItems=[...graph.scopes.values()].filter(scope=>scope.kind==='path-item'&&scope.pointer.startsWith('/components/pathItems/')).map(scope=>({resource:scope.resource,pointer:scope.pointer}));
  return {version:1,snapshot:input.snapshot,complete:true,dynamicReferences,reusablePathItems,
    coverage:{ordinaryOperations:'oasdiff-1.33.0',dynamicReferences:dynamicReferences.length?'unclassified':'not-present',reusablePathItems:reusablePathItems.length?'unclassified':'not-present'}};
}

/** Create a reviewable source edit for one explicitly selected, user-redacted
 * JSON response body. The response remains ordinary data: references inside it
 * are never resolved and exact numeric lexemes flow through setExample. */
export function planResponseExample(input:any) {
  const {docs,graph}=createGraph(input),target=input.target,doc=docs.get(target?.resource);
  const resource=(input.resources as Resource[]).find(resource=>resource.id===target?.resource);
  const node=doc?.nodes.get(target?.pointer),scope=doc&&graph.scopes.get(doc.id+'#'+target.pointer);
  if(!doc||!node||!resource||resource.generation!==target.generation||!(scope?.kind==='media'||scope?.family==='2.0'&&scope.kind==='response'))
    throw new SourceError('example.destination','The selected response media declaration is no longer current');
  if(typeof input.raw!=='string'||Buffer.byteLength(input.raw)>1024*1024)
    throw new SourceError('limit.example','A saved response example must be at most 1 MiB');
  const sample=new SourceDocument(input.raw,'file:///busyapi-reviewed-response-example.json');
  const exact=sample.dataJson('');
  if(scope.family==='2.0'&&(typeof input.mediaType!=='string'||!input.mediaType.includes('/')))throw new SourceError('example.media','Select the response example media type');
  const pointer=target.pointer+(scope.family==='2.0'?'/examples/'+escape(input.mediaType):'/example');
  const result=propose({...input,target,actions:[{kind:'setExample',pointer,raw:exact}]});
  let after=resource.text;
  for(const edit of [...result.edits].reverse())after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
  return {version:1,snapshot:input.snapshot,edits:result.edits,
    changes:result.edits.length?[{resource:resource.id,before:resource.text,after}]:[],usages:[],
    from:target,to:{resource:target.resource,pointer},checkedRoots:[input.root],kind:'response-example',
    redacted:input.redacted===true,bodyIdentity:createHash('sha256').update(input.raw).digest('hex')};
}

function oauthFlows(resource:string,pointer:string,flows:any,location:(resource:string,pointer:string)=>Located){
  if(!flows||typeof flows!=='object')return {};
  const result:any={};
  for(const name of ['implicit','password','authorizationCode','clientCredentials','deviceAuthorization'])if(flows[name]&&typeof flows[name]==='object'){
    const value=flows[name],at=pointer+'/flows/'+name;
    result[name]={authorizationUrl:value.authorizationUrl,tokenUrl:value.tokenUrl,refreshUrl:value.refreshUrl,
      scopes:value.scopes&&typeof value.scopes==='object'?value.scopes:{},source:location(resource,at)};
  }
  return result;
}
