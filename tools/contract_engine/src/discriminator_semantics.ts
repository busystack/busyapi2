import {type GraphTarget,type ReferenceGraph} from './reference_graph';
import {projectSchemaReference,type SchemaReferenceProjection} from './schema_reference_projection';

export const discriminatorContextRevision='1';
export const discriminatorLocation=(target:Pick<GraphTarget,'resource'|'pointer'>):string=>JSON.stringify([target.resource,target.pointer]);

/** Composition needs a guaranteed captured allOf connection. A dynamic choice
 * may establish a parent, but cannot disprove one. Keep those candidates and
 * unresolved chains incomplete rather than issuing a specification error. */
export function discriminatorParents(graph:ReferenceGraph):{established:ReadonlySet<string>;possible:ReadonlySet<string>;incomplete:boolean} {
 const edges=new Map<string,SchemaReferenceProjection[]>();
 for(const reference of graph.references){
  if(reference.kind!=='schema'||reference.connection)continue;
  const key=discriminatorLocation(reference),items=edges.get(key)??[];
  items.push(projectSchemaReference(reference));edges.set(key,items);
 }
 const established=new Set<string>(),possible=new Set<string>();
 const queue:{target:GraphTarget;possible:boolean}[]=[];
 let incomplete=false,work=0;
 const spend=()=>{if(++work<=1000000)return true;incomplete=true;return false;};
 const enqueue=(target:GraphTarget,uncertain:boolean)=>{
  const key=discriminatorLocation(target),seen=uncertain?possible:established;
  if(!seen.has(key)){seen.add(key);queue.push({target,possible:uncertain});}
 };
 const follow=(reference:SchemaReferenceProjection,uncertain:boolean)=>{
  if(!spend())return;
  if(reference.state==='fixed')enqueue(reference.target,uncertain);
  else if(reference.state==='dynamic')for(const target of reference.candidates){if(!spend())break;enqueue(target,true);}
  else incomplete=true;
 };
 for(const scope of graph.scopesFor('schema')){
  if(scope.kind!=='schema'||work>1000000)continue;
  const pointer=scope.pointer+'/allOf';
  if(graph.scopes.get(scope.resource+'#'+pointer)?.kind!=='schema-array')continue;
  const list=graph.docs.get(scope.resource)?.dataNode(pointer);if(list?.kind!=='array')continue;
  for(const index of list.children.keys())for(const reference of edges.get(discriminatorLocation({resource:scope.resource,pointer:pointer+'/'+index}))??[])follow(reference,false);
 }
 for(let index=0;index<queue.length&&work<=1000000;index++){
  const item=queue[index];for(const reference of edges.get(discriminatorLocation(item.target))??[])follow(reference,item.possible);
 }
 return {established,possible,incomplete};
}
