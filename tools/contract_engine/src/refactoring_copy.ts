import {createHash} from 'node:crypto';
import {createGraph,Resource} from './engine';
import {SourceDocument,SourceError,escape,segments} from './document';
import {referenceValue} from './reference_choices';
import {fieldsFor,componentFamily,componentLocation,documentUriOccurrences} from './authoring';
import {documentUriBase,ReferenceGraph,resolveUri} from './reference_graph';
import {coldGraph} from './reference_selection';
import {ParameterSemantics} from './parameter_semantics';
import {standardOperationMethods} from './contexts';
import {serverTemplate} from './derived_bundle';
import {hasRelativeMarkdownLinks} from './markdown_links';

const inside=(pointer:string,owner:string)=>pointer===owner||pointer.startsWith(owner+'/');

// A separately referenced payload is a semantic occurrence in its original
// location, not an intrinsic child of every object that contains its bytes.
// Copying an owner does not copy that unrelated consumer into the new payload.
const intrinsic=(graph:ReferenceGraph,resource:string,pointer:string,root:string)=>{
 const literal=graph.literalContainer(resource,pointer);
 return literal===undefined||literal===root||!inside(literal,root);
};
const semanticOwner=(graphs:{graph:ReferenceGraph}[],resource:string,pointer:string,range:[number,number])=>{
 if(graphs.some(owner=>owner.graph.literalContainer(resource,pointer)!==undefined))
  throw new SourceError('refactor.literal.ownership','This occurrence also belongs to literal data. Inline an API reference occurrence or edit the data owner explicitly before structural refactoring',range);
};
const same=(a:any,b:any)=>a?.resource===b?.resource&&a?.pointer===b?.pointer;
const editBudget=(resources:Resource[])=>{
 let operations=0,bytes=0;
 return (id:string)=>{
  bytes+=(resources.find(r=>r.id===id)?.text.length??0)*2;
  if(++operations>256||bytes>128*1024*1024)throw new SourceError('limit.refactor.copy','The source-preserving copy exceeds its bounded edit budget; no edits were prepared');
 };
};
const value=(doc:SourceDocument,pointer:string)=>doc.dataJson(pointer,n=>
 n.kind==='object'?(n.children.size?undefined:'{}'):n.kind==='array'?(n.children.size?undefined:'[]'):
 typeof n.value==='number'?undefined:JSON.stringify(n.value));

/** Copy an authored CST value, not a JS object projection. Only the selected
 * value is reindented. The original document, including comments elsewhere,
 * is never serialized. A reparse proves exact JSON-compatible scalar values,
 * including numeric lexemes, block clipping and multiline Unicode strings. */
function replaceValue(doc:SourceDocument,pointer:string,source:SourceDocument,from:string):SourceDocument {
 const node=doc.node(pointer),original=source.node(from);
 doc.assertSafe(pointer);source.assertSafe(from);
 doc.assertUnshared(pointer);
 for(const item of source.nodes.values())if(inside(item.pointer,from)&&(item.shared||item.keyShared))
  throw new SourceError('refactor.copy.shared','An anchored or aliased value needs explicit source ownership before copying');
 const block=source.format==='yaml'&&!original.flow&&(original.kind==='object'||original.kind==='array')&&original.children.size>0;
 const parent=doc.nodes.get(pointer.slice(0,pointer.lastIndexOf('/')));
 if(block&&(doc.format==='json'||parent?.flow))throw new SourceError('refactor.copy.flow','An authored YAML block cannot be copied into a nonempty flow container without changing its representation');
 if(source.format==='yaml'&&doc.format==='json'){
  try{
   const strict=new SourceDocument(source.text.slice(...original.range),'copied-value.json');
   if(value(strict,'')!==value(source,from))throw Error('Different source value');
  }catch{throw new SourceError('refactor.copy.format','Copying this YAML representation into JSON needs an explicit representation change');}
 }
 let raw=source.text.slice(...original.range),prefix='';
 const oldIndent=source.indent(original.range[0]);
 let indent=doc.indent(node.range[0]);
 if(block&&doc.text.slice(doc.lineStart(node.range[0]),node.range[0]).trim()){
  indent+=2;prefix=doc.newline+' '.repeat(indent);
 }
 if(doc.format==='yaml'&&source.format==='yaml') {
  const delta=indent-oldIndent;
  raw=raw.replace(/(\r\n|\r|\n)( *)(?=[^\r\n])/g,(_all,line,spaces)=>{
   if(spaces.length+delta<0)throw new SourceError('refactor.copy.indent','The authored multiline value cannot be reindented safely');
   return line+' '.repeat(spaces.length+delta);
  });
 }
 // A YAML mapping range can include the structural newline before a sibling.
 // Keep that separator even when the replacement is a flow value or scalar.
 const ending=/\r\n$|\r$|\n$/.exec(doc.text.slice(...node.range))?.[0]??'';
 if(ending&&!/[\r\n]$/.test(raw))raw+=ending;
 const next=new SourceDocument(doc.replace(...node.range,prefix+raw),doc.id);
 if(value(next,pointer)!==value(source,from))throw new SourceError('refactor.copy.value','Copying this representation would change an authored value; no edits were prepared');
 return next;
}

function insertValue(doc:SourceDocument,pointer:string,source:SourceDocument,from:string):SourceDocument {
 if(doc.nodes.has(pointer))throw new SourceError('edit.collision','The destination definition already exists');
 const finalNewline=/[\r\n]$/.test(doc.text);
 const parts=segments(pointer);let missing=1;
 while(missing<parts.length&&doc.nodes.has('/'+parts.slice(0,missing).map(escape).join('/')))missing++;
 const ancestor=missing===1?'':'/'+parts.slice(0,missing-1).map(escape).join('/');
 const parent=doc.node(ancestor);
 if(!['object','array'].includes(parent.kind)||parent.shared)throw new SourceError('refactor.copy.destination','Choose an unambiguous authored collection');
 if(parent.kind==='array'&&(missing!==parts.length||parts.at(-1)!==String(parent.children.size)))
  throw new SourceError('refactor.copy.destination','An authored array copy must append at its captured end');
 let seed:any=null;
 for(let i=parts.length-1;i>=missing;i--)seed={[parts[i]]:seed};
 const first='/'+parts.slice(0,missing).map(escape).join('/');
 // An empty flow collection has no authored children to reformat. Converting
 // just that explicit destination permits preserving a block value's source.
 if(doc.format==='yaml'&&parent.flow&&!parent.children.size&&ancestor&&
    !doc.node(ancestor.slice(0,ancestor.lastIndexOf('/'))).flow&&source.format==='yaml'&&!source.node(from).flow) {
  const generated=new SourceDocument(doc.emit(parent.kind==='array'?[seed]:{[parts[missing-1]]:seed}), 'destination.yaml');
  doc=replaceValue(doc,ancestor,generated,'');
 }else doc=new SourceDocument(doc.set(first,seed),doc.id);
 const copied=replaceValue(doc,pointer,source,from);
 if(finalNewline||!/[\r\n]$/.test(copied.text))return copied;
 const boundedEnd=new SourceDocument(copied.text.replace(/[\r\n]+$/,''),copied.id);
 if(value(boundedEnd,pointer)!==value(source,from))
  throw new SourceError('refactor.copy.final-newline','This block scalar requires an explicit destination before the final source line to preserve its value and final-newline state');
 return boundedEnd;
}

function retainOccurrenceComments(before:SourceDocument,after:SourceDocument,pointer:string,from=pointer,includeEntry=false):SourceDocument {
 const existing=new Map<string,number>();
 for(const range of after.comments(pointer,includeEntry)){const text=after.text.slice(...range);existing.set(text,(existing.get(text)??0)+1);}
 const missing:string[]=[];let bytes=0;
 for(const range of before.comments(from,includeEntry)){
  const text=before.text.slice(...range),count=existing.get(text)??0;
  if(count){existing.set(text,count-1);continue;}
  missing.push(text);bytes+=text.length;
  if(missing.length>20000||bytes>1024*1024)throw new SourceError('limit.refactor.comments','The authored comment review exceeds its bounded size');
 }
 if(!missing.length)return after;
 const node=after.node(pointer),at=after.lineStart(node.entryStart??node.range[0]);
 const indent=after.text.slice(at).match(/^ */)![0];
 // Comments belonging to the removed reference stay as source comments before
 // its owning line. Flow syntax may share that line with an ancestor; no data
 // is scanned, no comment text is interpreted, and no other source is rewritten.
 const text=after.replace(at,at,missing.map(comment=>indent+comment+after.newline).join(''));
 const next=new SourceDocument(text,after.id);
 if(value(next,pointer)!==value(after,pointer))throw new SourceError('refactor.copy.comments','Retaining the reference comments would change an authored value');
 return next;
}

function capture(input:any) {
 const resources=input.resources as Resource[],target=input.target;
 if(!Array.isArray(resources)||!Array.isArray(input.contexts)||!input.contexts.length||input.contexts.length>128)
  throw new SourceError('refactor.context','Choose the configured roots whose consumers are being reviewed');
 const resource=resources.find(r=>r.id===target?.resource);
 if(!resource||resource.generation!==target.generation)throw new SourceError('edit.stale','The captured occurrence changed');
 const graphs=input.contexts.map((context:any)=>{
  if(!Array.isArray(context.resources)||!context.resources.includes(context.root)||context.resources.some((id:string)=>!resources.some(r=>r.id===id)))
   throw new SourceError('refactor.context','A root context contains an unavailable resource');
  const result=createGraph({root:context.root,resources:resources.filter(r=>context.resources.includes(r.id))});
  if(result.graph.issues.length||[...result.docs.values()].some(doc=>doc.issues.length))
   throw new SourceError('refactor.graph','Resolve unavailable, invalid or ambiguous connections before reviewing this refactoring');
  return {context,...result};
 });
 const owning=graphs.filter(g=>g.graph.scopes.has(resource.id+'#'+target.pointer)),selected=owning.find(g=>g.context.root===target.root)??owning[0];
 if(!selected)throw new SourceError('refactor.copy.context','Choose a specification object, not arbitrary example or extension data');
 const doc=selected.docs.get(resource.id)!,node=doc.node(target.pointer),scope=selected.graph.scopes.get(resource.id+'#'+target.pointer)!;
 if(target.pointer===''&&selected.graph.specifications.has(doc.id))
  throw new SourceError('refactor.copy.context','An OpenAPI document root cannot become its own extracted or inlined object occurrence');
 if(node.shared||!doc.syntaxSafe(target.pointer)||target.range&&JSON.stringify(target.range)!==JSON.stringify(node.range)||target.expected!==undefined&&target.expected!==resource.text.slice(...node.range))
  throw new SourceError('edit.stale','The captured physical occurrence changed or is shared');
 if(owning.some(g=>g.graph.scopes.get(resource.id+'#'+target.pointer)?.kind!==scope.kind))
  throw new SourceError('refactor.context.ambiguous','This physical occurrence has different object kinds in configured roots');
 for(const g of owning)for(const ref of g.graph.references)if(ref.resolution==='resolved'&&ref.targetResource===resource.id&&inside(ref.targetPointer!,target.pointer)){
  const at=g.graph.scopes.get(resource.id+'#'+ref.targetPointer);
  if(at&&at.kind!==ref.kind)throw new SourceError('refactor.context.ambiguous','This source value has distinct typed occurrences; choose explicit ownership before relocating it');
 }
 return {resources,target,resource,graphs,owning,selected,doc,node,scope};
}

export function editsFor(resources:Resource[],outputs:Map<string,string>) {
 return [...outputs].filter(([id,text])=>resources.find(r=>r.id===id)!.text!==text).map(([id,text])=>{
  const resource=resources.find(r=>r.id===id)!,before=resource.text;let start=0,a=before.length,b=text.length;
  while(start<Math.min(a,b)&&before[start]===text[start])start++;
  while(a>start&&b>start&&before[a-1]===text[b-1]){a--;b--;}
  if(start&&/[\uDC00-\uDFFF]/.test(before[start]))start--;
  if(a<before.length&&/[\uDC00-\uDFFF]/.test(before[a])){a++;b++;}
  return {buffer:id,generation:resource.generation,start,end:a,expected:before.slice(start,a),replacement:text.slice(start,b)};
 });
}

/** Relocate only graph-established URI fields in an explicit copied object.
 * Original source data and shared definitions remain untouched. The graph
 * supplies each base; this neither follows externalValue nor resolves a new
 * dependency. Absolute spellings avoid guessing a destination-relative route. */
function relocateCopiedUris(before:ReferenceGraph,after:ReferenceGraph,from:{resource:string;pointer:string},to:{resource:string;pointer:string},
 outputs:Map<string,string>,repairs:Map<string,string>,admit:(id:string)=>void,intrinsicOnly=false) {
 let current=after.docs.get(to.resource)!;
 for(const occurrence of documentUriOccurrences(before)){
  const {scope,pointer,value}=occurrence;
  if(scope.resource!==from.resource||!inside(scope.pointer,from.pointer))continue;
  if(intrinsicOnly&&!intrinsic(before,scope.resource,scope.pointer,from.pointer))continue;
  const nextPointer=to.pointer+pointer.slice(from.pointer.length),nextScope=after.scopes.get(to.resource+'#'+to.pointer+scope.pointer.slice(from.pointer.length));
  if(!nextScope||nextScope.kind!==scope.kind)throw new SourceError('refactor.copy.uri-context','A copied URI field has no matching typed destination');
  const originalBase=documentUriBase(before,scope),nextBase=documentUriBase(after,nextScope);
  const meaning=(text:string,base:string)=>{
   try{return scope.kind==='server'?serverTemplate(text,base,before.docs.get(scope.resource)!.node(scope.pointer).value?.variables):resolveUri(text,base).href;}
   catch{throw new SourceError('refactor.copy.uri-context','A copied URI or Server template has no proved relocation at '+pointer);}
  };
  const wanted=meaning(value,originalBase),key='uri:'+to.resource+'#'+nextPointer,previous=repairs.get(key);
  if(previous!==undefined&&previous!==wanted)throw new SourceError('refactor.context.ambiguous','Configured roots give a copied URI different original targets');
  repairs.set(key,wanted);
  const now=current.node(nextPointer).value;
  if(typeof now!=='string')throw new SourceError('refactor.copy.uri-context','A copied URI field changed representation');
  if(meaning(now,nextBase)===wanted)continue;
  const spelling=scope.kind==='server'?wanted:wanted.split('#')[0]+(value.includes('#')?value.slice(value.indexOf('#')):'');
  if(meaning(spelling,nextBase)!==wanted)throw new SourceError('refactor.copy.uri-context','The destination cannot preserve an authored URI meaning');
  admit(to.resource);const text=current.set(nextPointer,spelling);outputs.set(to.resource,text);current=new SourceDocument(text,to.resource);
 }
}

function planCopy(input:any,moving=false) {
 const {resources,target,resource,graphs,owning,selected,doc,node,scope}=capture(input),family=componentFamily(scope.kind,scope.family);
 if(!family||scope.kind==='media'&&scope.family!=='3.2'||typeof input.name!=='string'||!/^[a-zA-Z0-9._-]+$/.test(input.name)||input.name.length>4096)
  throw new SourceError('refactor.copy.context','Choose an inline reusable object and a legal component name');
 const destinationId=input.destinationResource??resource.id,destinationResource=resources.find(r=>r.id===destinationId);
 const fragment=input.destinationFragment===true;
 if(fragment&&(!moving||!destinationResource||destinationResource.text!=='null'||graphs.some(g=>g.docs.has(destinationId))))
  throw new SourceError('refactor.extract.destination','A new fragment destination must be a separately captured empty planning slot');
 if(fragment&&(typeof node.value?.openapi==='string'||typeof node.value?.swagger==='string'))
  throw new SourceError('refactor.copy.resource-context','An authored OpenAPI-looking keyword needs an unambiguous resource interpretation before copying this object to a document root');
 const destinationDoc=fragment?new SourceDocument(destinationResource!.text,destinationId):destinationResource&&graphs.map(g=>g.docs.get(destinationId)).find(Boolean);
 if(!destinationDoc||!fragment&&!graphs.some(g=>g.graph.specifications.get(destinationId)?.family===scope.family))
  throw new SourceError('refactor.extract.destination','Choose an OpenAPI document as the component destination');
 const definition=(scope.family==='2.0'?/^\/(definitions|parameters|responses|securityDefinitions)\/[^/]+$/:/^\/components\/[^/]+\/[^/]+$/).test(target.pointer);
 if(moving?!definition:definition)
  throw new SourceError('refactor.extract.definition',moving?'Choose an authored component definition to move':'Choose an inline object, not an existing component definition');
 if(typeof node.value?.$ref==='string'||typeof node.value?.$dynamicRef==='string')
  throw new SourceError('refactor.extract.definition','Choose an inline object, not an existing definition or reference occurrence');
 const cross=destinationId!==resource.id;
 const destination=fragment?'':componentLocation(family,scope.family)!+'/'+escape(input.name),move=(id:string,pointer:string)=>id===resource.id&&inside(pointer,target.pointer)?destination+pointer.slice(target.pointer.length):pointer;
 const movedResource=(id:string,pointer:string)=>id===resource.id&&inside(pointer,target.pointer)?destinationId:id;
 if(moving&&!cross&&destination===target.pointer)return {version:1,kind:'component-move',snapshot:input.snapshot,edits:[],changes:[],usages:[],transitions:[],from:target,to:target,checkedRoots:input.contexts.map((c:any)=>c.root)};
 semanticOwner(owning,resource.id,target.pointer,node.range);
 if(cross)for(const g of owning)for(const at of g.graph.scopes.values())if(at.resource===resource.id&&inside(at.pointer,target.pointer)){
  const data=doc.node(at.pointer).value;
  if(typeof data?.description==='string'&&hasRelativeMarkdownLinks(data.description))
   throw new SourceError('refactor.copy.uri-context','A relative documentation link needs its original rendering context before cross-file extraction');
  if(at.kind==='schema'&&!inside(at.resourcePointer,target.pointer)){
   if(at.resourcePointer!==''||data&&typeof data==='object'&&['$anchor','$dynamicAnchor','$dynamicRef'].some(key=>Object.hasOwn(data,key)))
    throw new SourceError('refactor.copy.schema-resource','Extraction would move only part of an inherited schema resource or dynamic scope');
   if(g.graph.references.some(ref=>ref.keyword==='$dynamicRef'))
    throw new SourceError('refactor.copy.schema-resource','Anonymous-resource extraction cannot be proved by dynamic navigation candidates alone');
  }
 }
 const admit=editBudget(resources);admit(destinationId);admit(resource.id);
 let changed=fragment?replaceValue(destinationDoc,'',doc,target.pointer):insertValue(destinationDoc,destination,doc,target.pointer);
 // Relocation of an already authored $id retains its canonical identity. This
 // is a reviewed edit of that field, not an invented identifier/resource.
 if(cross)for(const at of selected.graph.scopes.values())if(at.kind==='schema'&&at.resource===resource.id&&inside(at.pointer,target.pointer)&&doc.nodes.has(at.pointer+'/$id')){
  admit(destinationId);changed=new SourceDocument(changed.set(move(resource.id,at.pointer)+'/$id',at.base),destinationId);
 }
 const occurrenceValue={$ref:fragment?destinationId:'#'+destination};
 const parent=doc.node(target.pointer.slice(0,target.pointer.lastIndexOf('/')));
 const occurrence=doc.format==='yaml'&&!parent.flow
  ?new SourceDocument(doc.emit(occurrenceValue),'occurrence.yaml')
  :new SourceDocument(JSON.stringify(occurrenceValue),'occurrence.json');
 const sourceAfter=replaceValue(cross?doc:changed,target.pointer,occurrence,'');
 const outputs=new Map<string,string>([[destinationId,changed.text],[resource.id,sourceAfter.text]]),repairs=new Map<string,string>(),usages=new Map<string,any>();
 const conversions=new Map<string,{resource:string,from:string,to:string}>();
 const keywordFor=(ref:any)=>conversions.has(movedResource(ref.resource,ref.pointer)+'#'+move(ref.resource,ref.pointer)+'/operationId')&&ref.keyword==='operationId'?'operationRef':ref.keyword;
 const currentResources=()=>resources.map(r=>outputs.has(r.id)?{...r,text:outputs.get(r.id)!}:r);
 const rebuilt=(g:typeof selected)=>{
  const current=currentResources(),ids=new Set<string>(g.context.resources);
  if(owning.includes(g))ids.add(destinationId);
  // Do not inject one entry description's entire resource set into unrelated
  // roots. Reuse canonical cold closure for genuinely new outgoing resources.
  for(const id of coldGraph(g.context.root,current).docs.keys())ids.add(id);
  return createGraph({root:g.context.root,resources:current.filter(r=>ids.has(r.id))});
 };
 for(const g of owning) {
  let after=rebuilt(g);
  const nextScope=after.graph.scopes.get(destinationId+'#'+destination),from=after.graph.scopes.get(resource.id+'#'+target.pointer);
  if(!nextScope||!from||nextScope.kind!==scope.kind)throw new SourceError('refactor.extract.destination','This component family is not supported in every owning root');
  if(cross)relocateCopiedUris(g.graph,after.graph,{resource:resource.id,pointer:target.pointer},{resource:destinationId,pointer:destination},outputs,repairs,admit);
  const address=referenceValue(after.graph,from,nextScope);
  if(!address)throw new SourceError('refactor.copy.address','The extracted definition has no unambiguous reference address');
  const addresses:[string,string,any,string?][]= [[resource.id,target.pointer+'/$ref',address]];
  for(const ref of g.graph.references) {
   const sourcePointer=move(ref.resource,ref.pointer),targetPointer=move(ref.targetResource!,ref.targetPointer!);
   if(sourcePointer===ref.pointer&&targetPointer===ref.targetPointer)continue;
   const retained=moving&&!(ref.resource===resource.id&&inside(ref.pointer,target.pointer))&&ref.targetResource===resource.id&&ref.targetPointer===target.pointer;
   if(retained){
    const key=ref.resource+'#'+ref.pointer+'/'+escape(ref.keyword),usage=usages.get(key)??{resource:ref.resource,pointer:ref.pointer+'/'+escape(ref.keyword),connection:ref.connection??ref.keyword,target:{resource:ref.targetResource,pointer:ref.targetPointer},roots:[],unchangedIdentity:true,bindingRetained:true};
    if(!usage.roots.includes(g.context.root))usage.roots.push(g.context.root);usages.set(key,usage);
    continue;
   }
   const targetResource=movedResource(ref.targetResource!,ref.targetPointer!),sourceResource=movedResource(ref.resource,ref.pointer);
   const to=after.graph.scopes.get(targetResource+'#'+targetPointer),at=after.graph.scopes.get(sourceResource+'#'+sourcePointer);
   if(!to||!at||ref.connection==='security'||ref.connection==='discriminator'&&ref.value.indexOf('/')<0&&ref.value.indexOf('#')<0)
    throw new SourceError('refactor.copy.implicit','An implicit connection needs an explicit ownership decision before extraction');
   const convert=ref.connection==='operationId'&&sourceResource!==ref.resource;
   if(convert&&g.docs.get(ref.resource)!.nodes.has(ref.pointer+'/operationRef'))throw new SourceError('edit.collision','The Link already authors both mutually exclusive target fields');
   const next=ref.connection==='operationId'&&!convert?ref.value:referenceValue(after.graph,at,to,convert?'operationRef':ref.keyword);
   if(next===undefined)throw new SourceError('refactor.copy.address','A required consumer cannot retain its proven target');
   const field=sourcePointer+'/'+escape(convert?'operationRef':ref.keyword),removed=convert?sourcePointer+'/operationId':undefined;
   addresses.push([sourceResource,field,next,removed]);
   if(removed)conversions.set(sourceResource+'#'+removed,{resource:sourceResource,from:removed,to:field});
   const key=ref.resource+'#'+ref.pointer+'/'+escape(ref.keyword),usage=usages.get(key)??{resource:ref.resource,pointer:ref.pointer+'/'+escape(ref.keyword),connection:ref.connection??ref.keyword,target:{resource:ref.targetResource,pointer:ref.targetPointer},roots:[]};
   if(!usage.roots.includes(g.context.root))usage.roots.push(g.context.root);usages.set(key,usage);
  }
  // A named allOf child retains its inherited discriminator wire name even
  // though its authored body now lives at another component key. Add only
  // the missing graph-proven mapping; never rewrite payloads by name.
  if(moving&&family==='schemas')for(const ref of g.graph.references){
   if(ref.resource!==resource.id||!ref.pointer.startsWith(target.pointer+'/allOf/')||ref.keyword!=='$ref')continue;
   const parentDoc=g.docs.get(ref.targetResource!)!,parent=parentDoc.node(ref.targetPointer!).value;
   const name=segments(target.pointer).at(-1)!;
   if(!parent?.discriminator||typeof parent.discriminator.propertyName!=='string'||Object.hasOwn(parent.discriminator.mapping??{},name))continue;
   const at=after.graph.scopes.get(ref.targetResource+'#'+ref.targetPointer);
   const value=at&&referenceValue(after.graph,at,from);
   if(value===undefined)throw new SourceError('refactor.copy.implicit','The inherited discriminator needs an unambiguous preserved component binding');
   const prefix=ref.targetPointer+'/discriminator/mapping';
   addresses.push([ref.targetResource!,parentDoc.nodes.has(prefix)?prefix+'/'+escape(name):prefix,parentDoc.nodes.has(prefix)?value:{[name]:value}]);
  }
  for(const [id,pointer,next,removed]of addresses){
   const key=id+'#'+pointer,previous=repairs.get(key);
   if(previous!==undefined&&previous!==JSON.stringify(next))throw new SourceError('refactor.context.ambiguous','One physical reference needs different repairs in configured roots');
   repairs.set(key,JSON.stringify(next));
   let current=new SourceDocument(outputs.get(id)??resources.find(r=>r.id===id)!.text,id);
   if(JSON.stringify(current.nodes.get(pointer)?.value)===JSON.stringify(next))continue;
   admit(id);
   if(removed&&current.nodes.has(removed)){
    const previous=current,parent=removed.slice(0,removed.lastIndexOf('/'));
    current=new SourceDocument(current.remove(removed),id);
    current=new SourceDocument(current.set(pointer,next),id);
    current=retainOccurrenceComments(previous,current,parent);
    outputs.set(id,current.text);continue;
   }
   outputs.set(id,current.set(pointer,next));
  }
 }
 const retainedBinding=(before:any,next:any,graph:any)=>{
  if(!moving||before.resource===resource.id&&inside(before.pointer,target.pointer)||before.targetResource!==resource.id||before.targetPointer!==target.pointer||
     next?.targetResource!==resource.id||next?.targetPointer!==target.pointer)return false;
  const bridge=graph.references.find((r:any)=>r.resource===resource.id&&r.pointer===target.pointer&&r.keyword==='$ref');
  return bridge?.resolution==='resolved'&&bridge.targetResource===destinationId&&bridge.targetPointer===destination;
 };
 for(const g of graphs){
  const after=rebuilt(g);
  if(after.graph.issues.length)throw new SourceError('refactor.proof','Extraction would introduce an unresolved or ambiguous connection');
  if(cross)for(const old of selected.graph.references)if(old.resource===resource.id&&inside(old.pointer,target.pointer)){
   const next=after.graph.references.find(ref=>ref.resource===destinationId&&ref.pointer===move(old.resource,old.pointer)&&ref.keyword===keywordFor(old));
   if(!next||next.resolution!=='resolved'||next.targetResource!==movedResource(old.targetResource!,old.targetPointer!)||next.targetPointer!==move(old.targetResource!,old.targetPointer!))
    throw new SourceError('refactor.context.ambiguous','The copied definition would bind a semantic consumer differently in another root');
  }
  for(const before of g.graph.scopes.values())if(before.kind==='schema'&&inside(before.pointer,target.pointer)&&before.resource===resource.id){
   const next=after.graph.scopes.get(movedResource(resource.id,before.pointer)+'#'+move(resource.id,before.pointer));
   const anonymousRelocation=cross&&before.resourcePointer==='';
   if(!next||!anonymousRelocation&&next.base!==before.base||next.dialect!==before.dialect||move(resource.id,before.resourcePointer)!==next.resourcePointer)
    throw new SourceError('refactor.copy.schema-resource','Extraction would change an inherited schema resource, base identity or dialect');
  }
  for(const ref of g.graph.references){
   const next=after.graph.references.find(r=>r.resource===movedResource(ref.resource,ref.pointer)&&r.pointer===move(ref.resource,ref.pointer)&&r.keyword===keywordFor(ref));
   if(!next||next.resolution!==ref.resolution||!retainedBinding(ref,next,after.graph)&&(next.targetResource!==movedResource(ref.targetResource!,ref.targetPointer!)||next.targetPointer!==move(ref.targetResource!,ref.targetPointer!))||movedResource(ref.resource,ref.pointer)===ref.resource&&next.base!==ref.base||
      JSON.stringify(next.dynamic?.candidates.map(t=>[t.resource,t.pointer]).sort())!==JSON.stringify(ref.dynamic?.candidates.map(t=>[movedResource(t.resource,t.pointer),move(t.resource,t.pointer)]).sort()))
    throw new SourceError('refactor.proof','An established consumer or dynamic navigation context would change meaning');
  }
  if(cross){
   const beforeCold=coldGraph(g.context.root,resources),afterCold=coldGraph(g.context.root,currentResources());
   const knownIssues=new Set(beforeCold.issues.map(issue=>JSON.stringify([issue.resource,issue.pointer,issue.code])));
   if(afterCold.issues.some(issue=>!knownIssues.has(JSON.stringify([issue.resource,issue.pointer,issue.code]))))
    throw new SourceError('refactor.copy.retrieval','The moved definition needs an explicit approved retrieval mapping before it can be reopened');
   for(const old of g.graph.references){
    const next=afterCold.references.find(ref=>ref.resource===movedResource(old.resource,old.pointer)&&ref.pointer===move(old.resource,old.pointer)&&ref.keyword===keywordFor(old));
    if(!next||next.resolution!=='resolved'||!retainedBinding(old,next,afterCold)&&(next.targetResource!==movedResource(old.targetResource!,old.targetPointer!)||next.targetPointer!==move(old.targetResource!,old.targetPointer!)))
     throw new SourceError('refactor.copy.retrieval','An established connection would be lost when reopening the relocated graph');
   }
  }
 }
 const edits=editsFor(resources,outputs);
 return {version:1,kind:moving?'component-move':'component-extract',...(moving?{preservedBinding:{resource:resource.id,pointer:target.pointer}}:{}),snapshot:input.snapshot,identity:createHash('sha256').update(JSON.stringify({snapshot:input.snapshot,target,name:input.name,moving,edits})).digest('hex'),edits,
  changes:[...outputs].map(([id,after])=>({resource:id,before:resources.find(r=>r.id===id)!.text,after})),usages:[...usages.values()],from:target,to:{...target,resource:destinationId,pointer:destination},
  transitions:[{resource:resource.id,from:target.pointer,to:destination,...(cross?{toResource:destinationId}:{})},...conversions.values()],checkedRoots:input.contexts.map((c:any)=>c.root)};
}

export const planExtract=(input:any)=>planCopy(input);

/** Compose the existing extraction and definition relocation proofs in one
 * immutable proposal. The temporary null is only a CST insertion slot, never
 * an authored API wrapper, published file, buffer or second document model. */
export function planExtractToFile(input:any) {
 const original=capture(input),id=input.destinationResource;
 if(typeof id!=='string'||original.resources.some(resource=>resource.id===id))throw new SourceError('edit.collision','Choose an unused approved source destination');
 let uri:URL;try{uri=new URL(id);}catch{throw new SourceError('refactor.extract.destination','Choose an absolute local source destination');}
 if(uri.protocol!=='file:'||uri.host||uri.hash||uri.search||!/\.(?:json|ya?ml)$/i.test(uri.pathname)||uri.pathname.endsWith('/busyapi.yaml'))
  throw new SourceError('refactor.extract.destination','Choose a local source file, not project configuration');
 if(original.doc.format!==(uri.pathname.toLowerCase().endsWith('.json')?'json':'yaml'))
  throw new SourceError('refactor.copy.format','Keep the selected source representation when creating its extracted file');
 const project=(resources:Resource[],edits:any[])=>resources.map(resource=>{
  let text=resource.text;
  for(const edit of edits.filter(edit=>edit.buffer===resource.id).sort((a,b)=>b.start-a.start)){
   if(edit.generation!==resource.generation||text.slice(edit.start,edit.end)!==edit.expected)throw new SourceError('edit.stale','An internal refactoring projection no longer matches its captured source');
   text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
  }
  return text===resource.text?resource:{...resource,text,identity:createHash('sha256').update(text).digest('hex')};
 });
 const extracted=planCopy({...input,destinationResource:original.selected.context.root}),intermediate=project(original.resources,extracted.edits);
 // Extraction can make the selected entry's public binding newly reachable
 // from a different configured root. Reuse the canonical cold closure over
 // already approved immutable resources before composing the second proof.
 const contexts=input.contexts.map((context:any)=>({...context,
  resources:[...new Set([...context.resources,...coldGraph(context.root,intermediate).docs.keys()])]}));
 const slot:Resource={id,text:'null',generation:0,identity:createHash('sha256').update('null').digest('hex')};
 const relocated=planCopy({...input,contexts,resources:[...intermediate,slot],destinationFragment:true,
  target:{root:input.target.root,resource:extracted.to.resource,pointer:extracted.to.pointer,generation:intermediate.find(resource=>resource.id===extracted.to.resource)!.generation}},true);
 const final=project([...intermediate,slot],relocated.edits),created=final.find(resource=>resource.id===id)!;
 const outputs=new Map(final.filter(resource=>resource.id!==id&&resource.text!==original.resources.find(before=>before.id===resource.id)!.text).map(resource=>[resource.id,resource.text]));
 const edits=editsFor(original.resources,outputs),binding={resource:extracted.to.resource,pointer:extracted.to.pointer};
 const conversions=extracted.transitions.slice(1).map(move=>move.resource===binding.resource&&inside(move.from,binding.pointer)
  ?{...move,resource:id,from:move.from.slice(binding.pointer.length),to:move.to.slice(binding.pointer.length)}:move);
 const data={version:1,kind:'component-extract-file',snapshot:input.snapshot,checkedRoots:input.contexts.map((context:any)=>context.root),
  edits,changes:[...outputs].map(([resource,after])=>({resource,before:original.resources.find(value=>value.id===resource)!.text,after})).concat([{resource:id,before:'',after:created.text,fileAction:'create'}] as any),
  creations:[{resource:id,text:created.text,identity:created.identity}],usages:extracted.usages,from:input.target,to:{resource:id,pointer:''},binding,
  transitions:[{resource:original.resource.id,from:input.target.pointer,to:'',toResource:id},...conversions,...relocated.transitions.slice(1)]};
 return {...data,identity:createHash('sha256').update(JSON.stringify(data)).digest('hex')};
}

/** Relocate exactly one physical Operation Object. Both standard and 3.2
 * additional method positions use the same captured graph/CST proof and core
 * multi-buffer review/history boundary as component refactoring. */
export function planOperationMove(input:any) {
 const {resources,target,resource,graphs,owning,selected,doc,node,scope}=capture(input);
 if(scope.kind!=='operation'||typeof input.method!=='string'||input.method.length>256||typeof input.additional!=='boolean')
  throw new SourceError('refactor.operation.context','Choose an authored Operation and an explicit method location');
 const fixed=standardOperationMethods(scope.family);
 if(input.additional){
  if(scope.family!=='3.2'||!/^[-!#$%&'*+.^_`|~0-9A-Za-z]+$/.test(input.method)||fixed.some(method=>method.toUpperCase()===input.method))
   throw new SourceError('edit.method','Choose an additional HTTP token not represented by a fixed operation field');
 }else if(!fixed.includes(input.method))throw new SourceError('edit.method','Choose a method in the authored OpenAPI family');
 let parent=target.pointer;
 while(parent){parent=parent.slice(0,parent.lastIndexOf('/'));if(selected.graph.scopes.get(resource.id+'#'+parent)?.kind==='path-item')break;}
 const sourcePath=selected.graph.scopes.get(resource.id+'#'+parent);
 if(!sourcePath||sourcePath.kind!=='path-item')throw new SourceError('refactor.operation.owner','This Operation has no established Path Item owner');
 let destinationParent=input.destinationPointer;
 if(input.path!==undefined){
  if(typeof input.path!=='string'||!input.path.startsWith('/')||input.path.length>16384||!target.pointer.startsWith('/paths/')||!selected.graph.specifications.has(doc.id))
   throw new SourceError('edit.path','Choose a real Paths destination in the authored document');
  destinationParent='/paths/'+escape(input.path);
 }
 if(typeof destinationParent!=='string'||destinationParent.length>16384)
  throw new SourceError('refactor.operation.destination','Choose a captured Path Item destination');
 const destinationPath=doc.nodes.get(destinationParent),destinationScope=selected.graph.scopes.get(resource.id+'#'+destinationParent);
 if(destinationPath&&destinationScope?.kind!=='path-item'||!destinationPath&&!(typeof input.path==='string'&&doc.nodes.get('/paths')?.kind==='object'))
  throw new SourceError('refactor.operation.destination','The destination is not an authored Path Item or an explicit new Paths entry');
 for(const pointer of [parent,...(destinationPath?[destinationParent]:[])]){
  const path=doc.node(pointer);doc.assertSafe(pointer);
  if(path.kind!=='object'||typeof path.value?.$ref==='string')throw new SourceError('edit.path.reference','Choose the actual Path Item definition before relocating one of its operations');
 }
 const destination=destinationParent+(input.additional?'/additionalOperations':'')+'/'+escape(input.method);
 const outputs=new Map<string,string>(),usages=new Map<string,any>(),admit=editBudget(resources);
 const baseResult={version:1,kind:'operation-move',snapshot:input.snapshot,from:target,to:{...target,pointer:destination},checkedRoots:input.contexts.map((context:any)=>context.root),context:input.context};
 if(destination===target.pointer)return {...baseResult,edits:[],changes:[],usages:[]};
 semanticOwner(owning,resource.id,target.pointer,node.range);
 if(doc.nodes.has(destination))throw new SourceError('edit.collision','The destination operation already exists');
 if(!['preserve','destination'].includes(input.context))throw new SourceError('edit.path.context','Choose whether effective declarations are preserved or destination inheritance is used');
 const oldEffective=new ParameterSemantics(selected.graph).operation(resource.id,target.pointer,sourcePath);
 const destinationParameters=new ParameterSemantics(selected.graph).list({resource:resource.id,pointer:destinationParent,kind:'path-item'},true);
 if(!oldEffective.complete||!oldEffective.valid||!destinationParameters.complete||!destinationParameters.valid)
  throw new SourceError('edit.path.parameters','Resolve the source and destination parameter declarations before relocation');
 const local=oldEffective.entries.filter(entry=>!entry.inherited),localIds=new Set(local.map(entry=>entry.identity));
 const effective=input.context==='preserve'?oldEffective.visible:[...local,...destinationParameters.entries.filter(entry=>!localIds.has(entry.identity))];
 if(input.path!==undefined){
  const names=[...input.path.matchAll(/\{([^}]+)\}/g)].map(match=>match[1]);
  if(scope.family==='3.2'&&new Set(names).size!==names.length||effective.some(entry=>entry.location==='path'&&(!names.includes(entry.name)||selected.docs.get(entry.definition!.resource)!.dataNode(entry.definition!.pointer)?.value?.required!==true))||names.some(name=>!effective.some(entry=>entry.location==='path'&&entry.name===name)))
   throw new SourceError('edit.path.template','Destination path templates and effective required Path parameters must agree');
 }
 let prepared=doc;
 const copiedParameters:{resource:string;pointer:string}[]=[],overrides:string[]=[];
 const serverViews=new Map<string,{document:SourceDocument;pointer:string;canonical:string;origin:string;defaulted:boolean}>();
 const servers=(g:typeof graphs[number],path:string,raw=false)=>{
  const pathDoc=g.docs.get(resource.id)!,entry=g.docs.get(g.context.root)!;
  const local=pathDoc.nodes.get(path+'/servers'),root=entry.nodes.get('/servers');
  const source=local?pathDoc:entry,pointer=local?path+'/servers':'/servers';
  const retrieval=g.graph.retrievals.get(source.id)!,defaulted=!local&&(!root||root.kind==='array'&&!root.children.size);
  const cacheKey=JSON.stringify([source.id,pointer,retrieval,defaulted,raw]);
  if(serverViews.has(cacheKey))return serverViews.get(cacheKey)!;
  let document=defaulted?new SourceDocument('{"servers":[{"url":"/"}]}',source.id):source;
  const array=document.node(pointer);
  if(array.kind!=='array')throw new SourceError('edit.path.servers','The effective Server declaration is not an array');
  for(const [index,server]of array.children){
   if(server.kind!=='object'||typeof server.value?.url!=='string')throw new SourceError('edit.path.servers','The effective Server declaration needs an authored URL');
   if(raw)continue;
   let url:string;
   try{url=serverTemplate(server.value.url,retrieval,server.value.variables);}catch{
    throw new SourceError('edit.path.servers','The Server template cannot retain one proved retrieval context after relocation');
   }
   const at=pointer+'/'+escape(index)+'/url';
   if(document.node(at).value!==url){admit(source.id);document=new SourceDocument(document.set(at,url),source.id);}
  }
  const result={document,pointer,canonical:(raw?retrieval+'\u0000':'')+value(document,pointer),origin:source.id,defaulted};
  serverViews.set(cacheKey,result);return result;
 };
 if(parent!==destinationParent&&input.context==='preserve'){
  const identities=new Set(effective.map(entry=>entry.identity));
  if(destinationParameters.entries.some(entry=>!identities.has(entry.identity)))throw new SourceError('edit.path.context','An operation override cannot remove an extra destination parameter');
  for(const entry of oldEffective.visible.filter(entry=>entry.inherited)){
   if(!prepared.nodes.has(target.pointer+'/parameters'))prepared=new SourceDocument(prepared.set(target.pointer+'/parameters',[]),resource.id);
   const at=target.pointer+'/parameters/'+prepared.node(target.pointer+'/parameters').children.size;
   admit(resource.id);prepared=insertValue(prepared,at,selected.docs.get(entry.source.resource)!,entry.source.pointer);
   copiedParameters.push(entry.source);
  }
  if(!node.children.has('servers')){
   const rawViews=owning.map(g=>({source:servers(g,parent,true),destination:servers(g,destinationParent,true)}));
   if(rawViews.some(view=>view.source.canonical!==view.destination.canonical)){
    const views=owning.map(g=>({source:servers(g,parent),destination:servers(g,destinationParent)}));
    if(views.some(view=>view.source.canonical!==view.destination.canonical)){
    if(new Set(views.map(view=>view.source.canonical)).size!==1)
     throw new SourceError('edit.path.servers','Configured entry descriptions have different inherited Server meanings; one local override cannot preserve all of them');
    const source=servers(selected,parent);
    // Keep original spellings when the declaration already belongs to this
    // physical retrieval context. A cross-document inherited declaration uses
    // only the proved URL-template rebase above, without normalizing payloads.
    const authored=source.origin===resource.id&&!source.defaulted?doc:source.document;
    admit(resource.id);prepared=insertValue(prepared,target.pointer+'/servers',authored,source.pointer);
    overrides.push('servers');
    }
   }
  }
 }
 // Insert through the existing exact-value CST copier before removing only
 // the selected occurrence. No path key, sibling Operation or payload changes.
 admit(resource.id);
 let moved=insertValue(prepared,destination,prepared,target.pointer);
 // A YAML value range starts after comments between its key and first child.
 // Retain those real CST comments beside the relocated occurrence; never
 // inspect comment-looking block scalar/example data or consume leading
 // comments outside the selected entry's removal range.
 moved=retainOccurrenceComments(prepared,moved,destination,target.pointer,true);
 moved=new SourceDocument(moved.remove(target.pointer),resource.id);
 outputs.set(resource.id,moved.text);
 const move=(id:string,pointer:string)=>id===resource.id&&inside(pointer,target.pointer)?destination+pointer.slice(target.pointer.length):pointer;
 const current=()=>resources.map(value=>({...value,text:outputs.get(value.id)??value.text}));
 const rebuild=(g:typeof graphs[number],seed=true)=>createGraph({root:g.context.root,resources:current().filter(value=>g.context.resources.includes(value.id)),
  ...(seed?{occurrences:[...g.graph.scopes.values()].map(at=>({...at,pointer:move(at.resource,at.pointer)}))}:{})});
 const repairs=new Map<string,string>();
 const referenceKey=(ref:any)=>JSON.stringify([ref.resource,ref.pointer,ref.keyword]);
 for(const g of graphs){
  const after=rebuild(g);
  const references=new Map(after.graph.references.map(ref=>[referenceKey(ref),ref]));
  for(const ref of g.graph.references){
   const from=after.graph.scopes.get(ref.resource+'#'+move(ref.resource,ref.pointer));
   const to=after.graph.scopes.get(ref.targetResource+'#'+move(ref.targetResource!,ref.targetPointer!));
   if(!from||!to)throw new SourceError('refactor.proof','A required operation connection has no derived occurrence');
   const implicit=ref.connection&&ref.connection!=='operationRef'&&!(ref.connection==='discriminator'&&(ref.value.includes('/')||ref.value.includes('#')));
   const existing=references.get(referenceKey({...ref,pointer:move(ref.resource,ref.pointer)}));
   const retained=existing?.resolution==='resolved'&&existing.targetResource===to.resource&&existing.targetPointer===to.pointer;
   const value=implicit?ref.value:retained?existing!.value:referenceValue(after.graph,from,to,ref.keyword==='$dynamicRef'&&!ref.dynamic?'$ref':ref.keyword);
   if(value===undefined)throw new SourceError('refactor.proof','A required operation connection has no unambiguous replacement address');
   const pointer=move(ref.resource,ref.pointer)+'/'+escape(ref.keyword),key=ref.resource+'#'+pointer;
   if(repairs.has(key)&&repairs.get(key)!==value)throw new SourceError('refactor.context.ambiguous','Configured roots require different repairs of one physical operation consumer');
   repairs.set(key,value);
   const enclosing=ref.targetResource===resource.id&&ref.targetPointer!==target.pointer&&inside(target.pointer,ref.targetPointer!);
   if(value===ref.value&&move(ref.targetResource!,ref.targetPointer!)===ref.targetPointer&&move(ref.resource,ref.pointer)===ref.pointer&&!enclosing)continue;
   const previous=usages.get(key);
   usages.set(key,{resource:ref.resource,pointer,connection:ref.connection??ref.keyword,target:{resource:ref.targetResource,pointer:ref.targetPointer},roots:[...new Set([...(previous?.roots??[]),g.context.root])],...(enclosing?{effect:'containing-definition-changes'}:{})});
   const document=new SourceDocument(outputs.get(ref.resource)??resources.find(value=>value.id===ref.resource)!.text,ref.resource);
   if(document.node(pointer).value!==value){admit(ref.resource);outputs.set(ref.resource,document.set(pointer,value));}
  }
 }
 for(const g of graphs){
  const after=rebuild(g,false);
  const references=new Map(after.graph.references.map(ref=>[referenceKey(ref),ref]));
  if(after.graph.issues.length)throw new SourceError('refactor.operation.proof','Relocation or inherited-context copying would introduce an invalid, unavailable or duplicate identity');
  for(const before of g.graph.scopes.values())if(before.kind==='schema'){
   const next=after.graph.scopes.get(before.resource+'#'+move(before.resource,before.pointer));
   if(!next||next.base!==before.base||next.dialect!==before.dialect||next.resourcePointer!==move(before.resource,before.resourcePointer)||next.family!==before.family)
    throw new SourceError('refactor.copy.schema-resource','Relocation would change a schema resource, dialect or authored feature family');
  }
  for(const ref of g.graph.references){
   const next=references.get(referenceKey({...ref,pointer:move(ref.resource,ref.pointer)}));
   if(!next||next.resolution!=='resolved'||next.base!==ref.base||next.targetResource!==ref.targetResource||next.targetPointer!==move(ref.targetResource!,ref.targetPointer!)||JSON.stringify(next.dynamic?.candidates.map(at=>[at.resource,at.pointer]).sort())!==JSON.stringify(ref.dynamic?.candidates.map(at=>[at.resource,move(at.resource,at.pointer)]).sort()))
    throw new SourceError('refactor.proof','An established consumer or dynamic context would change meaning');
  }
  const cold=coldGraph(g.context.root,current());
  const beforeCold=coldGraph(g.context.root,resources);
  if(cold.issues.length)throw new SourceError('refactor.copy.retrieval','An operation consumer could not reopen its derived target');
  const coldReferences=new Map(cold.references.map(ref=>[referenceKey(ref),ref]));
  const beforeColdReferences=new Set(beforeCold.references.map(referenceKey));
  for(const ref of g.graph.references){
   if(!beforeColdReferences.has(referenceKey(ref)))continue;
   const next=coldReferences.get(referenceKey({...ref,pointer:move(ref.resource,ref.pointer)}));
   if(!next||next.resolution!=='resolved'||next.targetResource!==ref.targetResource||next.targetPointer!==move(ref.targetResource!,ref.targetPointer!))
    throw new SourceError('refactor.copy.retrieval','An established operation consumer would disappear when reopening the project');
  }
 }
 const edits=editsFor(resources,outputs);
 return {...baseResult,identity:createHash('sha256').update(JSON.stringify([input.snapshot,target,destination,input.context,edits])).digest('hex'),edits,
  changes:[...outputs].map(([id,after])=>({resource:id,before:resources.find(value=>value.id===id)!.text,after})),usages:[...usages.values()],
  inheritedCopies:copiedParameters,overrides,transitions:[{resource:resource.id,from:target.pointer,to:destination}]};
}
/** Move the authored definition, deliberately retaining its public local name
 * as a Reference Object/schema applicator. This is not a filesystem move. */
export const planMoveDefinition=(input:any)=>planCopy(input,true);

/** Explicit, one-occurrence inlining. Definitions remain shared and unchanged.
 * Reference Object overrides, Path Item ambiguity, and Schema applicator
 * siblings are separate cases, never one universal object merge rule. */
export function planInline(input:any) {
 const {resources,target,resource,graphs,owning,selected,doc,node,scope}=capture(input);
 semanticOwner(owning,resource.id,target.pointer,node.range);
 const refs=owning.map(g=>g.graph.references.find(r=>same(r,scope)&&r.keyword==='$ref'));
 const ref=refs[0];
 if(!ref||ref.resolution!=='resolved'||refs.some(r=>!r||r.targetResource!==ref.targetResource||r.targetPointer!==ref.targetPointer))
  throw new SourceError('refactor.inline.target','Choose one unambiguous reference occurrence with the same target in every owning root');
 const definition=selected.docs.get(ref.targetResource!)!,definitionPointer=ref.targetPointer!,definitionNode=definition.node(definitionPointer);
 if(ref.targetResource===resource.id&&inside(target.pointer,definitionPointer))
  throw new SourceError('refactor.inline.recursive','The definition contains this occurrence; recursive graphs cannot be silently inlined');
 for(const g of owning){
  const active=new Set<string>(),visited=new Set<string>();let work=0,inspected=0;
  const visit=(id:string,pointer:string)=>{
   if(++work>20000)throw new SourceError('limit.refactor.inline','The reference impact graph exceeds its bounded review budget');
   const key=id+'#'+pointer;
   if(active.has(key))throw new SourceError('refactor.inline.recursive','The definition reaches a recursive graph; retain its shared definition instead of silently inlining it');
   if(visited.has(key))return;visited.add(key);active.add(key);
   for(const edge of g.graph.references){
    if(++inspected>200000)throw new SourceError('limit.refactor.inline','The reference impact graph exceeds its bounded review budget');
    if(edge.resource!==id||!inside(edge.pointer,pointer)||edge.connection||!intrinsic(g.graph,id,edge.pointer,pointer))continue;
    if(edge.keyword==='$dynamicRef')throw new SourceError('refactor.inline.schema-resource','A reachable dynamic reference needs its resource evaluation scope; it cannot be proved by static navigation');
    visit(edge.targetResource!,edge.targetPointer!);
   }
   active.delete(key);
  };
  visit(definition.id,definitionPointer);
 }
 if(definition.id!==resource.id){
  for(const g of owning)for(const at of g.graph.scopes.values())if(at.resource===definition.id&&inside(at.pointer,definitionPointer)&&intrinsic(g.graph,at.resource,at.pointer,definitionPointer)){
   // CommonMark links depend on a rendering context, not the graph's URI
   // fields. Their separate explicit-context decision remains required.
   if(typeof definition.node(at.pointer).value?.description==='string'&&hasRelativeMarkdownLinks(definition.node(at.pointer).value.description))
    throw new SourceError('refactor.inline.uri-context','A relative documentation link needs its original rendering context before cross-file inlining');
  }
 }
 // Duplicating an identified schema resource/anchor would create conflicting
 // identifiers; removing them would change meaning. Likewise, dynamic scope
 // cannot be proved merely by comparing possible navigation candidates.
 for(const g of owning)for(const at of g.graph.scopes.values())if(at.resource===definition.id&&inside(at.pointer,definitionPointer)&&at.kind==='schema'&&intrinsic(g.graph,at.resource,at.pointer,definitionPointer)){
  const value=definition.node(at.pointer).value;
  if(value&&typeof value==='object'&&['$id','$schema','$anchor','$dynamicAnchor','$dynamicRef'].some(key=>Object.hasOwn(value,key)))
   throw new SourceError('refactor.inline.schema-resource','This definition declares a schema resource, dialect, anchor or dynamic scope that cannot be duplicated by inlining');
 }
 const siblings=[...node.children.keys()].filter(key=>key!=='$ref');
 if(!['3.1','3.2'].includes(scope.family)&&scope.kind!=='path-item'&&siblings.length)
  throw new SourceError('refactor.inline.ignored','This specification ignores all Reference Object siblings; remove or relocate those authored values explicitly before inlining');
 if(scope.kind==='path-item'&&siblings.some(key=>definitionNode.children.has(key)))
  throw new SourceError('refactor.inline.pathItem','The Path Item reference has overlapping fields with undefined combined behavior');
 if(scope.kind!=='schema'&&scope.kind!=='path-item'&&siblings.some(key=>!['summary','description'].includes(key)))
  throw new SourceError('refactor.inline.ignored','Inlining would activate ignored Reference Object siblings; decide their ownership explicitly');
 if(scope.kind!=='schema'&&scope.kind!=='path-item'&&siblings.some(key=>!fieldsFor(scope.kind,scope.family,definitionNode.value).some(field=>field.name===key&&!field.prohibited)))
  throw new SourceError('refactor.inline.ignored','An inapplicable Reference Object override cannot become an authored inline field');
 if(scope.kind!=='schema'&&definitionNode.value?.$ref)
  throw new SourceError('refactor.inline.chain','Navigate to the final definition before explicitly inlining a reference chain');
 const admit=editBudget(resources);admit(resource.id);
 let changed:SourceDocument,destination=target.pointer;
 if(scope.kind==='schema'&&siblings.length){
  // Preserve local constraints in their authored position, not a map merge.
  changed=new SourceDocument(doc.remove(target.pointer+'/$ref'),doc.id);
  const existing=changed.nodes.get(target.pointer+'/allOf');
  if(existing&&(existing.kind!=='array'||existing.shared))throw new SourceError('refactor.inline.composition','Repair the authored allOf array ownership before adding this independent constraint');
  const index=existing?.children.size??0;
  changed=new SourceDocument(existing?changed.set(target.pointer+'/allOf/'+index,null):changed.set(target.pointer+'/allOf',[null]),doc.id);
  destination+='/allOf/'+index;changed=replaceValue(changed,destination,definition,definitionPointer);
 }else {
  changed=replaceValue(doc,target.pointer,definition,definitionPointer);
  for(const key of siblings){admit(resource.id);changed=changed.nodes.has(target.pointer+'/'+escape(key))
   ?replaceValue(changed,target.pointer+'/'+escape(key),doc,target.pointer+'/'+escape(key))
   :insertValue(changed,target.pointer+'/'+escape(key),doc,target.pointer+'/'+escape(key));
  }
 }
 changed=retainOccurrenceComments(doc,changed,target.pointer);
 const outputs=new Map<string,string>([[resource.id,changed.text]]),repairs=new Map<string,string>(),usages:any[]=[];
 const relocated=(pointer:string)=>destination+pointer.slice(definitionPointer.length);
 const rebuilt=(g:typeof selected)=>createGraph({root:g.context.root,resources:resources.filter(r=>g.context.resources.includes(r.id)).map(r=>outputs.has(r.id)?{...r,text:outputs.get(r.id)!}:r)});
 for(const g of owning){
  const after=rebuilt(g);
  if(definition.id!==resource.id){
   relocateCopiedUris(g.graph,after.graph,{resource:definition.id,pointer:definitionPointer},{resource:resource.id,pointer:destination},outputs,repairs,admit,true);
   changed=new SourceDocument(outputs.get(resource.id)!,resource.id);
  }
  for(const at of g.graph.scopes.values())if(at.resource===definition.id&&inside(at.pointer,definitionPointer)&&at.kind==='schema'&&intrinsic(g.graph,at.resource,at.pointer,definitionPointer)){
   const next=after.graph.scopes.get(resource.id+'#'+relocated(at.pointer));
   if(!next||next.dialect!==at.dialect)throw new SourceError('refactor.inline.dialect','The copied schema would inherit a different dialect');
  }
  for(const old of g.graph.references)if(old.resource===definition.id&&inside(old.pointer,definitionPointer)&&intrinsic(g.graph,old.resource,old.pointer,definitionPointer)){
   // The impact walk above rejects actual cycles. An acyclic internal target
   // remains the original shared definition, not a recursively expanded copy.
   // Its address and every copied occurrence are proved again below.
   const at=after.graph.scopes.get(resource.id+'#'+relocated(old.pointer)),to=after.graph.scopes.get(old.targetResource+'#'+old.targetPointer)??g.graph.scopes.get(old.targetResource+'#'+old.targetPointer);
   const next=old.connection?old.value:at&&to?referenceValue(after.graph,at,to,old.keyword):undefined;
   if(next===undefined)throw new SourceError('refactor.copy.address','An inlined consumer cannot retain its original target');
   const pointer=relocated(old.pointer)+'/'+escape(old.keyword),previous=repairs.get(pointer);
   if(previous!==undefined&&previous!==next)throw new SourceError('refactor.context.ambiguous','The copied occurrence needs different repairs in configured roots');
   repairs.set(pointer,next);
   if(changed.node(pointer).value!==next){admit(resource.id);changed=new SourceDocument(changed.set(pointer,next),resource.id);outputs.set(resource.id,changed.text);}
   usages.push({resource:old.resource,pointer:old.pointer+'/'+escape(old.keyword),connection:old.keyword,
    target:{resource:old.targetResource,pointer:old.targetPointer},roots:[g.context.root],effect:'retained-inline-target'});
  }
  usages.push({resource:resource.id,pointer:target.pointer+'/$ref',connection:'$ref',target:{resource:definition.id,pointer:definitionPointer},roots:[g.context.root]});
 }
 for(const g of graphs){
  const after=rebuilt(g);
  if(after.graph.issues.length)throw new SourceError('refactor.proof','Inlining would introduce an unresolved or ambiguous connection');
  for(const old of g.graph.references){
   if(old.resource===resource.id&&old.pointer===target.pointer&&old.keyword==='$ref')continue;
   if(owning.includes(g)&&old.resource===definition.id&&inside(old.pointer,definitionPointer)&&intrinsic(g.graph,old.resource,old.pointer,definitionPointer)){
    const copy=after.graph.references.find(r=>r.resource===resource.id&&r.pointer===relocated(old.pointer)&&r.keyword===old.keyword);
    if(!copy||copy.targetResource!==old.targetResource||copy.targetPointer!==old.targetPointer)
     throw new SourceError('refactor.proof','An inlined semantic consumer would change target in one configured root');
   }
   const next=after.graph.references.find(r=>same(r,old)&&r.keyword===old.keyword);
   // Removing the last incoming edge can make an unchanged fragment no
   // longer reachable in this root. It remains canonical source, not a
   // deleted definition. Its copied consumers were proved above, and no byte
   // of this now-orphaned resource is part of the plan.
   if(!next&&!outputs.has(old.resource)&&!after.graph.scopes.has(old.resource+'#'+old.pointer))continue;
   if(!next||next.resolution!==old.resolution||next.targetResource!==old.targetResource||next.targetPointer!==old.targetPointer)
    throw new SourceError('refactor.proof','Inlining would change an established consumer');
  }
 }
 const edits=editsFor(resources,outputs);
 return {version:1,kind:'reference-inline',snapshot:input.snapshot,identity:createHash('sha256').update(JSON.stringify({snapshot:input.snapshot,target,edits})).digest('hex'),edits,
  changes:[{resource:resource.id,before:resource.text,after:changed.text}],usages,from:target,to:{resource:definition.id,pointer:definitionPointer},transitions:[],checkedRoots:input.contexts.map((c:any)=>c.root)};
}
