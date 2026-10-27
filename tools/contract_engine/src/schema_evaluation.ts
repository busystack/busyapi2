import {createHash} from 'node:crypto';
import {addMediaTypePlugin,addUriSchemePlugin} from '@hyperjump/browser';
import {registerSchema,unregisterSchema,getAllRegisteredSchemaUris,setShouldValidateSchema,setShouldValidateFormat} from '@hyperjump/json-schema/draft-2020-12';
import '@hyperjump/json-schema/openapi-3-1';
import '@hyperjump/json-schema/openapi-3-2';
import '@hyperjump/json-schema/openapi-3-0';
import {compile,interpret,getSchema,toSchema,loadDialect,unloadDialect,BASIC} from '@hyperjump/json-schema/experimental';
import dialect31 from '../schemas/oas31-dialect.json';
import vocabulary31 from '../schemas/oas31-vocabulary.json';
import dialect32 from '../schemas/oas32-dialect.json';
import vocabulary32 from '../schemas/oas32-vocabulary.json';
import previousDialect32 from '../schemas/oas32-dialect-2025-09-17.json';
import previousVocabulary32 from '../schemas/oas32-vocabulary-2025-09-17.json';
import {createGraph} from './engine';
import {knownDialects,supportedSchemaDialect,GraphScope,schemaAddress,schemaDialectIdentity} from './reference_graph';
import {SourceDocument,SourceError,escape} from './document';
import {createExactNumericAdapter} from './exact_numbers';
import {evaluateRuntimeInstances} from './runtime_evaluation';
import {typedSchemaDocument,embeddedSchemaDocument} from './schema_document';
import {safeFinding} from './security_design';
import {schemaRoots,nestedSchemaBoundaries} from './schema_boundaries';
import {discriminatorRelationships} from './authoring_relationships';
import {restrictedSchemaDialect,swaggerSchemaDialect,modernFamily} from './specification';
import {installSwaggerSchemaDialect,schemaEvaluationScopes,swaggerMetaAddress,swaggerMetaIdentity,SchemaEvaluationScope} from './swagger_schema';
import {swaggerFileContexts} from './swagger_file';
import {evaluateSerializedExamples} from './serialized_examples';
import {exampleRepresentation,mediaExampleRepresentations,type ExampleValueField} from './example_representation';

export const schemaProducer={name:'hyperjump+busyapi-exact',version:'1.18.0+35',configuration:[
 'oas20-draft4-restricted','structural20-2017-08-27','oas30-restricted','structural30-2024-10-18',
 'draft2020-12','structural31-2026-08-03','structural32-2026-08-30',
 'oas31-2024-11-10','oas32-2026-02-26','oas32-2025-09-17','format-annotation',
 'exact-cst-v5','canonical-graph-addresses','runtime-media-v2','runtime-alternatives-v1','swagger-header-wire-v1','response-header-wire-v2','form-context-v1','example-serialization-coverage-v2','evaluation-stage-coverage-v1','parameter-example-serialization-v1','literal-media-examples-v1','dialect-resource-identity-v1','dialect-declaration-v1','schema-access-occurrence-v1',
 'reference-family-v1','reference-position-v1','schema-context-v1','multipart-position-v1','generic-named-multipart-v1','binary-instance-v1','body-media-owner-v1','legacy-binary-media-v1','swagger-file-body-v1','mime-framing-v1','swagger-file-media-v1','mime-header-content-v1','serialized-media-examples-v1','multipart-header-values-v1','multipart-file-shapes-v1','media-description-v1','component-names-v1','security-bindings-v2','response-status-v1','response-content-presence-v1',
].join(':')};
let configured=false,running=false;
const standardIds=new Set<string>(),reservedIds=new Set<string>(),standardMetas=new Map<string,any>();
const standardSources=new Map<string,any>();
function standards() {
 if(configured)return;
 installSwaggerSchemaDialect();
 registerSchema(previousVocabulary32);registerSchema(previousDialect32);
 loadDialect(previousDialect32.$id,previousDialect32.$vocabulary,true);
 for(const [family,dialect,vocabulary]of [['3.1',dialect31,vocabulary31],['3.2',dialect32,vocabulary32]] as any[]) {
  registerSchema(vocabulary);
  const alias=`https://spec.openapis.org/oas/${family}/dialect/base`;
  unregisterSchema(alias);registerSchema(dialect,alias);registerSchema(dialect);
  loadDialect(alias,dialect.$vocabulary,true);loadDialect(dialect.$id,dialect.$vocabulary,true);
 }
 // The library's automatic meta path builds rounded JS instances. Every
 // authored schema is instead explicitly meta-evaluated from canonical CST
 // before any instance compilation below. Official meta-schemas are bundled.
 setShouldValidateSchema(false);setShouldValidateFormat(false);
 for(const uri of getAllRegisteredSchemaUris()) {
  reservedIds.add(uri);
  if(uri.startsWith('https://json-schema.org/draft/2020-12/')||uri.startsWith('http://json-schema.org/draft-04/')||knownDialects.has(uri)||uri===swaggerMetaIdentity||[vocabulary31.$id,vocabulary32.$id,previousVocabulary32.$id].includes(uri))standardIds.add(uri);
 }
 configured=true;
}
const within=(pointer:string,parent:string)=>pointer===parent||pointer.startsWith(parent+'/');

/** The core may acquire a bundled standard as an immutable, read-only resource.
 * This allowlist never invokes a default network/filesystem loader. The public
 * vendor API serializes only trusted shipped schema artifacts, not user data. */
export async function standardResource(input:any) {
 standards();
 if(input.list===true)return {version:1,identities:[...standardIds].sort()};
 if(typeof input.uri!=='string')return {version:1,found:false};
 const uri=schemaDialectIdentity(input.uri);
 if(!standardIds.has(uri))return {version:1,found:false};
 let source=standardSources.get(uri);
 if(!source) {
  const schema=await getSchema(uri),id=schema.document.baseUri;
  const text=JSON.stringify(toSchema(schema,{includeDialect:'always',contextUri:id}));
  source={id,text,identity:createHash('sha256').update(text).digest('hex'),generation:0,hasBom:false,bundled:true,
   aliases:uri===id?[]:[uri],producer:'@hyperjump/json-schema',producerVersion:'1.18.0'};
  standardSources.set(uri,source);
 }
 return {version:1,found:true,source};
}

/** Draft/dialect evaluation is separate from structural OAS checks and from
 * dynamic-reference navigation. Only supplied, approved snapshots are used;
 * the validator's URI plugins cannot acquire files, network or credentials. */
export async function evaluateSchemas(input:any,observeFailure?:(error:unknown)=>void,context?:ReturnType<typeof createGraph>) {
 if(running)throw new SourceError('schema.busy','This worker already owns a schema evaluation');
 running=true;
 const exact=createExactNumericAdapter(standardIds),schemes=new Set<string>(),ownedIds=new Set<string>(),documents=new Map<string,any>();
 let open=true,complete=true,limited=false;
 const findings:any[]=[],evaluations:any[]=[],runtimeEvaluations:any[]=[],runtimeFindings:any[]=[],skipped:any[]=[],invalid:any[]=[],compiled=new Map<string,any>(),metas=new Map<string,any>();
 let schemas=0,instances=0;
 const add=(doc:SourceDocument,pointer:string,code:string,message:string,severity='error',details:any={})=>{
  if(findings.length>=200&&!code.startsWith('limit.')){limited=true;complete=false;return;}
  let owner=pointer;while(owner&&!doc.nodes.has(owner))owner=owner.slice(0,owner.lastIndexOf('/'));
  const authored=doc.nodes.get(pointer),source=authored??doc.dataNode(pointer),physical=source?.pointer??pointer;
  const range=source?.range??doc.nodes.get(owner)?.range??doc.root.range;
  findings.push({version:1,category:'openapi',root:input.root,resource:doc.id,pointer:physical,range,code,severity,...safeFinding(message,physical),...details,
   ...(physical!==pointer?{occurrencePointer:safeFinding('',pointer).pointer}:{}),
   producer:schemaProducer.name,producerVersion:schemaProducer.version,configuration:schemaProducer.configuration,snapshot:input.snapshot,
   id:createHash('sha256').update(JSON.stringify([input.root,doc.id,pointer,code,details.keyword,details.schema])).digest('hex')});
 };
 try {
  standards();exact.install();
  const {docs,graph}=context??createGraph(input);
  const bundled=new Set<string>();
  for(const resource of input.resources)if(resource.bundled===true) {
   const expected=await standardResource({uri:resource.id});
   if(!expected.found||resource.text!==expected.source.text)throw new SourceError('schema.identity.conflict','A supplied resource differs from its claimed bundled standard');
   bundled.add(resource.id);
  }
  const root=docs.get(input.root)!;
  // The validator's bundled standard registry is an explicit trusted resource
  // capability, not permission to retrieve an arbitrary remote URI. Graph
  // acquisition does not include those built-ins in the project's file set.
  const bundledReferences=new Set(graph.references.filter(ref=>ref.resolution==='unavailable'&&standardIds.has(ref.targetUri!)).map(ref=>ref.resource+'#'+ref.pointer+'/'+escape(ref.keyword)));
  if([...docs.values()].some(doc=>doc.issues.length)||graph.issues.some(issue=>issue.incomplete&&!bundledReferences.has(issue.resource+'#'+issue.pointer)))complete=false;
  for(const issue of graph.issues)if((issue.kind==='schema'||issue.code==='reference.cycle'||issue.code==='schema.dialect.malformed')&&!bundledReferences.has(issue.resource+'#'+issue.pointer)) {
   add(docs.get(issue.resource)!,issue.pointer,issue.code,issue.message,issue.severity??(issue.incomplete?'warning':'error'));
   if(!issue.incomplete&&issue.kind==='schema')invalid.push(graph.scope(issue.resource,issue.pointer));
  }
  const all=schemaEvaluationScopes(graph).filter(scope=>!bundled.has(scope.resource));
  const evaluationScopes=new Map(all.map(scope=>[scope.resource+'#'+scope.pointer,scope]));
  for(const reference of swaggerFileContexts(graph).invalidReferences){
   invalid.push(graph.scope(reference.resource,reference.pointer));
   add(docs.get(reference.resource)!,reference.pointer+'/$ref','schema.file.context','Swagger file schemas are only permitted at a response schema root; this reference uses the fragment in another schema position.');
  }
  for(const issue of discriminatorRelationships(graph))
   add(docs.get(issue.resource)!,issue.pointer,issue.code,issue.message);
  if(all.length>20000)throw new SourceError('limit.schema.count','Schema evaluation exceeds 20000 authored schema locations');
  const failed=(doc:SourceDocument,pointer:string,error:any)=>{
   observeFailure?.(error);
   complete=false;
   const code=error instanceof SourceError?error.code:'schema.execution.incomplete';
   add(doc,pointer,code,'Schema evaluation did not complete for this source scope. No clean result is inferred from the failed evaluation.','warning');
  };
  for(const [uri,targets]of graph.identities) {
   if(targets.length!==1){complete=false;continue;}
   if(reservedIds.has(uri)) {
    if(bundled.has(targets[0].resource))continue;
    throw new SourceError('schema.identity.conflict','A supplied resource identity conflicts with a bundled schema-dialect identity');
   }
   ownedIds.add(uri);
   schemes.add(new URL(uri).protocol.slice(0,-1));
  }
  // Override even unused conventional protocols: no default file/fetch loader
  // remains reachable through a third-party resolution path.
  for(const scheme of ['file','http','https',...schemes]) {
   schemes.add(scheme);
   addUriSchemePlugin(scheme,{retrieve:async (reference:string)=>{
    if(!open)throw new SourceError('schema.owner','The evaluation snapshot is closed');
    const uri=new URL(reference);uri.hash='';
    const targets=graph.identities.get(uri.href);
    if(targets?.length!==1)throw new SourceError('resource.unapproved','The validator requested an unavailable or ambiguous resource identity');
    const target=targets[0],doc=docs.get(target.resource)!;
    // The media-type callback reads this operation's captured CST directly.
    // Response carries its approved identity. Materializing a body here would
    // encode the entire file again for every independently compiled schema.
    const response=new Response(null,{headers:{'content-type':'application/vnd.busyapi.schema-snapshot+json'}});
    Object.defineProperty(response,'url',{value:uri.href});return response;
   }});
  }
  addMediaTypePlugin('application/vnd.busyapi.schema-snapshot+json',{fileMatcher:async()=>false,parse:async (response:Response)=>{
   if(!open)throw new SourceError('schema.owner','The evaluation snapshot is closed');
   const target=graph.identities.get(response.url)?.[0],doc=target&&docs.get(target.resource);
   if(!doc)throw new SourceError('resource.unapproved','The schema snapshot is unavailable');
   let document=documents.get(doc.id);
   if(!document){document=typedSchemaDocument(doc.root.value,doc.id,graph,graph.scope(doc.id,'').dialect);documents.set(doc.id,document);}
   const scope=graph.scope(doc.id,target.pointer);
   const selected=embeddedSchemaDocument(document,scope.base);
   if(!selected)throw new SourceError('schema.resource','The schema resource boundary is unavailable');
   return selected;
  }});
  for(const doc of docs.values())exact.addExactSource(doc,graph);
  // A parent meta-schema checks its nested schemas. Distinct dialect/resource
  // roots need their own explicit check; siblings stay independently eligible.
  const roots=schemaRoots(all),nestedBoundaries=nestedSchemaBoundaries(roots);
  for(const scope of roots) {
   const doc=docs.get(scope.resource)!;
   if(!supportedSchemaDialect(scope)){complete=false;invalid.push(scope);add(doc,scope.pointer,'schema.dialect.incomplete','This schema dialect is not configured; its content is preserved and no instance result is claimed.','warning');continue;}
   if(!doc.dataSyntaxSafe(scope.pointer)){complete=false;invalid.push(scope);continue;}
   try {
    const metaId=scope.family==='2.0'?swaggerMetaAddress(evaluationScopes.get(scope.resource+'#'+scope.pointer)!):scope.dialect;
    let meta=metas.get(metaId)??standardMetas.get(metaId);
    if(!meta){meta=await compile(await getSchema(metaId));standardMetas.set(metaId,meta);}
    metas.set(metaId,meta);
    const nested=nestedBoundaries(scope);
    const result:any=interpret(meta,exact.exactInstance(doc,scope.pointer,nested,[restrictedSchemaDialect,swaggerSchemaDialect].includes(scope.dialect)),BASIC);
    schemas++;
    if(!result.valid) {
     invalid.push(scope);
     for(const error of result.errors.slice(0,32)) {
      const fragment=new URL(error.instanceLocation).hash.slice(1),pointer=scope.pointer+decodeURIComponent(fragment);
      add(doc,pointer,'schema.keyword.invalid','This authored value does not satisfy the selected schema dialect meta-schema.','error',{keyword:error.keyword});
     }
    }
   }catch(error){invalid.push(scope);failed(doc,scope.pointer,error);}
   if(limited)break;
  }
  // Propagate known invalid dependencies through the canonical schema graph.
  // A missing pointer in an available document is a diagnosed invalid
  // contract, not an unavailable analysis service. Unapproved/ambiguous inputs
  // remain incomplete. No exception-message guessing or alternate resolver.
  const states=new Map<string,number>(),dependents=new Map<string,Set<string>>(),queue:string[]=[];
  const scopeId=(scope:GraphScope)=>scope.resource+'#'+scope.pointer;
  const mark=(id:string,state:number)=>{if(state>(states.get(id)??0)){states.set(id,state);queue.push(id);}};
  let edgeCount=0;
  const depends=(owner:string,target:string)=>{
   if(++edgeCount>400000)throw new SourceError('limit.schema.dependencies','Schema dependency evaluation exceeds its bounded edge budget');
   const parents=dependents.get(target)??new Set<string>();parents.add(owner);dependents.set(target,parents);
  };
  for(const scope of all) {
   const id=scopeId(scope);let parent=scope.pointer;
   while(parent){parent=parent.slice(0,parent.lastIndexOf('/'));const candidate=graph.scopes.get(scope.resource+'#'+parent);if(candidate?.kind==='schema'){
    // Reserved definitions are not applicators. Their schema is required only
    // if an established reference reaches it; an unfamiliar unused $defs
    // resource cannot disable this independent parent's supported assertions.
    const keyword=scope.pointer.slice(parent.length+1).split('/')[0];
    if(!['$defs','definitions'].includes(keyword))depends(scopeId(candidate),id);
    break;
   }}
   if(invalid.some(ancestor=>ancestor.resource===scope.resource&&within(scope.pointer,ancestor.pointer)))mark(id,1);
   if(!supportedSchemaDialect(scope)||!docs.get(scope.resource)!.dataSyntaxSafe(scope.pointer))mark(id,2);
  }
  for(const ref of graph.references)if(ref.kind==='schema'&&!ref.connection) {
   const id=scopeId(ref);
   if(ref.resolution==='resolved') {
    const target=graph.scopes.get(ref.targetResource+'#'+ref.targetPointer);
    if(target?.kind==='schema')depends(id,scopeId(target));
   } else if(ref.resolution==='unavailable'&&standardIds.has(ref.targetUri!))continue;
   else mark(id,['missing','invalid'].includes(ref.resolution)?1:2);
  }
  for(let i=0;i<queue.length;i++)for(const parent of dependents.get(queue[i])??[])mark(parent,states.get(queue[i])!);
  const getCompiled=async(scope:GraphScope)=>{
   if(states.get(scopeId(scope))||evaluationScopes.get(scopeId(scope))?.file)return;
   const uri=schemaAddress(scope);if(!compiled.has(uri))compiled.set(uri,await compile(await getSchema(uri)));
   return compiled.get(uri);
  };
  // Compile every independently rooted authored schema, even when it has no
  // examples. Missing references/vocabularies cannot masquerade as success.
  for(const scope of roots) {
   if(limited)break;
   try{await getCompiled(scope);}catch(error){invalid.push(scope);failed(docs.get(scope.resource)!,scope.pointer,error);}
  }
  const examples:{schema:GraphScope,doc:SourceDocument,pointer:string,interpretation:string}[]=[];
  const mediaForms=mediaExampleRepresentations(graph);
  const skip=(value:any)=>{if(skipped.length>=20000){limited=true;complete=false;}else skipped.push(value);};
  const append=(schema:GraphScope,doc:SourceDocument,pointer:string,interpretation:string)=>{
   if(examples.length>=20000){limited=true;complete=false;return;}
   examples.push({schema,doc,pointer,interpretation});
  };
  for(const scope of all) {
   const doc=docs.get(scope.resource)!,list=doc.dataNode(scope.pointer+'/examples');
   if(list?.kind==='array')for(const index of list.children.keys())append(scope,doc,scope.pointer+'/examples/'+index,'schema-annotation');
   // These are annotations, not new normative instance assertions. Only an
   // explicitly selected governance rule asks to check legacy singular
   // example/default compatibility. Ordinary OpenAPI checks stay unchanged.
   if(input.policyAnnotations===true)for(const keyword of ['example','default'])
    if(doc.dataNode(scope.pointer+'/'+keyword))append(scope,doc,scope.pointer+'/'+keyword,'policy-annotation');
  }
  const mediaData=(scope:GraphScope,doc:SourceDocument,pointer:string,field:ExampleValueField)=>{
   const node=doc.dataNode(pointer);if(!node)return false;
   const form=mediaForms(scope,field,node.value);
   return form.data;
  };
  for(const scope of graph.scopes.values()) {
   if(scope.family==='2.0'&&scope.kind==='response') {
    const schema=graph.scopes.get(scope.resource+'#'+scope.pointer+'/schema'),doc=docs.get(scope.resource)!;
    if(schema?.kind==='schema')for(const name of doc.dataNode(scope.pointer+'/examples')?.children.keys()??[]){
     const pointer=scope.pointer+'/examples/'+escape(name),node=doc.dataNode(pointer)!;
     if(exampleRepresentation('swagger-response',node.value,name)==='json')append(schema,doc,pointer,'authored-data');
    }
    continue;
   }
   if(!['media','parameter','header'].includes(scope.kind))continue;
   const schema=graph.scopes.get(scope.resource+'#'+scope.pointer+'/schema');if(schema?.kind!=='schema')continue;
   const doc=docs.get(scope.resource)!,node=doc.dataNode(scope.pointer)!;
   if(node.children.has('example')&&(scope.kind!=='media'||mediaData(scope,doc,scope.pointer+'/example','example')))append(schema,doc,scope.pointer+'/example','authored-data');
   const named=doc.dataNode(scope.pointer+'/examples');
   if(named?.kind!=='object')continue;
   for(const [name,child] of named.children) {
    let owner=doc,pointer=scope.pointer+'/examples/'+escape(name),value=child.value;
    const seen=new Set<string>();
    while(value&&typeof value.$ref==='string') {
     const resolved=graph.resolveReference(value.$ref,graph.scope(owner.id,pointer));
     if(resolved.resolution!=='resolved'){complete=false;break;}
     const key=resolved.targetResource+'#'+resolved.targetPointer;
     if(seen.has(key)||seen.size>=128){complete=false;break;}seen.add(key);
     owner=docs.get(resolved.targetResource!)!;pointer=resolved.targetPointer!;value=owner.dataNode(pointer)!.value;
    }
    if(!value||typeof value!=='object'||typeof value.$ref==='string')continue;
    const field=graph.scope(owner.id,pointer).family==='3.2'&&Object.hasOwn(value,'dataValue')?'dataValue':Object.hasOwn(value,'value')?'value':undefined;
    if(field){if(scope.kind!=='media'||mediaData(scope,owner,pointer+'/'+escape(field),field))append(schema,owner,pointer+'/'+escape(field),'authored-data');}
    else if(!(modernFamily(scope.family)&&scope.kind==='media'&&graph.scope(owner.id,pointer).family==='3.2'&&Object.hasOwn(value,'serializedValue')))
     skip({resource:owner.id,pointer,reason:Object.hasOwn(value,'externalValue')?'external-value-not-retrieved':Object.hasOwn(value,'serializedValue')?'serialized-value-not-parsed':'no-authored-data'});
   }
  }
  for(const example of examples) {
   if(limited)break;
   const {doc,pointer,schema,interpretation}=example;
   if(!doc.dataSyntaxSafe(pointer)){complete=false;continue;}
   try {
    const ast=await getCompiled(schema);if(!ast){skip({resource:doc.id,pointer,reason:'associated-schema-invalid-or-incomplete'});continue;}
    const result:any=interpret(ast,exact.exactInstance(doc,pointer),BASIC);instances++;
    const physical=doc.dataNode(pointer)!.pointer;
    evaluations.push({resource:doc.id,pointer:physical,...(physical!==pointer?{occurrencePointer:pointer}:{}),schema:{resource:schema.resource,pointer:schema.pointer},valid:result.valid,interpretation});
    if(!result.valid)for(const error of result.errors.slice(0,16)) {
     const at=pointer+decodeURIComponent(new URL(error.instanceLocation).hash.slice(1));
     add(doc,at,'example.schema.incompatible','This supplied JSON-compatible example does not satisfy the associated authored schema assertions. This is compatibility advice, not runtime conformance or an invented replacement value.','warning',
      {keyword:error.keyword,schema:{resource:schema.resource,pointer:schema.pointer},interpretation});
    }
   }catch(error){failed(doc,pointer,error);}
  }
  // OAS 3.2 discriminator metadata never changes JSON Schema validity.
  // Establish optionality using this same compiled canonical schema, rather
  // than treating the absence of a local required keyword as proof.
  const schemaEdges=new Map(graph.references.filter(edge=>edge.kind==='schema'&&edge.keyword==='$ref').map(edge=>[edge.resource+'#'+edge.pointer,edge]));
  let discriminatorWork=0;
  const requires=(scope:GraphScope,name:string,seen=new Set<string>()):boolean=>{
   const key=scope.resource+'#'+scope.pointer;
   if(seen.has(key)||seen.size>=128||++discriminatorWork>20000)return false;
   const value=docs.get(scope.resource)?.dataNode(scope.pointer)?.value;
   if(!value||typeof value!=='object')return false;
   if(Array.isArray(value.required)&&value.required.includes(name))return true;
   const nested=new Set(seen);nested.add(key);
   const ref=schemaEdges.get(key);
   if(ref?.resolution==='resolved'&&requires(graph.scope(ref.targetResource!,ref.targetPointer!),name,nested))return true;
   if(Array.isArray(value.allOf)&&value.allOf.some((_:any,i:number)=>requires(graph.scope(scope.resource,scope.pointer+'/allOf/'+i),name,nested)))return true;
   for(const keyword of ['anyOf','oneOf'])if(Array.isArray(value[keyword])&&value[keyword].length&&value[keyword].every((_:any,i:number)=>requires(graph.scope(scope.resource,scope.pointer+'/'+keyword+'/'+i),name,nested)))return true;
   return false;
  };
  const emptyObject=new SourceDocument('{}','urn:busyapi:discriminator-absence',true);
  for(const scope of all) {
   const doc=docs.get(scope.resource)!,value=doc.dataNode(scope.pointer)?.value;
   if(scope.family!=='3.2'||typeof value?.discriminator?.propertyName!=='string'||value.discriminator.defaultMapping!==undefined)continue;
   const name=value.discriminator.propertyName,pointer=scope.pointer+'/discriminator';
   if(requires(scope,name))continue;
   let optional=false;
   try {
    const ast=await getCompiled(scope);
    if(ast&&discriminatorWork<=20000) {
     const candidates=[{doc:emptyObject,pointer:''},...examples.filter(example=>example.schema.resource===scope.resource&&example.schema.pointer===scope.pointer).slice(0,32)];
     for(const candidate of candidates) {
      if(++discriminatorWork>20000)break;
      const node=candidate.doc.dataNode(candidate.pointer);
      if(node?.kind!=='object'||node.children.has(name))continue;
      const result:any=interpret(ast,exact.exactInstance(candidate.doc,candidate.pointer),BASIC);
      if(result.valid){optional=true;break;}
     }
    }
   }catch(error){observeFailure?.(error);}
   if(optional)add(doc,pointer,'discriminator.default-mapping.required','An optional discriminating property requires defaultMapping in OpenAPI 3.2');
   else {
    complete=false;
    add(doc,pointer,'discriminator.required.incomplete','The bounded schema proof could not establish whether the discriminating property is required; defaultMapping completeness is not claimed.','warning');
   }
  }
  // Authored-data policy rules do not select serialized or runtime instances.
  // Capture their completeness before those independently requested stages.
  const authoredData={complete,instances};
  const runtime=input.runtimeInstances??[];
  const runtimeOwner={snapshot:input.snapshot,graph,scopes:evaluationScopes,exact,compile:getCompiled,schemaReady:(scope:SchemaEvaluationScope)=>!states.get(scopeId(scope)),producer:schemaProducer,observeFailure};
  const serialized=await evaluateSerializedExamples(graph,values=>evaluateRuntimeInstances(values,runtimeOwner));
  complete=complete&&serialized.complete;instances+=serialized.instances;
  for(const finding of serialized.findings)add(finding.document,finding.pointer,finding.code,finding.message,finding.severity??'warning',finding.details);
  const checkedRuntime=await evaluateRuntimeInstances(runtime,runtimeOwner);
  complete=complete&&checkedRuntime.complete;instances+=checkedRuntime.instances;
  runtimeEvaluations.push(...checkedRuntime.evaluations);runtimeFindings.push(...checkedRuntime.findings);
  if(limited)add(root,'','limit.schema.findings','Schema evaluation reached its bounded work or finding limit. Shown results are not exhaustive.','warning');
  return {version:1,snapshot:input.snapshot,root:input.root,producer:schemaProducer.name,producerVersion:schemaProducer.version,configuration:schemaProducer.configuration+(input.policyAnnotations===true?':policy-annotations':''),
   complete,findings,evaluations,serializedEvaluations:serialized.evaluations,runtimeEvaluations,runtimeFindings,skipped,schemas,instances,coverage:{schemaKeywords:'dated-oas-and-draft2020-12-meta',instances:runtime.length?'selected-runtime-values-and-authored-examples':'authored-examples',authoredData,serializedMediaExamples:{complete:serialized.complete,evaluated:serialized.evaluations.length},unboundExampleSerializations:serialized.unbound,numbers:'exact-cst-decimal',dynamicScope:'validator-evaluation-stack',format:'annotation-only',runtime:runtime.length?'selected-operation-values':'not-requested'}};
 }finally {
  open=false;documents.clear();exact.dispose();
  for(const uri of ownedIds)unloadDialect(uri);
  for(const scheme of schemes)addUriSchemePlugin(scheme,{retrieve:async()=>{throw new SourceError('schema.owner','No schema evaluation owns this resource request');}});
  addMediaTypePlugin('application/vnd.busyapi.schema-snapshot+json',{fileMatcher:async()=>false,parse:async()=>{throw new SourceError('schema.owner','No schema snapshot is active');}});
  running=false;
 }
}
