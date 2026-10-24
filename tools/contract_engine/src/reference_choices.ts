import {posix} from 'node:path';
import {createGraph,Resource} from './engine';
import {fieldsFor} from './authoring';
import {segments,SourceError} from './document';
import {GraphScope,ReferenceGraph,resolveUri,supportedSchemaDialect} from './reference_graph';

const fragment=(pointer:string)=>'#'+encodeURI(pointer).replaceAll('#','%23').replaceAll('?','%3F');
const bounded=(value:string)=>Array.from(value).slice(0,240).join('');
const same=(a:{resource:string;pointer:string},b:{resource:string;pointer:string})=>a.resource===b.resource&&a.pointer===b.pointer;

/** Address construction is not resolution. Every proposed spelling must be
 * proved by the canonical graph, including embedded ids and retrieval aliases.
 * Completion and native choices use this same operation. */
export function referenceValue(graph:ReferenceGraph,from:GraphScope,to:GraphScope,keyword='$ref'):string|undefined {
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
    attempts.push(path+target.search+end);
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
   const result=graph.resolveReference(value,from,keyword);
   if(result.resolution==='resolved'&&to.resource===result.targetResource&&to.pointer===result.targetPointer)return value;
  }
 }catch { /* No guessed address when a pointer/identity cannot be represented. */ }
}

/** Current-root, approved-snapshot choices; never a filesystem/network scan or
 * a name-matching schema picker. Inline, reusable and identified definitions
 * remain visibly distinct physical occurrences. */
export function referenceChoices(input:any) {
 if(typeof input.query!=='string'||input.query.length>4096)throw new SourceError('limit.reference.query','Choose a bounded reference query');
 const {docs,graph}=createGraph(input),doc=docs.get(input.resource),scope=graph.scopes.get(input.resource+'#'+input.pointer);
 const keyword=input.keyword??'$ref';
 if(!doc||!scope||doc.node(input.pointer).kind!=='object'||!['$ref','$dynamicRef','operationRef'].includes(keyword)||
   !fieldsFor(scope.kind,scope.family,doc.node(input.pointer).value,segments(input.pointer).at(-1)).some(field=>field.name===keyword&&!field.prohibited&&!field.blockedBy?.length))
  throw new SourceError('reference.choice.context','This field is not a reference selector in the selected object context');
 const expectedKind=keyword==='operationRef'?'operation':scope.kind;
 const current=graph.references.find(ref=>ref.resource===doc.id&&ref.pointer===input.pointer&&ref.keyword===keyword);
 const query=input.query.toLocaleLowerCase('en-US'),all:any[]=[],resources=new Map((input.resources as Resource[]).map(resource=>[resource.id,resource]));
 for(const target of graph.scopes.values()) {
  if(target.kind!==expectedKind||same(target,scope)&&target.kind!=='schema')continue;
  const targetDoc=docs.get(target.resource)!,node=targetDoc.nodes.get(target.pointer);
  if(!node||!targetDoc.syntaxSafe(target.pointer))continue;
  const label=segments(target.pointer).at(-1)??target.base;
  if(![label,target.pointer,target.resource,target.base].some(value=>value.toLocaleLowerCase('en-US').includes(query)))continue;
  const value=referenceValue(graph,scope,target,keyword);
  if(value===undefined)continue;
  if(all.length>=20000)throw new SourceError('limit.reference.choices','Refine the reference query');
  const resource=resources.get(target.resource)!;
  const role=/^(?:\/components\/[^/]+|\/(?:definitions|parameters|responses|securityDefinitions))\/[^/]+$/.test(target.pointer)?'component':target.kind==='schema'&&target.resourcePointer===target.pointer?'schema-resource':'inline';
  all.push({semanticId:JSON.stringify([input.root,target.resource,target.pointer,target.kind]),label:bounded(label),value,kind:target.kind,role,
   reference:typeof node.value?.$ref==='string'||target.kind==='schema'&&typeof node.value?.$dynamicRef==='string',
   sharedSource:node.shared,
   selected:current?.resolution==='resolved'&&target.resource===current.targetResource&&target.pointer===current.targetPointer,
   target:{root:input.root,resource:target.resource,pointer:target.pointer,generation:resource.generation,range:node.range},
   ...(target.kind==='schema'?{dialect:target.dialect}:{}),...(keyword==='$dynamicRef'?{dynamic:true}:{}),
  });
 }
 all.sort((a,b)=>a.semanticId<b.semanticId?-1:a.semanticId>b.semanticId?1:0);
 const offset=Math.min(Math.max(0,Number.isInteger(input.offset)?input.offset:0),Math.max(0,(Math.ceil(all.length/50)-1)*50));
 const resource=resources.get(doc.id)!;
 return {version:1,snapshot:input.snapshot,root:input.root,resource:doc.id,pointer:input.pointer,generation:resource.generation,keyword,kind:scope.kind,
  range:doc.node(input.pointer).range,complete:!graph.issues.length&&[...docs.values()].every(doc=>!doc.issues.length),count:all.length,offset,entries:all.slice(offset,offset+50),
  current:current?{value:current.value,resolution:current.resolution,targetResource:current.targetResource,targetPointer:current.targetPointer,dynamic:current.dynamic}:null};
}
