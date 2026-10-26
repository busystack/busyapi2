import {SourceError} from './document';
import type {GraphReference,GraphScope,ReferenceGraph} from './reference_graph';

/** Swagger §6.4.12: an absent response schema declares no response content. */
export const swaggerResponseAllowsContent=(response:object):boolean=>Object.hasOwn(response,'schema');

const identity=(scope:{resource:string;pointer:string})=>scope.resource+'#'+scope.pointer;
const responseRoot=(graph:ReferenceGraph,scope:GraphScope)=>scope.family==='2.0'&&scope.kind==='schema'&&scope.pointer.endsWith('/schema')&&graph.scopes.get(scope.resource+'#'+scope.pointer.slice(0,-7))?.kind==='response';

/** Unversioned fragments receive the referring response position (§6.4.17).
 * A physical Schema Object inside a declared API or another schema retains its
 * own restrictions. Shared fragments cannot introduce file into body schemas. */
export function swaggerFileContexts(graph:ReferenceGraph):{contexts:ReadonlySet<string>;fileSchemas:ReadonlySet<string>;invalidReferences:readonly GraphReference[]} {
 const references=graph.references.filter(edge=>edge.kind==='schema'&&edge.keyword==='$ref');
 const edges=new Map(references.map(edge=>[identity(edge),edge]));
 const contexts=new Set<string>(),queue:GraphScope[]=[];
 for(const scope of graph.scopes.values())if(responseRoot(graph,scope)){contexts.add(identity(scope));queue.push(scope);}
 const accepts=(scope:GraphScope)=>{
  if(responseRoot(graph,scope))return true;
  if(scope.family!=='2.0'||scope.kind!=='schema'||graph.specifications.has(scope.resource))return false;
  let parent=scope.pointer;
  while(parent){parent=parent.slice(0,parent.lastIndexOf('/'));if(graph.scopes.get(scope.resource+'#'+parent)?.kind==='schema')return false;}
  return true;
 };
 for(let index=0;index<queue.length;index++){
  const edge=edges.get(identity(queue[index]));
  if(edge?.resolution!=='resolved')continue;
  const target=graph.scopes.get(edge.targetResource+'#'+edge.targetPointer);
  if(target&&accepts(target)&&!contexts.has(identity(target))){contexts.add(identity(target));queue.push(target);}
 }
 const reverse=new Map<string,string[]>(),files=new Set<string>(),pending:string[]=[];
 for(const scope of queue){
  const id=identity(scope),edge=edges.get(id);
  if(!edge&&graph.docs.get(scope.resource)?.dataNode(scope.pointer)?.value?.type==='file'){files.add(id);pending.push(id);}
  if(edge?.resolution==='resolved'){
   const target=edge.targetResource+'#'+edge.targetPointer;
   if(contexts.has(target))reverse.set(target,[...(reverse.get(target)??[]),id]);
  }
 }
 for(let index=0;index<pending.length;index++)for(const parent of reverse.get(pending[index])??[])if(!files.has(parent)){files.add(parent);pending.push(parent);}
 const invalidReferences=references.filter(edge=>edge.family==='2.0'&&!contexts.has(identity(edge))&&edge.resolution==='resolved'&&files.has(edge.targetResource+'#'+edge.targetPointer));
 return {contexts,fileSchemas:files,invalidReferences};
}

/** A file choice must keep every captured consumer in a response-root position.
 * A body reference into any link of a shared chain also excludes its target.
 * This uses the same graph ownership as file evaluation, before a type is edited. */
export function swaggerFileChoiceTargets(graph:ReferenceGraph):ReadonlySet<string> {
 const {contexts}=swaggerFileContexts(graph),blocked=new Set<string>(),pending:string[]=[];
 const edges=new Map<string,string>();
 for(const edge of graph.references){
  if(edge.kind!=='schema'||edge.keyword!=='$ref'||edge.resolution!=='resolved')continue;
  const source=identity(edge),target=edge.targetResource+'#'+edge.targetPointer;
  edges.set(source,target);
  if(contexts.has(target)&&!contexts.has(source)&&!blocked.has(target)){blocked.add(target);pending.push(target);}
 }
 for(let index=0;index<pending.length;index++){
  const target=edges.get(pending[index]);
  if(target&&contexts.has(target)&&!blocked.has(target)){blocked.add(target);pending.push(target);}
 }
 return new Set([...contexts].filter(target=>!blocked.has(target)));
}

/** Swagger §6.4.12 extends the response schema's root with file. This does
 * not introduce file as a JSON type or permit it in nested/body schemas. */
export function swaggerFileSchemas(graph:ReferenceGraph) {
 const {contexts}=swaggerFileContexts(graph);
 const edges=new Map(graph.references.filter(edge=>edge.kind==='schema'&&edge.keyword==='$ref').map(edge=>[edge.resource+'#'+edge.pointer,edge]));
 return (root:GraphScope):GraphScope|undefined=>{
  if(!contexts.has(identity(root)))return;
  let scope=root;const seen=new Set<string>();
  for(let depth=0;depth<128;depth++){
   const key=scope.resource+'#'+scope.pointer;
   if(seen.has(key))throw new SourceError('runtime.file.reference','The file schema reference chain is cyclic',[0,0],'unsupported');seen.add(key);
   const edge=edges.get(key);
   if(!edge)return graph.docs.get(scope.resource)?.dataNode(scope.pointer)?.value?.type==='file'?scope:undefined;
   if(edge.resolution!=='resolved')throw new SourceError('runtime.file.reference','The file schema reference is unresolved',[0,0],'unsupported');
   const next=graph.scopes.get(edge.targetResource+'#'+edge.targetPointer);
   if(!next||next.kind!=='schema'||next.family!=='2.0')throw new SourceError('runtime.file.reference','The file schema reference has no captured Swagger target',[0,0],'unsupported');
   if(!contexts.has(identity(next)))return;
   scope=next;
  }
  throw new SourceError('limit.runtime.file.reference','The file schema chain exceeds 128 references',[0,0],'unsupported');
 };
}
