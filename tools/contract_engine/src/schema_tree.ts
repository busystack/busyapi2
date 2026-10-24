import {createGraph} from './engine';
import {children} from './contexts';
import {escape,segments,SourceError} from './document';

const kinds=new Set(['schema','schema-map','schema-array']);
const bounded=(value:string)=>Array.from(value).slice(0,240).join('');

/** One lazy, authored tree level. References are navigation, never expanded
 * values. Only canonical graph positions may become schema rows: examples,
 * annotations and custom keywords are not traversed by resemblance. */
export function schemaTree(input:any) {
 const {docs,graph}=createGraph(input),doc=docs.get(input.resource);
 const scope=graph.scopes.get(input.resource+'#'+input.pointer);
 if(!doc||!scope||!kinds.has(scope.kind))throw new SourceError('schema.tree.context','This occurrence is not an authored schema tree position');
 const resource=input.resources.find((r:any)=>r.id===input.resource);
 const immediate=(pointer:string,kind:string)=>{
  const node=doc.node(pointer),typed=new Set(children(node.value,kind,graph.scope(doc.id,pointer).family).map(([name])=>name));
  return [...node.children.keys()].filter(name=>typed.has(name)&&kinds.has(graph.scopes.get(doc.id+'#'+pointer+'/'+escape(name))?.kind??''));
 };
 const row=(pointer:string,name:string)=>{
  const node=doc.node(pointer),context=graph.scopes.get(doc.id+'#'+pointer);
  if(!context||!kinds.has(context.kind))throw new SourceError('schema.tree.context','A child has no established schema context');
  const list=immediate(pointer,context.kind);
  const refs=graph.references.filter(ref=>ref.resource===doc.id&&ref.pointer===pointer&&!ref.connection).map(ref=>({
   keyword:ref.keyword,value:bounded(ref.value),resolution:ref.resolution,
   ...(ref.resolution==='resolved'?{target:{root:input.root,resource:ref.targetResource,pointer:ref.targetPointer}}:{}),
   ...(ref.dynamic?{dynamic:true}:{}),
  }));
  const tokens=segments(pointer),parent=pointer.slice(0,pointer.lastIndexOf('/'));
  const owner=parent.endsWith('/properties')?doc.nodes.get(parent.slice(0,-'/properties'.length)):undefined;
  return {root:input.root,resource:doc.id,generation:resource.generation,pointer,kind:context.kind,name:bounded(name),range:node.range,
   syntaxSafe:doc.syntaxSafe(pointer),shared:node.shared,nodeKind:context.kind==='schema'&&typeof node.value==='boolean'?'boolean':node.kind,childCount:list.length,
   ...(typeof node.value==='boolean'?{boolean:node.value}:{}),
   ...(node.value&&typeof node.value==='object'?(typeof node.value.type==='string'?{types:[bounded(node.value.type)]}:Array.isArray(node.value.type)?{types:node.value.type.filter((t:any)=>typeof t==='string').slice(0,16).map(bounded)}:{}):{}),
   ...(owner?{required:Array.isArray(owner.value?.required)&&owner.value.required.includes(tokens.at(-1))}:{}),references:refs};
 };
 const all=immediate(input.pointer,scope.kind);
 const offset=Math.min(Math.max(0,Number.isInteger(input.offset)?input.offset:0),Math.max(0,(Math.ceil(all.length/50)-1)*50));
 const reveal=typeof input.reveal==='string'&&input.reveal.startsWith(input.pointer+'/')?input.reveal.slice(input.pointer.length+1).split('/')[0]:undefined;
 const revealIndex=reveal===undefined?-1:all.findIndex(name=>escape(name)===reveal);
 return {version:1,snapshot:input.snapshot,node:row(input.pointer,segments(input.pointer).at(-1)??''),count:all.length,offset,
  ...(revealIndex>=0?{revealOffset:Math.floor(revealIndex/50)*50}:{}),
  entries:all.slice(offset,offset+50).map(name=>row(input.pointer+'/'+escape(name),name))};
}
