import {createHash} from 'node:crypto';
import {createGraph,propose,Resource} from './engine';
import {fieldsForScope} from './authoring';
import {escape,segments,SourceError} from './document';
import {referenceValue} from './reference_choices';
import {resolveUri} from './reference_graph';

const same=(a:any,b:any)=>a?.resource===b?.resource&&a?.pointer===b?.pointer;
const resolvedTo=(ref:any,target:any)=>ref?.resolution==='resolved'&&ref.targetResource===target.resource&&ref.targetPointer===target.pointer;

/** Reopening starts with the entry, not the last process's dependency cache.
 * This proof acquires nothing: it reuses canonical resolution over subsets of
 * the already approved immutable resources, admitted by retrieval URI or an
 * explicit supplied mapping, never by guessing a declared embedded identity. */
export function coldGraph(root:string,resources:Resource[]) {
 const retrievals=new Map<string,Set<string>>();
 for(const resource of resources)for(const name of [resource.id,...resource.aliases??[]]) {
  const uri=resolveUri(name,resource.id).href,values=retrievals.get(uri)??new Set<string>();
  values.add(resource.id);retrievals.set(uri,values);
 }
 const ids=new Set([root]);
 for(let pass=0;pass<=128;pass++) {
  const result=createGraph({root,resources:resources.filter(resource=>ids.has(resource.id))});
  let added=false;
  for(const ref of result.graph.references)if(ref.resolution==='unavailable') {
   const matches=retrievals.get(ref.targetUri!);
   if(matches?.size===1)for(const id of matches)if(!ids.has(id)){ids.add(id);added=true;}
  }
  if(!added)return result.graph;
 }
 throw new SourceError('limit.reference.closure','Cold reference closure exceeds the bounded graph limit');
}

/** An intentional, reviewed change of one reference occurrence. It is not
 * definition editing, inlining or a semantics-preserving rename. All roots
 * see the same physical change; newly reachable dependencies can only come
 * from the immutable resources already approved by the native owner. */
export function planReference(input:any) {
 const resources=input.resources as Resource[],target=input.target,choice=input.choice,keyword=input.keyword;
 if(!Array.isArray(resources)||!Array.isArray(input.contexts)||!input.contexts.length||input.contexts.length>128||!['$ref','$dynamicRef','operationRef'].includes(keyword))
  throw new SourceError('reference.choice.context','Choose a source occurrence and a typed target');
 const source=resources.find(r=>r.id===target?.resource),destination=resources.find(r=>r.id===choice?.resource);
 if(!source||!destination||source.generation!==target.generation||destination.generation!==choice.generation)
  throw new SourceError('edit.stale','A captured reference occurrence or definition changed');
 const graphs=input.contexts.map((context:any)=>{
  if(!Array.isArray(context.resources)||!context.resources.includes(context.root)||context.resources.some((id:string)=>!resources.some(r=>r.id===id)))
   throw new SourceError('refactor.context','A root context contains an unavailable resource');
  return {context,...createGraph({root:context.root,resources:resources.filter(r=>context.resources.includes(r.id))})};
 });
 const selected=graphs.find(g=>g.context.root===target.root),scope=selected?.graph.scopes.get(source.id+'#'+target.pointer),to=selected?.graph.scopes.get(destination.id+'#'+choice.pointer);
 const doc=selected?.docs.get(source.id),node=doc?.nodes.get(target.pointer),toDoc=selected?.docs.get(destination.id),toNode=toDoc?.nodes.get(choice.pointer);
 if(!scope||!to||!node||!toNode||node.kind!=='object'||node.shared||same(scope,to)&&scope.kind!=='schema'||
  to.kind!==(keyword==='operationRef'?'operation':scope.kind)||!doc!.syntaxSafe(target.pointer)||!toDoc!.syntaxSafe(choice.pointer)||
  !fieldsForScope(selected.graph,scope,node.value).some(f=>f.name===keyword&&!f.prohibited&&!f.blockedBy?.length))
  throw new SourceError('reference.choice.context','The selected source and target do not have compatible, unambiguous ownership');
 for(const [captured,actual,resource]of [[target,node,source],[choice,toNode,destination]] as const)
  if(JSON.stringify(captured.range)!==JSON.stringify(actual.range)||captured.expected!==resource.text.slice(...actual.range))
   throw new SourceError('edit.stale','The captured source or target occurrence changed');
 if(keyword==='$ref'&&scope.kind!=='schema'&&scope.kind!=='path-item'&&!Object.hasOwn(node.value,'$ref')&&Object.keys(node.value).some(k=>!['summary','description'].includes(k)))
  throw new SourceError('reference.choice.inline','Extract or explicitly remove the inline object before replacing it with a Reference Object');
 if(scope.kind==='path-item') {
  const overlap=Object.keys(node.value).filter(k=>k!=='$ref'&&Object.hasOwn(toNode.value??{},k));
  if(overlap.length)throw new SourceError('reference.choice.pathItem','The selected Path Item has fields also defined at this occurrence; their combined behavior is undefined');
 }
 const old=selected.graph.references.find(r=>same(r,scope)&&r.keyword===keyword),noop=resolvedTo(old,to);
 const value=noop?old!.value:referenceValue(selected.graph,scope,to,keyword);
 if(value===undefined)throw new SourceError('reference.choice.address','No unambiguous approved reference address can represent this target');
 const result=noop?{edits:[]}:propose({...input,target:{...target,pointer:target.pointer},actions:[{kind:'set',pointer:target.pointer+'/'+escape(keyword),value}]});
 let text=source.text;
 for(const edit of [...result.edits].reverse())text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
 const usages:any[]=[],issueKey=(v:any)=>JSON.stringify([v.resource,v.pointer,v.code]);
 const known=new Map<string,Set<string>>();
 for(const g of graphs)for(const [identity,targets]of g.graph.identities)for(const item of targets){const ids=known.get(identity)??new Set<string>();ids.add(item.resource);known.set(identity,ids);}
 for(const {context,graph}of graphs) {
  const occurrence=graph.scopes.get(source.id+'#'+target.pointer);
  if(!occurrence)continue;
  if(occurrence.kind!==scope.kind)throw new SourceError('refactor.context.ambiguous','One physical occurrence has different object kinds in configured roots');
  const ids=new Set<string>(context.resources);ids.add(destination.id);
  let after:ReturnType<typeof createGraph>|undefined;
  for(let pass=0;pass<=128;pass++) {
   after=createGraph({root:context.root,resources:resources.filter(r=>ids.has(r.id)).map(r=>r.id===source.id?{...r,text}:r)});
   const missing=after.graph.references.filter(r=>r.resolution==='unavailable'&&(!graph.references.some(old=>same(old,r)&&old.keyword===r.keyword&&old.value===r.value)));
   let added=false;
   for(const ref of missing) {
    const matches=known.get(ref.targetUri!);
    if(matches?.size===1)for(const id of matches)if(!ids.has(id)){ids.add(id);added=true;}
   }
   if(!added)break;
   if(pass===128)throw new SourceError('limit.reference.closure','The selected reference exceeds the bounded graph closure');
  }
  const next=after!.graph.references.find(r=>same(r,scope)&&r.keyword===keyword);
  if(!resolvedTo(next,to)||after!.graph.scopes.get(to.resource+'#'+to.pointer)?.kind!==to.kind)
   throw new SourceError('refactor.context.ambiguous','The selected reference does not resolve to the same typed definition in every owning root');
  if(result.edits.length) {
   const admitted=resources.filter(r=>ids.has(r.id)),beforeCold=coldGraph(context.root,admitted);
   const afterCold=coldGraph(context.root,admitted.map(r=>r.id===source.id?{...r,text}:r));
   if(!resolvedTo(afterCold.references.find(r=>same(r,scope)&&r.keyword===keyword),to))
    throw new SourceError('reference.choice.retrieval','This target needs an explicit approved URI mapping or a retained file reference before it can be resolved after reopening');
   const knownColdIssues=new Set(beforeCold.issues.map(issueKey));
   if(afterCold.issues.some(issue=>!knownColdIssues.has(issueKey(issue))))
    throw new SourceError('reference.choice.retrieval','This choice would lose a required retrieval path after reopening; approve the resource mapping before applying');
  }
  const oldIssues=new Set(graph.issues.map(issueKey));
  if(after!.graph.issues.some(issue=>!oldIssues.has(issueKey(issue))))
   throw new SourceError('reference.choice.graph','The selected reference introduces an unavailable, invalid or ambiguous semantic connection');
  for(const ref of graph.references) {
   const affected=same(ref,scope)&&ref.keyword===keyword||ref.targetResource===source.id&&(ref.targetPointer===scope.pointer||ref.targetPointer?.startsWith(scope.pointer+'/'));
   const changed=after!.graph.references.find(r=>same(r,ref)&&r.keyword===ref.keyword);
   if(!affected&&ref.resolution==='resolved'&&(!changed||changed.resolution!=='resolved'||changed.targetResource!==ref.targetResource||changed.targetPointer!==ref.targetPointer))
    throw new SourceError('reference.choice.graph','An unrelated established connection would become ambiguous or change target');
   if(affected)usages.push({root:context.root,roots:[context.root],resource:ref.resource,pointer:ref.pointer+'/'+escape(ref.keyword),connection:ref.connection??ref.keyword,
    target:{resource:ref.targetResource??source.id,pointer:ref.targetPointer??scope.pointer},effect:same(ref,scope)?'reference-target-changes':'definition-content-changes'});
  }
 }
 const changes=result.edits.length?[{resource:source.id,before:source.text,after:text}]:[];
 return {version:1,kind:'reference-selection',snapshot:input.snapshot,identity:createHash('sha256').update(JSON.stringify({snapshot:input.snapshot,target,choice,keyword,edits:result.edits})).digest('hex'),
  edits:result.edits,changes,usages,transitions:[],from:target,to:choice,keyword,value,dynamic:keyword==='$dynamicRef',checkedRoots:input.contexts.map((c:any)=>c.root)};
}
