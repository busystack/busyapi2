import {discriminatorLocation,discriminatorParents} from './discriminator_semantics';
import {escape} from './document';
import {GraphTarget,ReferenceGraph} from './reference_graph';

export type AuthoringIssue=GraphTarget&{code:string;message:string;incomplete?:boolean;severity?:string};

/** OAS 3.1/3.2 discriminator composition is a relationship constraint, never
 * an instance assertion. A parent may qualify through a child's allOf even
 * when the parent has no adjacent composition keyword. */
export function discriminatorRelationships(graph:ReferenceGraph):AuthoringIssue[] {
 const candidates=graph.scopesFor('schema').filter(scope=>scope.kind==='schema'&&scope.family!=='2.0'&&graph.docs.get(scope.resource)?.dataNode(scope.pointer)?.value?.discriminator);
 if(!candidates.length)return [];
 const parents=discriminatorParents(graph);
 const issues:AuthoringIssue[]=[];
 for(const scope of candidates) {
  const doc=graph.docs.get(scope.resource)!,value=doc.dataNode(scope.pointer)?.value;
  if(!value?.discriminator||!doc.dataSyntaxSafe(scope.pointer))continue;
  if(['oneOf','anyOf','allOf'].some(name=>Array.isArray(value[name])&&value[name].length>0)||parents.established.has(discriminatorLocation(scope)))continue;
  const incomplete=parents.incomplete||parents.possible.has(discriminatorLocation(scope));
  issues.push({...scope,pointer:scope.pointer+'/discriminator',code:incomplete?'discriminator.composition.incomplete':'discriminator.composition',message:incomplete?'The captured references cannot establish whether this schema has an allOf child; no complete discriminator composition result is claimed':'A discriminator requires adjacent composition or a parent schema referenced by a child through allOf',...(incomplete?{incomplete:true,severity:'warning'}:{})});
 }
 return issues;
}

/** Relationships which informational object schemas cannot express. Every
 * location is already a typed canonical-graph occurrence; example/extension
 * payload keys never enter this traversal. No effective defaults are authored. */
export function authoringRelationships(graph:ReferenceGraph):AuthoringIssue[] {
 const issues=new Map<string,AuthoringIssue>();
 const key=(at:GraphTarget)=>JSON.stringify([at.resource,at.pointer]);
 const namespace=new Map<string,GraphTarget[]>(),parents=new Map<string,{at:GraphTarget;name:string}>();
 // OAS 3.2 4.1.2.3 recommends the entry-description namespace for Tag names,
 // just as the graph uses it for implicit component names. URI bases do not
 // change. Index possible targets once; duplicate names never select a first.
 const tags=graph.docs.get(graph.root)?.dataNode('/tags');
 if(tags?.kind==='array')for(const [i,tag]of tags.children)if(typeof tag.value?.name==='string') {
  const values=namespace.get(tag.value.name)??[];
  values.push({resource:graph.root,pointer:'/tags/'+escape(i),kind:'tag'});namespace.set(tag.value.name,values);
 }
 const add=(at:GraphTarget,pointer:string,code:string,message:string,incomplete=false)=>{
  const value={...at,pointer,code,message,...(incomplete?{incomplete:true,severity:'warning'}:{})};
  issues.set(JSON.stringify([at.resource,pointer,code]),value);
 };
 for(const at of graph.scopes.values()) {
  const doc=graph.docs.get(at.resource)!,node=doc.dataNode(at.pointer);
  const family=at.family;
  if(!node||!doc.dataSyntaxSafe(at.pointer))continue;
  if(at.kind==='example'&&typeof node.value?.$ref!=='string') {
   const pairs=[['value','externalValue'],...(family==='3.2'?[['value','dataValue'],['value','serializedValue'],['serializedValue','externalValue']]:[])];
   for(const pair of pairs)if(pair.every(name=>node.children.has(name)))
    for(const name of pair)add(at,at.pointer+'/'+name,'example.representations.exclusive','These Example Object representations are mutually exclusive');
  }
  if(at.kind!=='tag-array'||node.kind!=='array')continue;
  const names=new Map<string,string[]>();
  for(const [i,tag]of node.children)if(typeof tag.value?.name==='string') {
   const pointer=at.pointer+'/'+escape(i),name=tag.value.name,existing=names.get(name)??[];
   existing.push(pointer);names.set(name,existing);
   if(family==='3.2'&&typeof tag.value.parent==='string') {
    const source={resource:at.resource,pointer,kind:'tag'};
    parents.set(key(source),{at:source,name:tag.value.parent});
   }
  }
  for(const pointers of names.values())if(pointers.length>1)for(const pointer of pointers)
   add(at,pointer+'/name','tag.name.duplicate','Tag names in one declaration list must be unique');
 }
 const edges=new Map<string,string>();
 for(const [source,{at,name}]of parents) {
  const targets=namespace.get(name)??[];
  if(targets.length===1)edges.set(source,key(targets[0]));
  else add(at,at.pointer+'/parent',targets.length?'tag.parent.ambiguous':'tag.parent.missing',targets.length?'The parent tag name has multiple entry declarations':'A parent tag must name an entry-description tag declaration',targets.length>1);
 }
 const finished=new Set<string>();
 for(const start of edges.keys()) {
   if(finished.has(start))continue;
   const route:string[]=[],positions=new Map<string,number>();let pointer:string|undefined=start;
   while(pointer!==undefined&&!finished.has(pointer)&&!positions.has(pointer)) {
    positions.set(pointer,route.length);route.push(pointer);pointer=edges.get(pointer);
   }
   if(pointer!==undefined&&positions.has(pointer))for(const member of route.slice(positions.get(pointer)!)) {
    const {at}=parents.get(member)!;
    add(at,at.pointer+'/parent','tag.parent.cycle','Tag parent relationships must not form a cycle');
   }
   for(const member of route)finished.add(member);
 }
 return [...issues.values(),...discriminatorRelationships(graph)];
}
