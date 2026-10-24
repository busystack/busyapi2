import {createHash} from 'node:crypto';
import {analyse,createGraph,Resource} from './engine';
import {escape,RawJsonValue,SourceDocument,SourceError} from './document';
import {documentUriBase,GraphScope,resolveUri} from './reference_graph';
import {documentUriFields} from './authoring';

const within=(pointer:string,parent:string)=>pointer===parent||pointer.startsWith(parent+'/');
const key=(resource:string,pointer:string)=>JSON.stringify([resource,pointer]);
const compare=(a:string,b:string)=>a<b?-1:a>b?1:0;
const fragment=(pointer:string)=>'#'+encodeURI(pointer).replaceAll('#','%23').replaceAll('?','%3F');
// Only construct a portable spelling; URI resolution remains the graph's.
// Do not parse placeholder ports as integers, normalize away a variable with
// a following '..', or choose a value/default for an unrestricted variable.
export function serverTemplate(value:string,retrieval:string,variables:any):string {
 if(!value.includes('{'))return resolveUri(value,retrieval).href;
 type Form='absolute'|'authority'|'root'|'path'|'query'|'fragment'|'empty';
 let work=0;
 const forms=new Set<Form>();
 const tokens:[string,boolean][]=[];let at=0;
 for(const match of value.matchAll(/\{([^{}]*)\}/gu)) {
  tokens.push([value.slice(at,match.index),false],[match[1],true]);at=match.index+match[0].length;
 }
 tokens.push([value.slice(at),false]);
 const classify=(index:number,prefix:string,selected=new Map<string,string>())=>{
  if(++work>1024)throw new SourceError('limit.bundle.server.templates','Server template classification exceeds its bounded enum combinations');
  while(index<tokens.length&&!tokens[index][1])prefix+=tokens[index++][0];
  if(/^[A-Za-z][A-Za-z0-9+.-]*:/u.test(prefix)) {forms.add('absolute');return;}
  if(prefix.startsWith('//')) {forms.add('authority');return;}
  if(prefix.startsWith('/')&&prefix.length>1) {forms.add('root');return;}
  if(prefix.startsWith('?')) {forms.add('query');return;}
  if(prefix.startsWith('#')) {forms.add('fragment');return;}
  if(index===tokens.length) {forms.add(prefix===''?'empty':prefix.startsWith('/')?'root':'path');return;}
  if(prefix.includes('/')&&prefix!=='/'||prefix.includes('?')||prefix.includes('#')||prefix!==''&&prefix!=='/'&&!/^[A-Za-z][A-Za-z0-9+.-]*$/u.test(prefix)) {forms.add('path');return;}
  const name=tokens[index][0],known=selected.get(name),values=known===undefined?variables?.[name]?.enum:[known];
  if(!Array.isArray(values)||!values.length||values.length>256||values.some(value=>typeof value!=='string'||value.length>4096))
   throw new SourceError('bundle.server.template-context','An initial unrestricted Server variable can change the URL reference form; its original retrieval context cannot be preserved by one relocated template');
  for(const choice of values) {
   // A repeated variable has one value, not an independent Cartesian choice.
   const next=new Map(selected);next.set(name,choice);
   // Enum strings are opaque substitution values, not recursively scanned as
   // further template syntax. Only the original authored tokens are visited.
   classify(index+1,prefix+choice,next);
  }
 };
 classify(0,'');
 if(forms.size!==1)throw new SourceError('bundle.server.template-context','Server variable enum values select different URL reference forms; one relocated template cannot preserve their original retrieval context');
 const form=[...forms][0],base=resolveUri('',retrieval);
 if(form==='absolute')return value;
 if(form==='authority')return base.protocol+value;
 if(form==='query') {base.hash='';base.search='';return base.href+value;}
 if(form==='fragment') {base.hash='';return base.href+value;}
 if(form==='empty')return base.href+value;
 if(form==='root')return resolveUri('/',retrieval).href.slice(0,-1)+value;
 return resolveUri('.',retrieval).href+value;
}
const groups:Record<string,string>={schema:'schemas',parameter:'parameters',header:'headers',response:'responses','request-body':'requestBodies',example:'examples',link:'links',callback:'callbacks','path-item':'pathItems',security:'securitySchemes',media:'mediaTypes'};
type Placement={resource:string;from:string;to:string;kind:string;schema?:boolean;entryContext?:boolean};

/** A bounded derived artifact, never an editable API model or a resolver.
 * All locations, bases, implicit connections and dynamic candidates originate
 * in the canonical graph. Values come from its source documents, not JS object
 * serialization. Schema resources are retained as compound-resource envelopes;
 * generic OAS definitions are imported into their actual component families.
 */
export function deriveBundle(input:any) {
 const {docs,graph,family}=createGraph(input),root=docs.get(input.root)!;
 if(typeof input.outputId!=='string'||!input.outputId.endsWith('.json'))throw new SourceError('bundle.destination','Choose an independent JSON output identity');
 const outputId=resolveUri(input.outputId,input.root).href;
 if(graph.identities.has(outputId))throw new SourceError('bundle.destination','The derived output cannot replace a source resource identity');
 if([...docs.values()].some(doc=>doc.issues.length))throw new SourceError('bundle.syntax','Repair ambiguous source syntax before bundling');
 if(graph.issues.length)throw new SourceError('bundle.graph','The approved reference graph must be complete and unambiguous before bundling');
 if(graph.references.length>20000)throw new SourceError('limit.bundle.references','Bundle exceeds 20000 semantic connections');
 const schemaScopes=[...graph.scopes.values()].filter(scope=>scope.kind==='schema');
 const placements:Placement[]=[],imports=new Map<string,Map<string,string>>(),patches=new Map<string,string>();
 const entryBase=graph.scope(input.root,'').base;
 const defaultServer=!root.root.children.has('servers')||Array.isArray(root.root.value.servers)&&root.root.value.servers.length===0;
 const needsEntryIdentity=graph.references.some(ref=>ref.kind==='schema'&&ref.targetResource===input.root&&ref.base!==entryBase&&graph.scope(input.root,ref.targetPointer!).resourcePointer==='');
 const retainEntryResource=family==='3.1'&&needsEntryIdentity;
 const addSelf=family==='3.2'&&typeof root.root.value.$self!=='string'&&needsEntryIdentity;
 if(family==='3.2'&&typeof root.root.value.$self==='string')patches.set(key(input.root,'/$self'),JSON.stringify(entryBase));
 // The derived entry has a new retrieval URI, not an invented $self in 3.1.
 // Authored schema identities remain the same even when their original $id
 // used a relative spelling under that entry's old retrieval identity.
 for(const scope of schemaScopes)if(typeof docs.get(scope.resource)!.dataNode(scope.pointer)?.value?.$id==='string')
  patches.set(key(scope.resource,scope.pointer+'/$id'),JSON.stringify(scope.base));
 const reserved=new Map<string,Set<string>>();
 for(const [group,entries]of Object.entries(root.root.value?.components??{}))reserved.set(group,new Set(Object.keys(entries??{})));
 const name=(group:string,identity:string)=>{
  const names=reserved.get(group)??new Set<string>(),hash=createHash('sha256').update(identity).digest('hex');
  let candidate='_busyapi_'+hash.slice(0,24),suffix=0;
  while(names.has(candidate))candidate='_busyapi_'+hash+'_'+(++suffix);
  names.add(candidate);reserved.set(group,names);return candidate;
 };
 const put=(group:string,name:string,raw:string)=>{const entries=imports.get(group)??new Map<string,string>();entries.set(name,raw);imports.set(group,entries);};
 const allSchemas=new Set(schemaScopes.map(scope=>key(scope.resource,scope.pointer)));
 // These are physical OAS Schema Objects / referenced schema fragments, not
 // nested schema resources (which stay inside their original authored parent).
 const roots=schemaScopes.filter(scope=>{
  let at=scope.pointer;
  while(at){at=at.slice(0,at.lastIndexOf('/'));if(allSchemas.has(key(scope.resource,at)))return false;}
  return true;
 });
 const topByResource=new Map<string,GraphScope[]>();
 for(const scope of roots){const values=topByResource.get(scope.resource)??[];values.push(scope);topByResource.set(scope.resource,values);}
 const schemaCopies:{scope:GraphScope;to:string;entryContext?:boolean}[]=[],envelopes:{resource:string;to:string;name:string;scopes:GraphScope[];dialect:string}[]=[];
 const dialectDeclarations=new Map<string,string>();
 for(const [resource,scopes]of [...topByResource].sort(([a],[b])=>compare(a,b))) {
  scopes.sort((a,b)=>compare(a.pointer,b.pointer));
  // Normally OAS-local schema roots stay OAS-local. A 3.1 entry reached from
  // another identified schema resource needs its original schema-resource
  // identity retained in a compound envelope instead of an unsupported $self.
  if(resource===input.root&&!retainEntryResource)continue;
  const doc=docs.get(resource)!;
  if(scopes.length===1&&scopes[0].pointer===''&&doc.root.kind==='object') {
   const component=name('schemas',key(resource,'')),to='/components/schemas/'+component;
   placements.push({resource,from:'',to,kind:'schema',schema:true});schemaCopies.push({scope:scopes[0],to});
   // A root-relative declaration used its retrieval identity before import.
   patches.set(key(resource,'/$id'),JSON.stringify(scopes[0].base));
  }else{
   const component=name('schemas','resource:'+resource),to='/components/schemas/'+component;
   // A containing OAS document may select a dialect at a schema root without
   // an authored $id. Such declarations cannot simply become nested $schema
   // keywords under $defs (2020-12 Core 8.1.1). If these roots agree, retain
   // the original resource/base and promote their shared declaration to the
   // compound resource root. Independently identified children retain their
   // own dialects. Never split one identity into guessed per-dialect resources.
   const inherited=scopes.filter(child=>typeof doc.dataNode(child.pointer)?.value?.$id!=='string');
   const dialects=new Set(inherited.map(child=>child.dialect));
   if(dialects.size>1)
    throw new SourceError('bundle.dialect.boundary','Schema roots sharing one retained resource identity select different dialects; a single compound resource cannot preserve those dialect boundaries. Explicitly select the resource-package format to retain the original documents and URI identities.');
   const dialect=inherited[0]?.dialect??graph.scope(resource,'').dialect;
   for(const child of inherited)if(typeof doc.dataNode(child.pointer)?.value?.$schema==='string')
    dialectDeclarations.set(key(resource,child.pointer+'/$schema'),to+'/$schema');
   envelopes.push({resource,to,name:component,scopes,dialect});
   for(const scope of scopes) {
    // $defs names need not obey Components naming, nevertheless use legal,
    // collision-resistant names; component names and pointer escaping remain
    // independent invariants. Preserve named component wire values when known.
    const tokens=scope.pointer.split('/'),original=tokens.length===4&&tokens[1]==='components'&&tokens[2]==='schemas'?tokens[3]:undefined;
    const leaf=original&&/^[A-Za-z0-9._-]+$/.test(original)?original:'d_'+createHash('sha256').update(scope.pointer).digest('hex');
    const derived=to+'/$defs/'+escape(leaf);
    placements.push({resource,from:scope.pointer,to:derived,kind:'schema',schema:true});schemaCopies.push({scope,to:derived});
   }
  }
 }
 // Select real reusable owners for non-schema targets. An operationRef can
 // import its actual containing Path Item, never invent a new public route.
 const requested=new Map<string,GraphScope>();
 for(const ref of graph.references) {
  if(ref.targetResource===input.root||ref.kind==='schema'||ref.connection==='discriminator')continue;
  let target=graph.scopes.get(ref.targetResource!+'#'+ref.targetPointer!)??graph.scope(ref.targetResource!,ref.targetPointer!);
  if(ref.kind==='operation') {
   let at=ref.targetPointer!;
   while(at){at=at.slice(0,at.lastIndexOf('/'));const parent=graph.scopes.get(ref.targetResource!+'#'+at);if(parent?.kind==='path-item'){target=parent;break;}}
   if(target.kind!=='path-item')throw new SourceError('bundle.operation.owner','An operation target has no established reusable Path Item owner');
  }
  if(!groups[target.kind]||(target.kind==='media'&&family!=='3.2'))throw new SourceError('bundle.object.context','This semantic target has no component family in the selected specification');
  if(target.family!==family)throw new SourceError('bundle.object.version','A referenced OpenAPI object belongs to another authored feature family; relocating it into the selected root would change its version context');
  requested.set(key(target.resource,target.pointer),target);
 }
 const owners=[...requested.values()].filter(scope=>{
  let at=scope.pointer;while(at){at=at.slice(0,at.lastIndexOf('/'));if(requested.has(key(scope.resource,at)))return false;}return true;
 });
 for(const scope of owners) {
  const group=groups[scope.kind],component=name(group,key(scope.resource,scope.pointer));
  placements.push({resource:scope.resource,from:scope.pointer,to:'/components/'+group+'/'+component,kind:scope.kind});
 }
 placements.sort((a,b)=>b.from.length-a.from.length||compare(a.resource,b.resource)||compare(a.to,b.to));
 const placementIndex=new Map(placements.map(p=>[key(p.resource,p.from),p]));
 const placementAt=(resource:string,pointer:string)=>{
  let at=pointer;while(true){const placement=placementIndex.get(key(resource,at));if(placement)return placement;if(!at)return;at=at.slice(0,at.lastIndexOf('/'));}
 };
 const locate=(resource:string,pointer:string):string=>{
  const placement=placementAt(resource,pointer);
  if(placement)return placement.to+pointer.slice(placement.from.length);
  if(resource===input.root)return pointer;
  throw new SourceError('bundle.provenance','A semantic location has no proved derived destination');
 };
 const rootSchemaMoves=new Map(placements.filter(p=>p.schema).map(p=>[key(p.resource,p.from),p]));
 const schemaAddresses=new Map<string,string>();
 const keyRepairs=new Map<string,string>();
 const literalContainers=new Map([...docs.keys()].map(resource=>[resource,graph.literalContainers(resource)]));
 const isLiteral=(resource:string,pointer:string)=>graph.literalContainer(resource,pointer)!==undefined;
 const literalBelow=(resource:string,pointer:string,from?:string)=>{
  let at=pointer;
  while(at!==from) {
   if(literalContainers.get(resource)?.has(at))return true;
   if(!at)return false;at=at.slice(0,at.lastIndexOf('/'));
  }
  return false;
 };
 // A referenced entry value may also be ordinary example/annotation data.
 // Preserve that data occurrence and give only its established schema meaning
 // a separate OAS-local destination. No invented $id or new resource boundary
 // is needed: both meanings retain the entry's existing schema base/dialect.
 const entryLiteralSchemas=schemaScopes.filter(scope=>scope.resource===input.root&&isLiteral(scope.resource,scope.pointer)&&(scope.resourcePointer===''||scope.resourcePointer===scope.pointer));
 const entryLiteralPointers=new Set(entryLiteralSchemas.map(scope=>scope.pointer));
 if(!retainEntryResource)for(const scope of entryLiteralSchemas) {
  let at=scope.pointer,covered=false;
  while(at){at=at.slice(0,at.lastIndexOf('/'));if(entryLiteralPointers.has(at)){covered=true;break;}}
  if(covered)continue;
  const to='/components/schemas/'+name('schemas','schema-occurrence:'+key(scope.resource,scope.pointer));
  const placement:Placement={resource:scope.resource,from:scope.pointer,to,kind:'schema',schema:true,entryContext:true};
  placements.push(placement);placementIndex.set(key(scope.resource,scope.pointer),placement);
  rootSchemaMoves.set(key(scope.resource,scope.pointer),placement);
  schemaCopies.push({scope,to,entryContext:true});
 }
 // A const/example/unknown payload can itself be an explicitly referenced
 // schema. Keep its original data bytes in the owning schema, and place only
 // its established semantic occurrence in the SAME retained resource's
 // $defs. This does not invent a resource/$id, resolver or validation model.
 // Nested literal positions need their own placement even when an enclosing
 // payload has already been copied as a schema occurrence.
 const literalCopies:{scope:GraphScope;to:string;holder:string}[]=[],literalNames=new Map<string,Set<string>>();
 for(const scope of schemaScopes.filter(scope=>isLiteral(scope.resource,scope.pointer)).sort((a,b)=>a.pointer.length-b.pointer.length||compare(a.resource,b.resource)||compare(a.pointer,b.pointer))) {
  const previous=placementAt(scope.resource,scope.pointer);
  if(!literalBelow(scope.resource,scope.pointer,previous?.from))continue;
  const parent=graph.scope(scope.resource,scope.pointer.slice(0,scope.pointer.lastIndexOf('/')));
  if(scope.resource===input.root&&parent.resourcePointer===''&&!retainEntryResource) {
   const to='/components/schemas/'+name('schemas','schema-occurrence:'+key(scope.resource,scope.pointer));
   const placement:Placement={resource:scope.resource,from:scope.pointer,to,kind:'schema',schema:true,entryContext:true};
   placements.push(placement);placementIndex.set(key(scope.resource,scope.pointer),placement);rootSchemaMoves.set(key(scope.resource,scope.pointer),placement);
   schemaCopies.push({scope,to,entryContext:true});continue;
  }
  const resourcePlacement=placementAt(scope.resource,parent.resourcePointer),envelope=envelopes.find(value=>value.resource===scope.resource);
  const holder=resourcePlacement?resourcePlacement.to+parent.resourcePointer.slice(resourcePlacement.from.length):envelope?.to??(scope.resource===input.root?parent.resourcePointer:undefined);
  if(!holder)throw new SourceError('bundle.data.placement','A literal schema occurrence has no proved retained resource boundary');
  let names=literalNames.get(holder);
  if(!names) {
   names=new Set(Object.keys(docs.get(scope.resource)!.dataNode(parent.resourcePointer)?.value?.$defs??{}));
   if(envelope?.to===holder)for(const child of envelope.scopes)names.add(locate(child.resource,child.pointer).slice(holder.length+'/$defs/'.length));
   literalNames.set(holder,names);
  }
  const hash=createHash('sha256').update(key(scope.resource,scope.pointer)).digest('hex');
  let leaf='_busyapi_literal_'+hash.slice(0,24),suffix=0;
  while(names.has(leaf))leaf='_busyapi_literal_'+hash+'_'+(++suffix);
  names.add(leaf);
  const to=holder+'/$defs/'+escape(leaf),placement:Placement={resource:scope.resource,from:scope.pointer,to,kind:'schema',schema:true};
  placements.push(placement);placementIndex.set(key(scope.resource,scope.pointer),placement);rootSchemaMoves.set(key(scope.resource,scope.pointer),placement);
  literalCopies.push({scope,to,holder});
 }
 // An explicitly referenced OAS object may also occur as extension/example
 // data. Use only its graph-established type and the existing Components
 // importer. The original literal occurrence is not changed into an object
 // definition merely because its keys resemble specification fields.
 for(const scope of [...graph.scopes.values()].filter(scope=>scope.kind!=='schema'&&groups[scope.kind]&&isLiteral(scope.resource,scope.pointer)).sort((a,b)=>a.pointer.length-b.pointer.length||compare(a.resource,b.resource)||compare(a.pointer,b.pointer))) {
  if(!literalBelow(scope.resource,scope.pointer,placementAt(scope.resource,scope.pointer)?.from))continue;
  if(scope.kind==='media'&&family!=='3.2')throw new SourceError('bundle.object.context','This semantic target has no component family in the selected specification');
  if(scope.family!==family)throw new SourceError('bundle.object.version','A referenced OpenAPI object belongs to another authored feature family');
  const to='/components/'+groups[scope.kind]+'/'+name(groups[scope.kind],'literal-occurrence:'+key(scope.resource,scope.pointer)),placement:Placement={resource:scope.resource,from:scope.pointer,to,kind:scope.kind};
  placements.push(placement);placementIndex.set(key(scope.resource,scope.pointer),placement);
 }
 // An external Example/annotation can supply a schema target as well as data.
 // Its top-level schema placement is already a distinct retained occurrence;
 // the ordinary literal copy stays unchanged in its imported OAS owner. This
 // does not authorize patches through an arbitrary literal ancestor of a
 // moved schema: that still needs a separately proved placement below.
 const separateLiteralOccurrence=(resource:string,pointer:string)=>{
  const placement=placementAt(resource,pointer);
  return !!placement&&isLiteral(resource,placement.from)&&!literalBelow(resource,pointer,placement.from);
 };
 // Only specification-defined URI fields use the original base. This never
 // searches extension/example data or fetches an externalValue. Schema $id
 // relationships themselves remain inside retained resource boundaries.
 // OAuth Flow endpoint URLs resolve against effective Server URLs, not the
 // document URI. Keep their authored relative spelling while retaining every
 // Server declaration's original retrieval context (OAS 3.1 §4.7 / 3.2 §4.5.2).
 for(const scope of graph.scopes.values()) {
  const node=docs.get(scope.resource)!.dataNode(scope.pointer)!;
  for(const field of scope.kind==='server'?[]:documentUriFields(scope.kind,node.value))if(typeof node.value?.[field]==='string')
   patches.set(key(scope.resource,scope.pointer+'/'+field),JSON.stringify(resolveUri(node.value[field],documentUriBase(graph,scope)).href));
  if(scope.kind==='server'&&typeof node.value?.url==='string') {
   patches.set(key(scope.resource,scope.pointer+'/url'),JSON.stringify(serverTemplate(node.value.url,documentUriBase(graph,scope),node.value.variables)));
  }
 }
 const render=(resource:string,pointer:string,copySchema=false)=>docs.get(resource)!.dataJson(pointer,(node,occurrence)=>{
  if(occurrence!==pointer&&literalContainers.get(resource)?.has(occurrence))return docs.get(resource)!.dataJson(occurrence);
  if(graph.scopes.get(resource+'#'+occurrence)?.kind==='security-requirement'&&[...node.children.keys()].some(name=>keyRepairs.has(key(resource,occurrence+'/'+escape(name)))))
   return '{'+[...node.children.keys()].map(name=>JSON.stringify(keyRepairs.get(key(resource,occurrence+'/'+escape(name)))??name)+':'+render(resource,occurrence+'/'+escape(name))).join(',')+'}';
  const move=rootSchemaMoves.get(key(resource,occurrence));
  if(move&&!(copySchema&&occurrence===pointer))return JSON.stringify({$ref:schemaAddresses.get(key(resource,occurrence))??fragment(move.to)});
  return patches.get(key(resource,occurrence));
 });
 const effectiveDialects=schemaCopies.filter(copy=>!copy.entryContext&&!docs.get(copy.scope.resource)!.dataNode(copy.scope.pointer)!.children.has('$schema')&&
  (copy.to.split('/').length===4||typeof docs.get(copy.scope.resource)!.dataNode(copy.scope.pointer)!.value?.$id==='string'));
 const effectiveDialectKeys=new Set(effectiveDialects.map(copy=>key(copy.scope.resource,copy.scope.pointer)));
 const assemble=()=>{
  imports.clear();
  for(const {scope,to,entryContext}of schemaCopies)if(to.split('/').length===4) {
   let raw=render(scope.resource,scope.pointer,true);
   if(!entryContext&&!docs.get(scope.resource)!.dataNode(scope.pointer)!.children.has('$id'))raw=new SourceDocument(raw,outputId).set('/$id',scope.base);
   // An imported standalone resource used its original containing document's
   // default, not the destination OpenAPI document's jsonSchemaDialect.
   if(!entryContext&&!docs.get(scope.resource)!.dataNode(scope.pointer)!.children.has('$schema'))raw=new SourceDocument(raw,outputId).set('/$schema',scope.dialect);
   put('schemas',to.split('/')[3],raw);
  }
  for(const envelope of envelopes) {
   const scope=graph.scope(envelope.resource,'');
   const definitions=envelope.scopes.map(child=>{
    const to=locate(child.resource,child.pointer),leaf=to.slice(envelope.to.length+'/$defs/'.length).replaceAll('~1','/').replaceAll('~0','~');
    let raw=render(child.resource,child.pointer,true);
    if(dialectDeclarations.has(key(child.resource,child.pointer+'/$schema')))
     raw=new SourceDocument(raw,outputId).remove('/$schema');
    else if(effectiveDialectKeys.has(key(child.resource,child.pointer)))
     raw=new SourceDocument(raw,outputId).set('/$schema',child.dialect);
    return JSON.stringify(leaf)+':'+raw;
   });
   put('schemas',envelope.name,'{"$id":'+JSON.stringify(scope.base)+',"$schema":'+JSON.stringify(envelope.dialect)+',"$defs":{'+definitions.join(',')+'}}');
  }
  for(const placement of placements)if(!placement.schema) {
   const parts=placement.to.split('/');put(parts[2],parts[3],render(placement.resource,placement.from));
  }
  let text=render(input.root,'');
  let doc=new SourceDocument(text,outputId);
  // The specification's absent/empty root Server default is relative '/'.
  // Materialize only this derived default so relocation cannot silently change
  // the API host (or the base of relative OAuth endpoints). Source stays absent.
  if(defaultServer) {
   text=doc.set('/servers',[{url:resolveUri('/',graph.retrievals.get(input.root)!).href}]);
   doc=new SourceDocument(text,outputId);
  }
  if(addSelf){text=doc.set('/$self',entryBase);doc=new SourceDocument(text,outputId);}
  if(imports.size) {
   const components=doc.nodes.get('/components'),groups:string[]=[],remaining=new Map(imports);
   const imported=(entries:Map<string,string>)=>[...entries].sort(([a],[b])=>compare(a,b)).map(([name,raw])=>JSON.stringify(name)+':'+raw);
   for(const [group,node]of components?.children??[]) {
    const extra=remaining.get(group);remaining.delete(group);
    if(!extra){groups.push(JSON.stringify(group)+':'+doc.dataJson(node.pointer));continue;}
    if(node.kind!=='object')throw new SourceError('bundle.components','A component family is not an object');
    const entries=[...node.children].map(([name,child])=>JSON.stringify(name)+':'+doc.dataJson(child.pointer));
    groups.push(JSON.stringify(group)+':{'+[...entries,...imported(extra)].join(',')+'}');
   }
   for(const [group,entries]of [...remaining].sort(([a],[b])=>compare(a,b)))groups.push(JSON.stringify(group)+':{'+imported(entries).join(',')+'}');
   text=doc.set('/components',new RawJsonValue('{'+groups.join(',')+'}'));
  }
  if(literalCopies.length) {
   // Augment each derived resource once, not one whole-output parse/edit per
   // copied literal. New child resource boundaries are rendered recursively
   // in their own bounded source fragment; references never expand a graph.
   const additions=new Map<string,typeof literalCopies>();
   for(const copy of literalCopies){const entries=additions.get(copy.holder)??[];entries.push(copy);additions.set(copy.holder,entries);}
   const emitted=new Set<string>();
   const augment=(source:SourceDocument,pointer:string,base:string):string=>source.dataJson(pointer,(node,occurrence)=>{
    const extra=additions.get(base+occurrence);
    if(!extra)return;
    if(node.kind!=='object')throw new SourceError('bundle.data.placement','A retained resource cannot hold the proved schema occurrences');
    const definitions=node.children.get('$defs');
    if(definitions&&definitions.kind!=='object')throw new SourceError('bundle.data.placement','The retained resource has no valid definition collection');
    const entries=[...definitions?.children??[]].map(([name,child])=>JSON.stringify(name)+':'+augment(source,child.pointer,base));
    for(const copy of extra) {
     if(emitted.has(copy.to))throw new SourceError('bundle.data.placement','A derived schema occurrence has duplicate placements');
     emitted.add(copy.to);
     const fragment=new SourceDocument(render(copy.scope.resource,copy.scope.pointer,true),outputId);
     entries.push(JSON.stringify(copy.to.slice(copy.holder.length+'/$defs/'.length).replaceAll('~1','/').replaceAll('~0','~'))+':'+augment(fragment,'',copy.to));
    }
    return '{'+[...node.children].filter(([name])=>name!=='$defs').map(([name,child])=>JSON.stringify(name)+':'+augment(source,child.pointer,base)).concat('"$defs":{'+entries.join(',')+'}').join(',')+'}';
   });
   text=augment(new SourceDocument(text,outputId),'','');
   if(emitted.size!==literalCopies.length)throw new SourceError('bundle.data.placement','A derived schema occurrence lost its retained owner');
  }
  return text+'\n';
 };
 let text=assemble();
 // Scaffolding may contain old references. Its identity/scope index is used
 // only to construct proven destinations; it is never accepted as output.
 const layout=createGraph({root:outputId,resources:[{id:outputId,text,generation:0,identity:'layout'}]});
 const targetAddress=(resource:string,pointer:string,schema:boolean)=>{
  const to=locate(resource,pointer);
  if(!schema)return fragment(to);
  const scope=layout.graph.scope(outputId,to);
  if(scope.kind!=='schema')throw new SourceError('bundle.schema.context','The derived schema target lost its schema-bearing context');
  return scope.base+fragment(to.slice(scope.resourcePointer.length));
 };
 for(const move of rootSchemaMoves.values())schemaAddresses.set(key(move.resource,move.from),targetAddress(move.resource,move.from,true));
 for(const ref of graph.references) {
  if(ref.connection==='operationId')continue;
  if(ref.connection==='security') {
   if(ref.targetResource!==input.root||ref.value.includes('/')||ref.value.includes('#'))keyRepairs.set(key(ref.resource,ref.pointer+'/'+escape(ref.keyword)),targetAddress(ref.targetResource!,ref.targetPointer!,false));
   continue;
  }
  if(ref.connection==='discriminator'&&!ref.value.includes('/')&&!ref.value.includes('#')&&root.nodes.has('/components/schemas/'+escape(ref.value)))continue;
  const schema=ref.kind==='schema'&&!ref.connection||ref.connection==='discriminator';
  let next=targetAddress(ref.targetResource!,ref.targetPointer!,!!schema);
  // A dynamic anchor remains a dynamic anchor, not a statically substituted
  // pointer. Retain the resolved resource id and the actual anchor fragment.
  const originalUri=resolveUri(ref.value,ref.base);
  if(schema&&originalUri.hash&&!decodeURIComponent(originalUri.hash.slice(1)).startsWith('/')) {
   const to=locate(ref.targetResource!,ref.targetPointer!),scope=layout.graph.scope(outputId,to);
   next=scope.base+originalUri.hash;
  }
  if(schema) {
   const sourceScope=layout.graph.scope(outputId,locate(ref.resource,ref.pointer)),targetScope=layout.graph.scope(outputId,locate(ref.targetResource!,ref.targetPointer!));
   if(sourceScope.base===targetScope.base)next=next.slice(next.indexOf('#'));
   else if(family==='3.1'&&ref.targetResource===input.root&&targetScope.resourcePointer==='')
    throw new SourceError('bundle.entry.identity','A schema in a distinct identified resource refers back to the 3.1 entry resource; a stable portable entry identity is required');
  }
  patches.set(key(ref.resource,ref.pointer+'/'+escape(ref.keyword)),JSON.stringify(next));
 }
 for(const [id,replacement]of patches) {
  const [resource,pointer]=JSON.parse(id),node=docs.get(resource)!.nodes.get(pointer);
  if(node&&isLiteral(resource,pointer)&&!separateLiteralOccurrence(resource,pointer)&&JSON.stringify(node.value)!==replacement)
   throw new SourceError('bundle.data.identity','A schema transformation would change a literal example, annotation or extension payload');
 }
 text=assemble();
 let resource:Resource={id:outputId,text,generation:0,identity:createHash('sha256').update(text).digest('hex')};
 let after=createGraph({root:outputId,resources:[resource]}).graph;
 if(after.issues.length)throw new SourceError('bundle.proof','The derived graph has an unresolved, ambiguous or unsupported connection');
 // oasdiff refuses an absolute-looking reference even when its identified
 // schema resource is embedded in the same compound document. For its narrow
 // input adapter only, use a local JSON Pointer when the referencing scope is
 // the derived entry resource and the graph proves the same embedded target.
 // References from another identified resource, anchors and dynamic scope are
 // retained and remain explicit unsupported coverage rather than flattened.
 if(input.consumer==='oasdiff') {
  const entryBase=after.scope(outputId,'').base,source=new SourceDocument(text,outputId),edits:{range:[number,number];text:string}[]=[];
  for(const ref of after.references) {
   if(ref.keyword!=='$ref'||ref.kind!=='schema'||ref.dynamic||ref.resolution!=='resolved'||ref.targetResource!==outputId||!ref.targetPointer?.startsWith('/components/schemas/'))continue;
   if(after.scope(outputId,ref.pointer).base!==entryBase)continue;
   const node=source.nodes.get(ref.pointer+'/'+escape(ref.keyword));
   if(!node||typeof node.value!=='string')throw new SourceError('bundle.oasdiff.reference','A proved semantic reference lost its exact source location');
   edits.push({range:node.range,text:JSON.stringify(fragment(ref.targetPointer))});
  }
  for(const edit of edits.sort((a,b)=>b.range[0]-a.range[0]))text=text.slice(0,edit.range[0])+edit.text+text.slice(edit.range[1]);
  resource={id:outputId,text,generation:0,identity:createHash('sha256').update(text).digest('hex')};
  after=createGraph({root:outputId,resources:[resource]}).graph;
  if(after.issues.length)throw new SourceError('bundle.oasdiff.reference','The oasdiff-local reference spelling did not retain a complete graph');
 }
 const afterRefs=new Map(after.references.map(ref=>[key(ref.pointer,ref.keyword),ref]));
 const dereference=(pointer:string)=>{
  const seen=new Set<string>();
  while(!seen.has(pointer)) {
   seen.add(pointer);
   const ref=afterRefs.get(key(pointer,'$ref'));
   // Only the synthetic occurrence -> moved-definition edge is transparent.
   const moved=[...rootSchemaMoves.values()].some(p=>p.to===ref?.targetPointer&&pointer!==p.to);
   if(!ref||!moved||ref.targetPointer===pointer)break;pointer=ref.targetPointer!;
  }
  return pointer;
 };
 for(const scope of schemaScopes) {
  const next=after.scopes.get(outputId+'#'+locate(scope.resource,scope.pointer));
  const derivedEntryBase=after.scope(outputId,'').base;
  const placement=placementAt(scope.resource,scope.pointer);
  const expectedBase=scope.resource===input.root&&scope.resourcePointer===''&&(!placement?.schema||placement.entryContext)?derivedEntryBase:scope.base;
  if(!next||next.base!==expectedBase||next.dialect!==scope.dialect)
   throw new SourceError('bundle.proof.scope','A schema resource base or dialect would change');
 }
 for(const ref of graph.references) {
  const pointer=locate(ref.resource,ref.pointer),keyword=keyRepairs.get(key(ref.resource,ref.pointer+'/'+escape(ref.keyword)))??ref.keyword,next=afterRefs.get(key(pointer,keyword));
  if(!next||dereference(next.targetPointer!)!==dereference(locate(ref.targetResource!,ref.targetPointer!)))throw new SourceError('bundle.proof.target','An authored semantic connection would change its target');
  const expected=ref.dynamic?.candidates.map(t=>locate(t.resource,t.pointer)).sort(),actual=next.dynamic?.candidates.map(t=>t.pointer).sort();
  if(JSON.stringify(expected)!==JSON.stringify(actual))throw new SourceError('bundle.proof.dynamic','Dynamic navigation scope changed during bundling');
 }
 const generatedOccurrences=[...rootSchemaMoves.values()].flatMap(move=>[
  ...(move.resource===input.root&&!isLiteral(move.resource,move.from)?[{source:{resource:move.resource,pointer:move.from},derived:{resource:outputId,pointer:move.from},kind:'schema-reference-occurrence'}]:[]),
  ...placements.filter(owner=>!owner.schema&&owner.resource===move.resource&&within(move.from,owner.from)&&!isLiteral(move.resource,move.from))
    .map(owner=>({source:{resource:move.resource,pointer:move.from},derived:{resource:outputId,pointer:owner.to+move.from.slice(owner.from.length)},kind:'schema-reference-occurrence'})),
 ]);
 for(const occurrence of generatedOccurrences) {
  const move=rootSchemaMoves.get(key(occurrence.source.resource,occurrence.source.pointer))!;
  if(afterRefs.get(key(occurrence.derived.pointer,'$ref'))?.targetPointer!==move.to)
    throw new SourceError('bundle.proof.occurrence','A generated occurrence does not reach its proved schema definition');
 }
 const checked=analyse({root:outputId,snapshot:input.snapshot,resources:[resource]});
 if(checked.findings.some((f:any)=>f.severity==='error')||!checked.complete)throw new SourceError('bundle.validity','The derived output did not pass structural and semantic checks');
 const provenancePointer=(resource:string,pointer:string)=>{
  // The scopes underneath a renamed Security Requirement key move with it;
  // their physical value/array locations must not retain the old URI spelling.
  let at=pointer;
  while(at) {
   const repaired=keyRepairs.get(key(resource,at));
   if(repaired!==undefined)return locate(resource,at.slice(0,at.lastIndexOf('/')))+'/'+escape(repaired)+pointer.slice(at.length);
   at=at.slice(0,at.lastIndexOf('/'));
  }
  return locate(resource,pointer);
 };
 const provenance=[...[...graph.scopes.values()].filter(scope=>scope.resource===input.root||placementAt(scope.resource,scope.pointer))
  .map(scope=>{
   const doc=docs.get(scope.resource)!,physical=doc.dataNode(scope.pointer)!;
   let occurrence=scope.pointer;while(occurrence&&!doc.nodes.has(occurrence))occurrence=occurrence.slice(0,occurrence.lastIndexOf('/'));
   return {source:{resource:scope.resource,pointer:scope.pointer,
    ...(physical.pointer!==scope.pointer?{physicalPointer:physical.pointer,range:physical.range,occurrenceRange:doc.nodes.get(occurrence)!.range}:{})},
    derived:{resource:outputId,pointer:provenancePointer(scope.resource,scope.pointer)},kind:scope.kind,base:scope.base,dialect:scope.dialect};
  }),...graph.references.map(ref=>({
   // A transformed connection can change its field name (a 3.2 security URI
   // key). Retain the proved field mapping,
   // not a suffix guessed later by a renderer or the native source navigator.
   source:{resource:ref.resource,pointer:ref.pointer+'/'+escape(ref.keyword)},
   derived:{resource:outputId,pointer:locate(ref.resource,ref.pointer)+'/'+escape(keyRepairs.get(key(ref.resource,ref.pointer+'/'+escape(ref.keyword)))??ref.keyword)},
   kind:'reference',...(ref.connection?{connection:ref.connection}:{}),
  })),...effectiveDialects.map(copy=>({
   source:{resource:copy.scope.resource,pointer:copy.scope.pointer},derived:{resource:outputId,pointer:copy.to+'/$schema'},kind:'effective-schema-dialect',
  })),...[...dialectDeclarations].map(([source,pointer])=>{
   const [resource,from]=JSON.parse(source);
   return {source:{resource,pointer:from},derived:{resource:outputId,pointer},kind:'schema-dialect-declaration'};
  }),...generatedOccurrences,...placements.filter(move=>isLiteral(move.resource,move.from)).flatMap(move=>[
   ...(move.resource===input.root?[{source:{resource:move.resource,pointer:move.from},derived:{resource:outputId,pointer:move.from},kind:'literal-data-occurrence'}]:[]),
   ...placements.filter(owner=>owner!==move&&owner.resource===move.resource&&within(move.from,owner.from))
    .map(owner=>({source:{resource:move.resource,pointer:move.from},derived:{resource:outputId,pointer:owner.to+move.from.slice(owner.from.length)},kind:'literal-data-occurrence'})),
  ]),
  ...(defaultServer?[{source:{resource:input.root,pointer:root.root.children.has('servers')?'/servers':''},derived:{resource:outputId,pointer:'/servers/0'},kind:'effective-server-default'}]:[])]
  .sort((a,b)=>compare(a.source.resource,b.source.resource)||compare(a.source.pointer,b.source.pointer)||compare(a.kind,b.kind));
 return {version:1,complete:true,producer:'busyapi-graph-bundle',producerVersion:'3',snapshot:input.snapshot,root:input.root,
  output:{id:outputId,text,identity:resource.identity,format:'json'},provenance,sourceResources:(input.resources as Resource[]).map(r=>({id:r.id,identity:r.identity,generation:r.generation})).sort((a,b)=>compare(a.id,b.id)),
  identitiesRetained:[...new Set(schemaScopes.filter(scope=>scope.resource!==input.root||scope.resourcePointer!==''||placementAt(scope.resource,scope.pointer)?.schema||after.scope(outputId,'').base===entryBase).map(scope=>scope.base))].sort(),
  entryIdentity:{source:entryBase,derived:after.scope(outputId,'').base,declaredSelf:typeof root.root.value.$self==='string',derivedSelf:addSelf}};
}
