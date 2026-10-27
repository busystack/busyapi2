import {posix} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {createGraph,propose,Resource} from './engine';
import {SourceDocument,SourceError,escape,segments} from './document';
import {documentUriFields,documentUriOccurrences} from './document_uris';
import {documentUriBase,GraphScope,implicitNameReference,resolveUri,type GraphReference} from './reference_graph';
import {referenceValue} from './reference_choices';
import {coldGraph} from './reference_selection';
import {editsFor} from './refactoring_copy';
import {serverTemplate} from './derived_bundle';
import {resolveServerUrl} from './server_semantics';
import {securityConfigurationCopies,type SecurityBindingChange} from './security_configuration';
import {caseFileLocators,movedCaseFileSource} from './case_file_configuration';

const same=(a:any,b:any)=>a?.resource===b?.resource&&a?.pointer===b?.pointer;

/** Remove a declaration, not its files. Configuration can also be explicitly
 * consumed as schema/example data: review that dual ownership in the canonical
 * graphs, without seeding configuration or payload keys as API objects. */
export function planRootRemoval(input:any) {
 const manifest=input.manifest as Resource,target=input.target;
 if(typeof input.snapshot!=='string'||!manifest||typeof manifest.id!=='string'||typeof manifest.text!=='string'||manifest.text.length>65536||
    !Number.isInteger(manifest.generation)||manifest.generation<0||!Number.isInteger(target?.index)||typeof target.name!=='string'||typeof target.resource!=='string'||
    !Array.isArray(input.configuredRoots)||input.configuredRoots.length>128||input.configuredRoots.some(value=>typeof value!=='string'))
  throw new SourceError('root.snapshot','Choose one captured named root declaration');
 const doc=new SourceDocument(manifest.text,manifest.id,true),entries=doc.root.value?.roots;
 if(doc.issues.length||doc.root.value?.version!==1||!Array.isArray(entries)||entries.length>128||
    entries.some(entry=>!entry||typeof entry.name!=='string'||typeof entry.path!=='string')||new Set(entries.map(entry=>entry.name)).size!==entries.length||
    target.index<0||target.index>=entries.length||entries[target.index]?.name!==target.name||typeof entries[target.index]?.path!=='string')
  throw new SourceError('root.stale','The named root declaration changed before review');
 let resource:string;
 try{resource=pathToFileURL(posix.resolve(posix.dirname(fileURLToPath(manifest.id)),entries[target.index].path)).href;}
 catch{throw new SourceError('root.snapshot','Choose a captured local project configuration');}
 if(resource!==target.resource||!input.configuredRoots.includes(resource))throw new SourceError('root.stale','The named source path does not match the captured root');
 const pointer='/roots/'+target.index,after=doc.remove(pointer),changed=new SourceDocument(after,manifest.id,true);
 if(changed.issues.length||changed.root.value?.roots?.length!==entries.length-1||
    changed.root.value.roots.some((_entry,index)=>changed.dataJson('/roots/'+index)!==doc.dataJson('/roots/'+(index<target.index?index:index+1))))
  throw new SourceError('root.proof','The source edit did not preserve the other root declarations');
 const resources=input.resources as Resource[],contexts=input.contexts;
 if(!Array.isArray(resources)||!Array.isArray(contexts)||!contexts.length||contexts.length>128||
    JSON.stringify(contexts.map(context=>context.root))!==JSON.stringify(input.configuredRoots)||
    !Array.isArray(input.manifestAliases)||input.manifestAliases.length>256||input.manifestAliases.some(value=>typeof value!=='string'))
  throw new SourceError('root.context','Capture every configured root and approved manifest locator before review');
 const included=resources.find(resource=>resource.id===manifest.id);
 if(included&&(included.text!==manifest.text||included.generation!==manifest.generation||included.identity!==manifest.identity))
  throw new SourceError('edit.stale','API and configuration snapshots disagree about the manifest');
 const locators=new Set([manifest.id,...input.manifestAliases,...(included?.aliases??[])]);
 const usages=new Map<string,any>(),blockers=new Map<string,any>();
 let activeDocs:Map<string,SourceDocument>|undefined;
 const add=(root:string,resource:string,pointer:string,code:string,connection?:string,target?:any)=>{
  const key=JSON.stringify([resource,pointer,code]),previous=blockers.get(key);
  const original=resources.find(value=>value.id===resource),doc=activeDocs?.get(resource);
  let at=pointer;while(at&&doc&&!doc.nodes.has(at))at=at.slice(0,at.lastIndexOf('/'));
  const item={resource,pointer,code,generation:original?.generation,identity:original?.identity,range:doc?.nodes.get(at)?.range??[0,0],connection:connection??'root-analysis',target:target??{resource,pointer},roots:[...new Set([...(previous?.roots??[]),root])]};
  blockers.set(key,item);usages.set(key,item);
 };
 const within=(value:string,owner:string)=>value===owner||value.startsWith(owner+'/');
 const shift=(id:string,pointer:string)=>{
  if(id!==manifest.id||!pointer.startsWith('/roots/'))return pointer;
  const tokens=segments(pointer);
  if(/^(0|[1-9][0-9]*)$/.test(tokens[1])&&Number(tokens[1])>target.index)tokens[1]=String(Number(tokens[1])-1);
  return '/'+tokens.map(escape).join('/');
 };
 for(const context of contexts){
  if(typeof context.root!=='string'||!Array.isArray(context.resources)||!context.resources.includes(context.root)||context.resources.some((id:string)=>!resources.some(resource=>resource.id===id)))
   throw new SourceError('root.context','A captured root context contains an unavailable resource');
  const selected=resources.filter(resource=>context.resources.includes(resource.id)),{graph,docs}=createGraph({root:context.root,resources:selected});
  activeDocs=docs;
  for(const issue of graph.issues)add(context.root,issue.resource,issue.pointer,'root.remove.analysis');
  for(const source of docs.values())for(const issue of source.issues)add(context.root,source.id,'','root.remove.analysis');
  for(const occurrence of documentUriOccurrences(graph))if(occurrence.scope.kind==='example'&&occurrence.field==='externalValue'){
   const {scope,pointer:at,value}=occurrence;
   try{const uri=resolveUri(value,documentUriBase(graph,scope));uri.hash='';
    if(locators.has(uri.href))add(context.root,scope.resource,at,'root.remove.data-consumer','externalValue',{resource:manifest.id,pointer:''});
   }catch{add(context.root,scope.resource,at,'root.remove.analysis');}
  }
  // Ordinary configuration is not an API resource. A declaration-only edit
  // cannot change an API graph that does not contain that physical input.
  if(!context.resources.includes(manifest.id))continue;
  const next=createGraph({root:context.root,resources:selected.map(resource=>resource.id===manifest.id?{...resource,text:after}:resource)}).graph;
  const nextReferences=new Map<string,typeof next.references>();
  const referenceKey=(resource:string,pointer:string,keyword:string)=>JSON.stringify([resource,pointer,keyword]);
  for(const reference of next.references){const key=referenceKey(reference.resource,reference.pointer,reference.keyword),previous=nextReferences.get(key)??[];previous.push(reference);nextReferences.set(key,previous);}
  for(const ref of graph.references){
   if(ref.resource===manifest.id&&within(ref.pointer,pointer))continue;
   const at=ref.pointer+'/'+escape(ref.keyword),destination={resource:ref.targetResource,pointer:ref.targetPointer};
   const direct=ref.targetResource===manifest.id&&(within(ref.targetPointer!,pointer)||within(pointer,ref.targetPointer!));
   const dynamic=ref.dynamic?.candidates.some(candidate=>candidate.resource===manifest.id&&within(candidate.pointer,pointer));
   if(direct||dynamic){add(context.root,ref.resource,at,'root.remove.consumer',ref.connection??ref.keyword,destination);continue;}
   const candidates=nextReferences.get(referenceKey(ref.resource,shift(ref.resource,ref.pointer),ref.keyword)),updated=candidates?.length===1?candidates[0]:undefined;
   // No guessed repair: a pointer that would rebind after an array shift is
   // an exact blocker. Anchored consumers can survive a physical index shift
   // only when the graph proves their base and dynamic candidates unchanged.
   if(!updated||updated.resolution!==ref.resolution||updated.targetResource!==ref.targetResource||updated.targetPointer!==shift(ref.targetResource!,ref.targetPointer!)||updated.base!==ref.base||
      JSON.stringify(updated.dynamic?.candidates.map(value=>[value.resource,value.pointer]).sort())!==JSON.stringify(ref.dynamic?.candidates.map(value=>[value.resource,shift(value.resource,value.pointer)]).sort()))
    add(context.root,ref.resource,at,'root.remove.consumer',ref.connection??ref.keyword,destination);
  }
  for(const issue of next.issues)if(!graph.issues.some(previous=>previous.resource===issue.resource&&previous.pointer===issue.pointer&&previous.code===issue.code))
   add(context.root,issue.resource,issue.pointer,'root.remove.analysis');
 }
 const edits=editsFor([manifest],new Map([[manifest.id,after]]));
 const result={version:1,kind:'root-remove',snapshot:input.snapshot,checkedRoots:contexts.map(context=>context.root),configuredRoots:input.configuredRoots,
  from:{resource:manifest.id,pointer},to:{resource:manifest.id,pointer:'/roots'},transitions:[],edits,
  changes:[{resource:manifest.id,before:manifest.text,after}],usages:[...usages.values()],blockers:[...blockers.values()],
  removed:{name:target.name,resource:target.resource,pointer},remaining:entries.length-1};
 return {...result,identity:createHash('sha256').update(JSON.stringify(result)).digest('hex')};
}

/** Whole-file removal has no text-replacement heuristic. Only the canonical
 * graph establishes incoming consumers; an incomplete graph or a configured
 * root cannot be represented as a proved unused-file deletion. The core owns
 * virtual presence, destination permissions, archives and publication. */
export function planFileDeletion(input:any) {
 const resources=input.resources as Resource[],contexts=input.contexts,target=input.target,source=input.deletionSource as Resource;
 if(!Array.isArray(resources)||!Array.isArray(contexts)||!contexts.length||contexts.length>128||
    !source||typeof source.id!=='string'||typeof source.text!=='string'||source.text.length>16*1024*1024||
    source.id!==target?.resource||source.generation!==target.generation)
  throw new SourceError('file.delete.snapshot','Choose a captured physical source and its configured root contexts');
 let uri:URL;try{uri=new URL(source.id);}catch{throw new SourceError('file.delete.path','Choose an absolute physical file identity');}
 if(uri.protocol!=='file:'||uri.host||uri.hash||uri.search||uri.pathname.endsWith('/'))throw new SourceError('file.delete.path','Choose an absolute physical file identity');
 const included=resources.find(value=>value.id===source.id);
 if(included&&(included.text!==source.text||included.generation!==source.generation||included.identity!==source.identity))
  throw new SourceError('file.delete.snapshot','Root contexts disagree about the captured physical source');
 const usages=new Map<string,any>(),blockers:any[]=[];
 for(const context of contexts) {
  if(typeof context.root!=='string'||!Array.isArray(context.resources)||!context.resources.includes(context.root)||context.resources.some((id:string)=>!resources.some(resource=>resource.id===id)))
   throw new SourceError('refactor.context','A root context has an unavailable resource');
  const {docs,graph}=createGraph({root:context.root,resources:resources.filter(resource=>context.resources.includes(resource.id))});
  if(context.root===source.id)blockers.push({resource:source.id,pointer:'',code:'file.delete.root',roots:[context.root]});
  if(graph.issues.length||[...docs.values()].some(doc=>doc.issues.length))blockers.push({resource:context.root,pointer:'',code:'file.delete.analysis',roots:[context.root]});
  for(const ref of graph.references)if(ref.targetResource===source.id&&ref.resource!==source.id) {
   const id=JSON.stringify([ref.resource,ref.pointer,ref.keyword,ref.connection,ref.targetPointer]);
   let usage=usages.get(id);
   if(!usage){usage={resource:ref.resource,pointer:ref.pointer+'/'+escape(ref.keyword),connection:ref.connection??ref.keyword,target:{resource:source.id,pointer:ref.targetPointer??''},roots:[]};usages.set(id,usage);}
   if(!usage.roots.includes(context.root))usage.roots.push(context.root);
  }
  const locators=new Set([source.id,...(included?.aliases??[])]);
  for(const occurrence of documentUriOccurrences(graph))if(occurrence.scope.kind==='example'&&occurrence.field==='externalValue'&&occurrence.scope.resource!==source.id){
   const {scope,pointer,value}=occurrence;
   let uri:URL;
   try{uri=resolveUri(value,documentUriBase(graph,scope));}catch{
    blockers.push({resource:scope.resource,pointer,code:'file.delete.analysis',roots:[context.root]});continue;
   }
   uri.hash='';
   if(!locators.has(uri.href))continue;
   const id=JSON.stringify([scope.resource,pointer,'externalValue']);
   let usage=usages.get(id);
   if(!usage){usage={resource:scope.resource,pointer,connection:'externalValue',target:{resource:source.id,pointer:''},roots:[]};usages.set(id,usage);}
   if(!usage.roots.includes(context.root))usage.roots.push(context.root);
  }
 }
 const manifest=input.manifest as Resource|undefined;
 if(manifest){
  if(typeof manifest.id!=='string'||typeof manifest.text!=='string'||Buffer.byteLength(manifest.text)>65536||!Number.isInteger(manifest.generation)||manifest.generation<0)
   throw new SourceError('file.delete.snapshot','Choose a bounded captured project configuration');
  const shared=resources.find(value=>value.id===manifest.id);
  if(shared&&(shared.text!==manifest.text||shared.generation!==manifest.generation||shared.identity!==manifest.identity))
   throw new SourceError('file.delete.snapshot','Root contexts disagree about the captured project configuration');
  const doc=new SourceDocument(manifest.text,manifest.id);
  if(doc.issues.length||doc.root.value?.version!==1)throw new SourceError('manifest.version','Expected a version-1 project configuration');
  for(const locator of caseFileLocators(doc))if(locator.resource===source.id){
   const usage={resource:manifest.id,pointer:locator.pointer,range:locator.range,connection:'case-file',target:{resource:source.id,pointer:''},roots:contexts.map((context:any)=>context.root)};
   usages.set(JSON.stringify([manifest.id,locator.pointer,'case-file']),usage);
  }
 }
 const compare=(a:string,b:string)=>a<b?-1:a>b?1:0;
 const resolved=[...usages.values()].sort((a,b)=>compare(a.resource,b.resource)||compare(a.pointer,b.pointer));
 for(const usage of resolved){usage.roots.sort();blockers.push({...usage,code:usage.connection==='case-file'?'file.delete.case-file':'file.delete.consumer'});}
 return {version:1,snapshot:input.snapshot,kind:'file-delete',checkedRoots:contexts.map((context:any)=>context.root),
  identity:createHash('sha256').update(JSON.stringify({snapshot:input.snapshot,resource:source.id,generation:source.generation,identity:source.identity,kind:'file-delete',...(manifest?{configuration:{resource:manifest.id,generation:manifest.generation,identity:createHash('sha256').update(manifest.text).digest('hex')}}:{})})).digest('hex'),
  from:{resource:source.id,pointer:''},to:{resource:source.id,pointer:''},edits:[],usages:resolved,blockers,
  changes:[{resource:source.id,before:source.text,after:'',fileAction:'delete'}],
  transitions:[{resource:source.id,from:'',to:'',mode:'removal'}]};
}
/** Construct a relative spelling, then prove it with the canonical URI parser.
 * This helper neither resolves graph edges nor acquires resources. */
function relative(target:string,base:string):string {
 const to=resolveUri(target,base),from=resolveUri('',base);
 if(to.protocol===from.protocol&&to.host===from.host&&['file:','https:','http:'].includes(to.protocol)) {
  let path=posix.relative(posix.dirname(from.pathname),to.pathname)||posix.basename(to.pathname);
  if(to.pathname.endsWith('/'))path=(path||'.')+'/';
  if(path.split('/')[0].includes(':'))path='./'+path;
  const value=path+to.search+to.hash;
  if(resolveUri(value,base).href===to.href)return value;
 }
 return to.href;
}
function rebaseTemplate(value:string,before:string,after:string,variables:any):string {
 const old=resolveUri('',before),next=resolveUri('',after);
 if(value.startsWith('/')&&old.protocol===next.protocol&&old.host===next.host)return value;
 if(!value.includes('{')){
  const original=resolveServerUrl(value,before).href;
  return resolveServerUrl(value,after).href===original?value:relative(original,after);
 }
 let absolute:string;
 try{absolute=serverTemplate(value,before,variables);}catch(error){
  if(error instanceof SourceError)throw new SourceError(error.code.replace('bundle.','file.move.'),error.message);
  throw error;
 }
 // Rebase only the literal directory prefix. Never parse/normalize a template
 // before substitution: a variable may itself contain slashes or dot segments.
 const directory=resolveUri('.',before),destination=resolveUri('.',after);
 if(absolute.startsWith(directory.href)&&directory.protocol===destination.protocol&&directory.host===destination.host){
  const prefix=posix.relative(destination.pathname,directory.pathname);
  return (prefix?prefix+'/':'')+absolute.slice(directory.href.length);
 }
 return absolute;
}

/** A physical file move is a virtual, immutable-snapshot transformation. The
 * core owns destination permissions and all later filesystem publication.
 * Source values are edited through the existing CST, never serialized objects.
 */
export function planFileMove(input:any) {
 const target=input.target,destination=input.destinationResource,manifest=input.manifest as Resource|undefined;
 if(input.retainIdentity!==undefined&&typeof input.retainIdentity!=='boolean')throw new SourceError('file.move.identity','Choose whether the original URI context is retained');
 const retain=input.retainIdentity===true;
 if(!Array.isArray(input.resources)||!Array.isArray(input.contexts)||!input.contexts.length||input.contexts.length>128)
  throw new SourceError('refactor.context','Choose the configured root contexts for this file move');
 const included=(input.resources as Resource[]).find(r=>r.id===target?.resource),source=(included??input.moveSource) as Resource|undefined;
 if(!source||source.id!==target?.resource||source.generation!==target.generation||typeof source.text!=='string'||source.text.length>16*1024*1024||typeof destination!=='string')throw new SourceError('edit.stale','The captured physical file changed');
 if(included&&input.moveSource&&(input.moveSource.id!==source.id||input.moveSource.generation!==source.generation||input.moveSource.identity!==source.identity||input.moveSource.text!==source.text))
  throw new SourceError('edit.stale','The captured physical source disagrees with its root snapshots');
 const resources:Resource[]=included?input.resources:[...input.resources,source];
 if(manifest?.id===source.id)throw new SourceError('file.move.configuration','Project configuration is not a contract-file move target');
 for(const id of [source.id,destination]) {
  let uri:URL;try{uri=new URL(id);}catch{throw new SourceError('file.move.path','Choose absolute local file identities');}
  if(uri.protocol!=='file:'||uri.host||uri.hash||uri.search||uri.pathname.endsWith('/'))throw new SourceError('file.move.path','Choose absolute local file identities');
 }
 if(source.id.toLowerCase().endsWith('.json')!==destination.toLowerCase().endsWith('.json'))
  throw new SourceError('file.move.format','Keep the physical file in its current YAML or JSON format');
 const move=(id:string)=>id===source.id?destination:id;
 if(destination!==source.id&&resources.some(r=>r.id===destination))throw new SourceError('edit.collision','The destination is already a captured resource');
 const graphs=input.contexts.map((context:any)=>{
  if(!Array.isArray(context.resources)||!context.resources.includes(context.root)||context.resources.some((id:string)=>!resources.some(r=>r.id===id)))
   throw new SourceError('refactor.context','A root context has an unavailable resource');
  const result=createGraph({root:context.root,resources:resources.filter(r=>context.resources.includes(r.id))});
  if(result.graph.issues.length||[...result.docs.values()].some(doc=>doc.issues.length))throw new SourceError('refactor.graph','Resolve invalid, ambiguous or unavailable connections before moving a file');
  return {context,...result};
 });
 // A separately captured unused/example-only file is opaque. Do not seed it
 // into any API graph, even when payload keys resemble openapi/$id/$ref.
 const opaque=!graphs.some(g=>g.docs.has(source.id));
 const retrievals=new Set<string>(graphs.filter(g=>g.docs.has(source.id)).map(g=>g.graph.retrievals.get(source.id)!));
 if(opaque){try{retrievals.add(resolveUri(source.aliases?.[0]??source.id,source.id).href);}catch{throw new SourceError('file.move.path','The captured opaque source has an invalid approved retrieval identity');}}
 if(retrievals.size!==1)throw new SourceError('file.move.base.ambiguous','The configured roots disagree about this resource retrieval identity');
 const retained=retain&&destination!==source.id?[...retrievals][0]:undefined;
 if(retained&&!manifest)throw new SourceError('file.move.mapping.manifest','Retaining a URI context requires an existing project manifest; no manifest was created');
 const outputs=new Map<string,string>(),changes=new Map<string,any>(),usages=new Map<string,any>();
 const repairedKeys=new Map<string,string>();
 const securityBindings:SecurityBindingChange[]=[];
 const referenceKey=(ref:GraphReference)=>JSON.stringify([ref.resource,ref.pointer,ref.keyword]);
 const currentKeyword=(ref:GraphReference)=>repairedKeys.get(referenceKey(ref))??ref.keyword;
 const currentPointer=(resource:string,pointer:string)=>{
  let at=pointer;
  while(at){
   const parent=at.slice(0,at.lastIndexOf('/')),name=segments(at).at(-1)!;
   const next=repairedKeys.get(JSON.stringify([resource,parent,name]));
   if(next!==undefined)return parent+'/'+escape(next)+pointer.slice(at.length);
   at=parent;
  }
  return pointer;
 };
 let count=0,cost=0,revision=0;
 const set=(id:string,pointer:string,value:string,reason:string,rename=false)=>{
  const resource=resources.find(r=>r.id===id)!,doc=new SourceDocument(outputs.get(id)??resource.text,id);
  if(rename?segments(pointer).at(-1)===value:doc.node(pointer).value===value)return;
  const literalOwner=graphs.find(g=>g.graph.literalContainer(id,pointer)!==undefined);
  if(literalOwner)throw new SourceError('file.move.literal.ownership','A required file-move repair also changes literal data; retain the original URI context or resolve the dual source ownership explicitly',literalOwner.docs.get(id)?.dataNode(pointer)?.range);
  if(++count>512||(cost+=doc.text.length*2)>128*1024*1024)throw new SourceError('limit.refactor.file','The file-move edit review exceeds its bounded budget');
  doc.assertSafe(pointer);
  if(rename){
   // A Security Requirement URI is a member name, with its scope/role array
   // untouched. Reuse the canonical CST writer and its collision/alias guards.
   const result=propose({snapshot:input.snapshot,resources:[{...resource,text:doc.text}],target:{resource:id,generation:resource.generation,pointer:''},actions:[{kind:'rename',pointer,name:value}]});
   let text=doc.text;for(const edit of [...result.edits].reverse())text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
   outputs.set(id,text);
  }else outputs.set(id,doc.set(pointer,value));
  revision++;
  changes.set(id+'#'+pointer,{resource:id,pointer,reason});
 };
 const current=()=>resources.map(r=>({...r,id:move(r.id),text:outputs.get(r.id)??r.text,...(retained&&r.id===source.id?{aliases:[retained]}:{})}));
 // One cached proof graph, not one per reference or an unbounded cache of all
 // roots. Only actual source edits invalidate it; all inputs are immutable.
 let cached:{owner:typeof graphs[number];seed:boolean;revision:number;result:ReturnType<typeof createGraph>}|undefined;
 const rebuild=(g:typeof graphs[number],seed=true)=>{
  if(cached?.owner===g&&cached.seed===seed&&cached.revision===revision)return cached.result;
  const result=createGraph({root:move(g.context.root),resources:current().filter(r=>g.context.resources.map(move).includes(r.id)),
   ...(seed?{occurrences:[...g.graph.scopes.values()].map(at=>({resource:move(at.resource),pointer:currentPointer(at.resource,at.pointer),kind:at.kind}))}:{})});
  cached={owner:g,seed,revision,result};return result;
 };
 if(destination!==source.id) {
  let serializedConsumer=false;
  // Retain authored resource identities, outer first. A relative identifier is
  // rebased, not replaced with a new identity at its new filesystem location.
  for(const g of graphs)if(g.docs.has(source.id)) {
   const before=g.docs.get(source.id)!,retrieval=g.graph.retrievals.get(source.id)!;
   const self=before.nodes.get('/$self');
   if(g.graph.scope(source.id,'').family==='3.2'&&typeof self?.value==='string'&&resolveUri(self.value,retrieval).href!==resolveUri(self.value,rebuild(g).graph.retrievals.get(destination)!).href)
    set(source.id,'/$self',relative(resolveUri(self.value,retrieval).href,rebuild(g).graph.retrievals.get(destination)!),'document-identity');
   for(const at of [...g.graph.scopes.values()].filter(at=>at.resource===source.id&&at.kind==='schema'&&before.nodes.has(at.pointer+'/$id')).sort((a,b)=>a.pointer.length-b.pointer.length)) {
    const after=rebuild(g).graph,now=after.scopes.get(destination+'#'+at.pointer)!;
    if(now.base===at.base)continue;
    const parent=at.pointer?after.scope(destination,at.pointer.slice(0,at.pointer.lastIndexOf('/'))).base:after.retrievals.get(destination)!;
    set(source.id,at.pointer+'/$id',relative(at.base,parent),'schema-resource-identity');
   }
   // Preserve each typed URI's actual base, not a universal retrieval base.
   // OAuth endpoints are Server-relative and deliberately absent here.
   const afterUris=rebuild(g).graph,newRetrieval=afterUris.retrievals.get(destination)!;
   for(const at of g.graph.scopes.values())if(at.resource===source.id)for(const field of documentUriFields(at,before.node(at.pointer).value)) {
    const pointer=at.pointer+'/'+escape(field),value=before.nodes.get(pointer)?.value;
    const oldBase=documentUriBase(g.graph,at),newBase=documentUriBase(afterUris,afterUris.scopes.get(destination+'#'+at.pointer)!);
    if(newBase!==oldBase&&typeof value==='string'&&!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(value)) {
     // Shared template semantics do not normalize before substitution.
     const next=at.kind==='server'?rebaseTemplate(value,oldBase,newBase,before.node(at.pointer).value?.variables):relative(resolveUri(value,oldBase).href,newBase);
     set(source.id,pointer,next,at.kind==='server'?'retrieval-relative-url':'description-relative-uri');
    }
   }
   for(const at of g.graph.scopes.values())if(at.resource===source.id) {
    const description=before.nodes.get(at.pointer+'/description')?.value;
    if(newRetrieval!==retrieval&&typeof description==='string'&&hasRelativeMarkdownLinks(description))
     throw new SourceError('file.move.documentation','An authored relative Markdown link needs an explicit reviewed source rebase before this file can move');
   }
  }
  // externalValue locates opaque serialized bytes, not a schema/reference
  // target. Repair only the captured physical locator; approved canonical
  // mappings retain their identities. Do not interpret a data fragment as a
  // JSON Pointer, and preserve its authored spelling during path repair.
  const dataRepairs=new Map<string,string>();
  for(const g of graphs){
   let after:ReturnType<typeof rebuild>['graph']|undefined;
   const currentDocs=new Map<string,SourceDocument>();
   for(const occurrence of documentUriOccurrences(g.graph))if(occurrence.scope.kind==='example'&&occurrence.field==='externalValue'){
   const {scope,pointer,value}=occurrence;
   let old:URL;
   try{old=resolveUri(value,documentUriBase(g.graph,scope));}catch{throw new SourceError('file.move.example-uri','An external example has an invalid source URI at '+pointer);}
   old.hash='';
   const aliases=source.aliases??[];
   if(old.href!==source.id&&!aliases.includes(old.href))continue;
   serializedConsumer=true;
   after??=rebuild(g).graph;
   const at=after.scopes.get(move(scope.resource)+'#'+scope.pointer)!;
   const fragment=value.includes('#')?value.slice(value.indexOf('#')):'';
   const next=relative(!retained&&old.href===source.id?destination:old.href,documentUriBase(after,at))+fragment;
   const id=scope.resource+'#'+pointer,previous=dataRepairs.get(id);
   if(previous!==undefined&&previous!==next)throw new SourceError('refactor.context.ambiguous','Configured roots require conflicting external-example locator repairs');
   dataRepairs.set(id,next);
   // Retain a no-op spelling whenever the current authored locator still has
   // the proved target; an equivalent absolute URI is not an automatic edit.
   let doc=currentDocs.get(scope.resource);
   if(!doc){doc=new SourceDocument(outputs.get(scope.resource)??g.docs.get(scope.resource)!.text,scope.resource);currentDocs.set(scope.resource,doc);}
   const currentValue=doc.node(pointer).value;
   const wanted=resolveUri(next,documentUriBase(after,at)).href;
   if(resolveUri(currentValue,documentUriBase(after,at)).href!==wanted){set(scope.resource,pointer,next,'external-example-locator');currentDocs.delete(scope.resource);}
   const usage=usages.get(id)??{resource:scope.resource,pointer,connection:'externalValue',target:{resource:source.id,pointer:''},roots:[]};
   if(!usage.roots.includes(g.context.root))usage.roots.push(g.context.root);usages.set(id,usage);
   }
  }
  const repairs=new Map<string,string>();
  for(const g of graphs)for(const ref of g.graph.references) {
   if(ref.resolution!=='resolved')throw new SourceError('refactor.graph','Every reviewed semantic connection must resolve');
   const after=rebuild(g),from=after.graph.scopes.get(move(ref.resource)+'#'+currentPointer(ref.resource,ref.pointer))!,to=after.graph.scopes.get(move(ref.targetResource!)+'#'+currentPointer(ref.targetResource!,ref.targetPointer!))!;
   const now=after.graph.references.find(r=>same(r,from)&&r.keyword===currentKeyword(ref));
   let value=now?.value??ref.value;
   // A physical locator must survive cold acquisition as well as a warm graph.
   // Declared canonical identities stay unchanged; only the known old retrieval
   // locator changes. Preserve the exact authored fragment spelling.
   if(ref.connection!=='operationId'&&!implicitNameReference(ref)) {
    const old=resolveUri(ref.value,ref.base),physical=new URL(source.id);
    const hash=old.hash;old.hash='';
    if(!retained&&old.href===physical.href&&!(ref.resource===source.id&&ref.value.startsWith('#')&&now?.resolution==='resolved'&&same({resource:now.targetResource,pointer:now.targetPointer},to))) {
     const data=g.docs.get(source.id)!.root.value;
     if(String(data?.openapi).startsWith('3.2.')&&typeof data?.$self==='string')
      throw new SourceError('file.move.self-routing','A declared OpenAPI identity needs a portable approved resource mapping before its physical retrieval route can move');
     value=relative(destination+hash,from.base);
    }
    else if(!same({resource:now?.targetResource,pointer:now?.targetPointer},to)||now?.resolution!=='resolved')value=referenceValue(after.graph,from,to,ref.keyword)??'';
   }
   if(!value)throw new SourceError('file.move.address','A connection has no proven address after the move');
   if(implicitNameReference(ref)||ref.connection==='operationId') {
    if(now?.resolution!=='resolved'||!same({resource:now.targetResource,pointer:now.targetPointer},to))throw new SourceError('file.move.implicit','Moving the file would change an implicit connection');
   }else {
    let proof=after.graph.resolveConnection({...ref,...from,kind:ref.kind,value});
    const relocating=value!==currentKeyword(ref)||proof.resolution!=='resolved'||!same({resource:proof.targetResource,pointer:proof.targetPointer},to);
    const occupied=ref.connection==='security'&&relocating?new Set([...new SourceDocument(outputs.get(ref.resource)??g.docs.get(ref.resource)!.text,ref.resource).node(ref.pointer).children.keys()].filter(name=>name!==currentKeyword(ref))):undefined;
    if(occupied?.has(value)||proof.resolution!=='resolved'||!same({resource:proof.targetResource,pointer:proof.targetPointer},to)){
     const alternative=referenceValue(after.graph,{...from,kind:ref.kind},to,ref.keyword,occupied);
     if(alternative!==undefined){value=alternative;proof=after.graph.resolveConnection({...ref,...from,kind:ref.kind,value});}
    }
    if(proof.resolution!=='resolved'||!same({resource:proof.targetResource,pointer:proof.targetPointer},to))throw new SourceError('file.move.address','A repaired locator does not retain its exact captured target at '+ref.pointer+' ('+proof.resolution+')');
   }
   const key=ref.resource+'#'+ref.pointer+'/'+escape(ref.keyword),previous=repairs.get(key);
   if(previous!==undefined&&previous!==value)throw new SourceError('refactor.context.ambiguous','Configured roots require conflicting repairs of one physical occurrence');
   repairs.set(key,value);
   if(value!==ref.value){
    set(ref.resource,ref.pointer+'/'+escape(currentKeyword(ref)),value,'reference-locator',ref.connection==='security');
    if(ref.connection==='security')repairedKeys.set(referenceKey(ref),value);
   }
   if(ref.resource===source.id||ref.targetResource===source.id||value!==ref.value) {
    const usage=usages.get(key)??{resource:ref.resource,pointer:ref.pointer+'/'+escape(ref.keyword),connection:ref.connection??ref.keyword,target:{resource:ref.targetResource,pointer:ref.targetPointer},roots:[]};
    if(!usage.roots.includes(g.context.root))usage.roots.push(g.context.root);usages.set(key,usage);
   }
  }
  if(serializedConsumer&&(outputs.get(source.id)??source.text)!==source.text)
   throw new SourceError('file.move.example-content','This source is also an external serialized example; repairing its contract text would change the example bytes. Retain its original URI context instead');
  for(const g of graphs) {
   const after=rebuild(g,false).graph,cold=coldGraph(move(g.context.root),current());
   if(after.issues.length||cold.issues.length)throw new SourceError('file.move.retrieval','The moved project would not resolve after reopening from its configured roots');
   for(const old of g.graph.references)for(const graph of [after,cold]) {
    const now=graph.references.find(r=>r.resource===move(old.resource)&&r.pointer===currentPointer(old.resource,old.pointer)&&r.keyword===currentKeyword(old));
    if(now?.resolution!=='resolved'||now.targetResource!==move(old.targetResource!)||now.targetPointer!==currentPointer(old.targetResource!,old.targetPointer!)||
      old.dynamic&&JSON.stringify(old.dynamic.candidates.map(c=>[move(c.resource),c.pointer]).sort())!==JSON.stringify(now.dynamic?.candidates.map(c=>[c.resource,c.pointer]).sort()))
     throw new SourceError('file.move.target','The moved graph does not preserve every captured target and dynamic navigation context');
    if(manifest&&graph===after&&old.connection==='security')securityBindings.push({root:g.context.root,before:old,after:now});
   }
  }
 }
 // A manifest is configuration, not another OpenAPI graph resource. Its exact
 // captured text is edited separately and remains part of core freshness checks.
 if(manifest&&destination!==source.id) {
  let doc=new SourceDocument(manifest.text,manifest.id);
  if(doc.issues.length||doc.root.value?.version!==1||!Array.isArray(doc.root.value?.roots))throw new SourceError('manifest.version','Expected a version-1 project manifest');
  for(const locator of caseFileLocators(doc))if(locator.resource===source.id){
   if((outputs.get(source.id)??source.text)!==source.text)
    throw new SourceError('file.move.case-file.content','This source is also a saved upload; repairing its contract text would change the uploaded bytes. Retain its original URI context instead',locator.range,undefined,{resource:manifest.id,pointer:locator.pointer,range:locator.range});
   if(resources.some(resource=>resource.id===manifest.id))throw new SourceError('refactor.configuration.ownership','Project configuration cannot also be an edited API graph resource',locator.range,undefined,{resource:manifest.id,pointer:locator.pointer,range:locator.range});
   doc=new SourceDocument(movedCaseFileSource(doc,locator,destination),manifest.id);
   usages.set(JSON.stringify([manifest.id,locator.pointer,'case-file']),{resource:manifest.id,pointer:locator.pointer,range:locator.range,connection:'case-file',target:{resource:source.id,pointer:''},roots:input.contexts.map((context:any)=>context.root)});
  }
  for(let i=0;i<doc.root.value.roots.length;i++) {
   const pointer='/roots/'+i+'/path',value=doc.nodes.get(pointer)?.value;
   if(typeof value!=='string')throw new SourceError('manifest.root','A configured root has no source path');
   const original=pathToFileURL(posix.resolve(posix.dirname(fileURLToPath(manifest.id)),value)).href;
   if(original===source.id)doc=new SourceDocument(doc.set(pointer,posix.relative(posix.dirname(fileURLToPath(manifest.id)),fileURLToPath(destination))),manifest.id);
  }
  const mappings=doc.nodes.get('/resourceMappings');
  if(mappings&&mappings.kind!=='object')throw new SourceError('resource.configuration','Resource mappings must be an object');
  if(mappings)for(const [name,node]of mappings.children){
   if(typeof node.value!=='string')throw new SourceError('resource.configuration','Resource mappings require local path strings');
   const original=pathToFileURL(posix.resolve(posix.dirname(fileURLToPath(manifest.id)),node.value)).href;
   if(original===source.id)doc=new SourceDocument(doc.set('/resourceMappings/'+escape(name),posix.relative(posix.dirname(fileURLToPath(manifest.id)),fileURLToPath(destination))),manifest.id);
  }
  if(retained){
   let name=relative(retained,manifest.id);
   for(const [key]of mappings?.children??[])if(resolveUri(key,manifest.id).href===retained)name=key;
   const path=posix.relative(posix.dirname(fileURLToPath(manifest.id)),fileURLToPath(destination));
   doc=new SourceDocument(doc.nodes.has('/resourceMappings')?doc.set('/resourceMappings/'+escape(name),path):doc.set('/resourceMappings',{[name]:path}),manifest.id);
  }
  if(doc.text!==manifest.text)outputs.set(manifest.id,doc.text);
 }
 if(manifest){
  const configuration=securityConfigurationCopies({...manifest,text:outputs.get(manifest.id)??manifest.text},securityBindings);
  if(configuration?.actions.length){
   if(resources.some(resource=>resource.id===manifest.id))throw new SourceError('refactor.configuration.ownership','Project configuration cannot also be an edited API graph resource');
   const result=propose({snapshot:input.snapshot,resources:[configuration.source],target:{resource:manifest.id,generation:manifest.generation,pointer:''},actions:configuration.actions});
   let text=configuration.source.text;for(const edit of [...result.edits].reverse())text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
   outputs.set(manifest.id,text);
   for(const usage of configuration.usages)usages.set(JSON.stringify([usage.resource,usage.pointer,usage.target.resource,usage.target.pointer]),usage);
  }
  if(Buffer.byteLength(outputs.get(manifest.id)??manifest.text,'utf8')>65536)throw new SourceError('limit.refactor.configuration','The repaired project configuration would exceed 64 KiB',[0,manifest.text.length],'unsupported',{resource:manifest.id,pointer:'',range:[0,manifest.text.length]});
 }
 const all=manifest?[...resources,manifest]:resources,edits=editsFor(all,outputs),from={resource:source.id,pointer:''},to={resource:destination,pointer:''};
 const data={version:1,kind:'file-move',snapshot:input.snapshot,checkedRoots:input.contexts.map((c:any)=>c.root),from,to,edits,
  changes:[...edits.map(edit=>({resource:edit.buffer,before:all.find(r=>r.id===edit.buffer)!.text,after:outputs.get(edit.buffer)!,fields:[...changes.values()].filter(c=>c.resource===edit.buffer)})),
   ...(!edits.some(e=>e.buffer===source.id)&&source.id!==destination?[{resource:source.id,before:source.text,after:source.text,pathOnly:true}]:[])],
  usages:[...usages.values()],transitions:source.id===destination?[]:[{resource:source.id,from:'',to:'',toResource:destination}],
  file:{source:source.id,destination,generation:source.generation,...(opaque?{opaque:true}:{}),...(retained?{retainedIdentity:retained}:{})},impact:{externalConsumers:'Unopened projects and external consumers are not rewritten; review their old physical locators separately.'}};
 return {...data,identity:createHash('sha256').update(JSON.stringify(data)).digest('hex')};
}
import {hasRelativeMarkdownLinks} from './markdown_links';
