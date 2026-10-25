import {posix} from 'node:path';
import {createGraph,Resource} from './engine';
import {componentLocation,fieldsForScope} from './authoring';
import {escape,segments,SourceError} from './document';
import {GraphReference,GraphScope,ReferenceGraph,implicitNameReference,resolveUri,supportedSchemaDialect} from './reference_graph';
import {capabilitiesFor,isNativeFamily} from './specification';
import {securityRequirementDefinition,securityRequirementValuesAllowed} from './security_requirements';

const fragment=(pointer:string)=>'#'+encodeURI(pointer).replaceAll('#','%23').replaceAll('?','%3F');
const bounded=(value:string)=>Array.from(value).slice(0,240).join('');
const same=(a:{resource:string;pointer:string},b:{resource:string;pointer:string})=>a.resource===b.resource&&a.pointer===b.pointer;

/** Address construction is not resolution. Every proposed spelling must be
 * proved by the canonical graph, including embedded ids and retrieval aliases.
 * Completion and native choices use this same operation. */
export function referenceValue(graph:ReferenceGraph,from:GraphScope,to:GraphScope,keyword='$ref',excluded?:ReadonlySet<string>):string|undefined {
 if(to.kind==='schema'&&!supportedSchemaDialect(to))return;
 let target:URL,suffix:string;
 try {
  target=resolveUri(to.kind==='schema'?to.base:graph.scope(to.resource,'').base,to.resource);
  suffix=to.kind==='schema'?to.pointer.slice(to.resourcePointer.length):to.pointer;
  target.hash='';
  if(target.username||target.password)return;
  if(keyword==='$dynamicRef') {
   const anchor=graph.docs.get(to.resource)!.node(to.pointer).value?.$dynamicAnchor;
   if(typeof anchor!=='string')return;
   suffix=anchor;
  }
  const source=resolveUri('',from.base);source.hash='';
  const attempts:string[]=[];
  const append=(target:URL,end:string)=>{
   if(source.href===target.href)attempts.push(end);
   if(source.protocol===target.protocol&&source.host===target.host&&['file:','http:','https:'].includes(target.protocol)) {
    let path=posix.relative(posix.dirname(source.pathname),target.pathname)||posix.basename(target.pathname);
    if(target.pathname.endsWith('/'))path=(path||'.')+'/';
    if(path.split('/')[0].includes(':'))path='./'+path;
    let relative=path+target.search+end;
    // Distinct Security Requirement bindings can address the same target.
    // Keep their arrays separate when a relocation needs new member names;
    // redundant dot segments retain URI meaning (RFC 3986 §5.2.4).
    while(excluded?.has(relative)&&relative.length+2<=65536)relative='./'+relative;
    attempts.push(relative);
   }
   attempts.push(target.href+end);
  };
  const data=graph.docs.get(to.resource)!.root.value;
  // A canonical identifier is not a retrieval capability. Retain a local
  // file route when selecting an external schema would otherwise discard its
  // last discoverable dependency. Core/graph resolution still establishes the
  // original $id/base/dialect at the selected location. JSON Schema Core 9.2.1
  // permits this physical-document addressing; moving the resource requires
  // reviewed reference repairs. OAS 3.2's declared $self is never bypassed.
  if(to.kind==='schema'&&to.resource!==from.resource&&to.resource.startsWith('file:')&&
    !(String(data?.openapi).startsWith('3.2.')&&typeof data?.$self==='string')&&
    (keyword!=='$dynamicRef'||to.resourcePointer===''))
   append(resolveUri(to.resource,to.resource),keyword==='$dynamicRef'?'#'+encodeURIComponent(suffix):fragment(to.pointer));
  append(target,keyword==='$dynamicRef'?'#'+encodeURIComponent(suffix):fragment(suffix));
  for(const value of attempts) {
   if(excluded?.has(value))continue;
   const result=graph.resolveReference(value,from,keyword);
   if(result.resolution==='resolved'&&to.resource===result.targetResource&&to.pointer===result.targetPointer)return value;
  }
 }catch { /* No guessed address when a pointer/identity cannot be represented. */ }
}

export type SecurityBindingForm='name'|'uri';
export type SecuritySelectionScope={source:GraphScope;mode:'alternative'|'combined'|'replacement';requirementPointer:string;current?:GraphReference};
export type SecurityBindingCandidate={target:GraphScope;value:string;bindingForm:SecurityBindingForm};

/** Security Requirement members are connections, not Reference Objects. The
 * typed parent distinguishes a role/scope array from arbitrary array data. */
export function securitySelectionScope(graph:ReferenceGraph,source:GraphScope):SecuritySelectionScope|undefined {
 if(!isNativeFamily(source.family))return;
 const doc=graph.docs.get(source.resource)!,node=doc.dataNode(source.pointer);
 if(source.kind==='security-array'&&node?.kind==='array')return {source,mode:'alternative',requirementPointer:source.pointer+'/'+node.children.size};
 if(source.kind==='security-requirement'&&node?.kind==='object')return {source,mode:'combined',requirementPointer:source.pointer};
 if(source.kind!=='string-array'||node?.kind!=='array')return;
 const parts=segments(source.pointer),name=parts.pop()!,parent='/'+parts.map(escape).join('/');
 const owner=graph.scopes.get(source.resource+'#'+parent);
 if(owner?.kind!=='security-requirement')return;
 const current=graph.references.find(ref=>ref.resource===source.resource&&ref.pointer===parent&&ref.keyword===name&&ref.connection==='security');
 return current?{source,mode:'replacement',requirementPointer:parent,current}:undefined;
}

/** All binding spellings are proved in their actual name/URI namespace.
 * OAS 3.2 §4.30 name precedence also applies to URI-looking member names. */
export function securityBindings(graph:ReferenceGraph,selection:SecuritySelectionScope,options:{bindingForm?:SecurityBindingForm;query?:string;prefix?:string}={}):SecurityBindingCandidate[] {
 const {source,current}=selection,doc=graph.docs.get(source.resource)!;
 const uriSupported=isNativeFamily(source.family)&&capabilitiesFor(source.family).securityRequirementUris;
 if(options.bindingForm==='uri'&&!uriSupported){
  const range=doc.node(source.pointer).range;
  throw new SourceError('reference.choice.security-uri','URI Security Requirement bindings require OpenAPI 3.2',range,'unsupported',{resource:source.resource,pointer:source.pointer,range});
 }
 const group=componentLocation('securitySchemes',graph.family),names=group?graph.docs.get(graph.root)!.dataNode(group)?.children:new Map();
 const occupied=selection.mode==='alternative'?new Set<string>():new Set(doc.node(selection.requirementPointer).children.keys());
 if(current)occupied.delete(current.value);
 const excluded=new Set<string>([...names?.keys()??[],...occupied]),query=(options.query??'').toLocaleLowerCase('en-US');
 const result:SecurityBindingCandidate[]=[];
 const count=current?doc.node(source.pointer).children.size:0;
 const append=(target:GraphScope,value:string,bindingForm:SecurityBindingForm)=>{
  if(options.prefix!==undefined&&!value.startsWith(options.prefix)||occupied.has(value))return;
  if(count>0){
   const definition=securityRequirementDefinition(graph,target);
   if(!definition||!securityRequirementValuesAllowed(source.family,graph.docs.get(definition.resource)!.dataNode(definition.pointer)?.value?.type,count))return;
  }
  const proof=graph.resolveConnection({...source,kind:'security',connection:'security',keyword:value,value});
  if(proof.resolution!=='resolved'||proof.targetResource!==target.resource||proof.targetPointer!==target.pointer)return;
  if(result.length>=20000)throw new SourceError('limit.reference.choices','Refine the security binding query');
  result.push({target,value,bindingForm});
 };
 for(const target of graph.scopes.values()){
  if(target.kind!=='security')continue;
  const targetDoc=graph.docs.get(target.resource)!,node=targetDoc.dataNode(target.pointer);
  if(node?.kind!=='object'||!targetDoc.syntaxSafe(target.pointer))continue;
  const label=segments(target.pointer).at(-1)??target.base;
  if(query&&![label,target.pointer,target.resource,target.base,target.resource+'#'+target.pointer].some(value=>value.toLocaleLowerCase('en-US').includes(query)))continue;
  if(options.bindingForm!=='uri'&&target.resource===graph.root&&group&&target.pointer===group+'/'+escape(label)&&names?.has(label))append(target,label,'name');
  if(options.bindingForm==='name'||!uriSupported)continue;
  const retained=current?.resolution==='resolved'&&!implicitNameReference(current)&&current.targetResource===target.resource&&current.targetPointer===target.pointer;
  const value=retained?current.value:referenceValue(graph,{...source,kind:'security'},target,'security',excluded);
  if(value!==undefined)append(target,value,'uri');
 }
 return result;
}

/** Current-root, approved-snapshot choices; never a filesystem/network scan or
 * a name-matching schema picker. Inline, reusable and identified definitions
 * remain visibly distinct physical occurrences. */
export function referenceChoices(input:any) {
 if(typeof input.query!=='string'||input.query.length>4096)throw new SourceError('limit.reference.query','Choose a bounded reference query');
 const {docs,graph}=createGraph(input),doc=docs.get(input.resource),scope=graph.scopes.get(input.resource+'#'+input.pointer);
 const keyword=input.keyword??'$ref';
 const security=keyword==='security'&&scope?securitySelectionScope(graph,scope):undefined;
 if(!doc||!scope||!['$ref','$dynamicRef','operationRef','security'].includes(keyword)||
   (keyword==='security'?!security:doc.node(input.pointer).kind!=='object'||!fieldsForScope(graph,scope,doc.node(input.pointer).value).some(field=>field.name===keyword&&!field.prohibited&&!field.blockedBy?.length))||
   input.bindingForm!==undefined&&(!security||!['name','uri'].includes(input.bindingForm)))
  throw new SourceError('reference.choice.context','This field is not a reference selector in the selected object context');
 const expectedKind=security?'security':keyword==='operationRef'?'operation':scope.kind;
 const current=security?security.current:graph.references.find(ref=>ref.resource===doc.id&&ref.pointer===input.pointer&&ref.keyword===keyword);
 const query=input.query.toLocaleLowerCase('en-US'),all:any[]=[],resources=new Map((input.resources as Resource[]).map(resource=>[resource.id,resource]));
 function* candidates():Generator<{target:GraphScope;value?:string;bindingForm?:SecurityBindingForm}>{
  if(security)yield*securityBindings(graph,security,{bindingForm:input.bindingForm,query:input.query});
  else for(const target of graph.scopes.values())yield {target};
 }
 for(const candidate of candidates()) {
  const target=candidate.target;
  if(target.kind!==expectedKind||same(target,scope)&&target.kind!=='schema')continue;
  const targetDoc=docs.get(target.resource)!,node=targetDoc.nodes.get(target.pointer);
  if(!node||!targetDoc.syntaxSafe(target.pointer))continue;
  const label=segments(target.pointer).at(-1)??target.base;
  if(![label,target.pointer,target.resource,target.base].some(value=>value.toLocaleLowerCase('en-US').includes(query)))continue;
  const value=candidate.value??referenceValue(graph,scope,target,keyword);
  if(value===undefined)continue;
  if(all.length>=20000)throw new SourceError('limit.reference.choices','Refine the reference query');
  const resource=resources.get(target.resource)!;
  const role=/^(?:\/components\/[^/]+|\/(?:definitions|parameters|responses|securityDefinitions))\/[^/]+$/.test(target.pointer)?'component':target.kind==='schema'&&target.resourcePointer===target.pointer?'schema-resource':'inline';
  all.push({semanticId:JSON.stringify([input.root,target.resource,target.pointer,target.kind,...(candidate.bindingForm?[candidate.bindingForm]:[])]),label:bounded(label),value,kind:target.kind,role,
   ...(candidate.bindingForm?{bindingForm:candidate.bindingForm}:{}),
   reference:graph.allowsReference(target)&&typeof node.value?.$ref==='string'||target.kind==='schema'&&typeof node.value?.$dynamicRef==='string',
   sharedSource:node.shared,
   selected:current?.resolution==='resolved'&&target.resource===current.targetResource&&target.pointer===current.targetPointer&&(!security||value===current.value),
   target:{root:input.root,resource:target.resource,pointer:target.pointer,generation:resource.generation,range:node.range},
   ...(target.kind==='schema'?{dialect:target.dialect}:{}),...(keyword==='$dynamicRef'?{dynamic:true}:{}),
  });
 }
 all.sort((a,b)=>a.semanticId<b.semanticId?-1:a.semanticId>b.semanticId?1:0);
 const offset=Math.min(Math.max(0,Number.isInteger(input.offset)?input.offset:0),Math.max(0,(Math.ceil(all.length/50)-1)*50));
 const resource=resources.get(doc.id)!;
 return {version:1,snapshot:input.snapshot,root:input.root,resource:doc.id,pointer:input.pointer,generation:resource.generation,keyword,kind:scope.kind,targetKind:expectedKind,...(input.bindingForm?{bindingForm:input.bindingForm}:{}),
  range:doc.node(input.pointer).range,complete:!graph.issues.length&&[...docs.values()].every(doc=>!doc.issues.length),count:all.length,offset,entries:all.slice(offset,offset+50),
  current:current?{value:current.value,resolution:current.resolution,targetResource:current.targetResource,targetPointer:current.targetPointer,dynamic:current.dynamic}:null};
}
