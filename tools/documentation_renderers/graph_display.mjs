// Presentation addresses for a renderer that understands document pointers but
// not JSON Schema resource identities. This is not a reference resolver or an
// OpenAPI bundle: every target comes from BusyAPI's existing located Reference
// projection. Never publish this view as the canonical/derived API document.
const escape = value => value.replaceAll('~','~0').replaceAll('/','~1');
const tokens = pointer => {
  if(typeof pointer!=='string'||pointer!==''&&!pointer.startsWith('/')||/~(?![01])/.test(pointer))throw Error('busyapi.documentation.pointer');
  return pointer===''?[]:pointer.slice(1).split('/').map(value=>value.replaceAll('~1','/').replaceAll('~0','~'));
};
function at(root, pointer) {
  let value=root;
  for(const name of tokens(pointer)) {
    if(value===null||typeof value!=='object'||!Object.hasOwn(value,name))throw Error('busyapi.documentation.target');
    value=value[name];
  }
  return value;
}
const fragment = pointer => '#'+encodeURI(pointer).replaceAll('#','%23').replaceAll('?','%3F');
const location = value => Object.freeze({...value,
  ...(Array.isArray(value.range)?{range:Object.freeze([...value.range])}:{}),
  ...(Array.isArray(value.occurrenceRange)?{occurrenceRange:Object.freeze([...value.occurrenceRange])}:{}),
});
const indices = new WeakMap();

// Follow only already-resolved occurrence coordinates. There is no URI lookup,
// parser, acquisition or inferred payload traversal in this presentation index.
function located(presentation,pointer,table) {
  tokens(pointer);
  const index=indices.get(presentation);
  if(!index)throw Error('busyapi.documentation.projection');
  const visited=new Set();
  for(let depth=0;depth<32;depth++) {
    if(visited.has(pointer))throw Error('busyapi.documentation.reference-cycle');
    visited.add(pointer);
    let parent=pointer,alias;
    while(true) {
      const candidate=index.aliases.get(parent);
      if(candidate&&candidate.kind!=='schema') {alias={...candidate,from:parent};break;}
      if(!parent)break;parent=parent.slice(0,parent.lastIndexOf('/'));
    }
    const own=index[table].get(pointer),field=tokens(pointer).at(-1);
    // Reference Object payload fields come from the definition, not ignored
    // siblings. Path Item local fields retain their distinct source behavior.
    if(own&&(!alias||alias.kind==='path-item'||['summary','description'].includes(field)))return {pointer,value:own};
    if(alias){pointer=alias.target+pointer.slice(alias.from.length);continue;}
    if(own)return {pointer,value:own};
    return undefined;
  }
  throw Error('busyapi.documentation.reference-depth');
}
export function presentationNode(presentation,pointer) {
  const found=located(presentation,pointer,'nodes');
  return found?Object.freeze({pointer:found.pointer,kind:found.value.kind,source:found.value.source,value:at(presentation.spec,found.pointer)}):undefined;
}
export function presentationValue(presentation,pointer,{followReference=true}={}) {
  tokens(pointer);
  const index=indices.get(presentation);
  if(!index)throw Error('busyapi.documentation.projection');
  return followReference?located(presentation,pointer,'fields')?.value:index.fields.get(pointer);
}
// A read-only page of already-typed projection fields. No payload traversal,
// object merging, schema evaluation or URI lookup is performed by consumers.
export function presentationSection(presentation,pointer,{followReference=false,occurrence}={}) {
  tokens(pointer);
  const index=indices.get(presentation);
  if(!index)throw Error('busyapi.documentation.projection');
  const own=index.sections.get(pointer);
  const found=followReference?located(presentation,pointer,'sections'):own?{pointer,value:own}:undefined;
  if(occurrence!==undefined) {
    tokens(occurrence);
    const context=found&&index.contexts.get(found.pointer)?.get(presentation.root+'#'+occurrence);
    if(!context)throw Error('busyapi.documentation.operation-context');
    return Object.freeze({pointer:found.pointer,...found.value,effective:context.effective,occurrence,navigationId:context.navigationId});
  }
  return found?Object.freeze({pointer:found.pointer,...found.value}):undefined;
}

// Original source locations never enter a renderer. This only verifies that
// an opaque owner action names an existing role/coordinate in its display.
export function hasPresentationCoordinate(presentation,pointer,role) {
  tokens(pointer);
  const index=indices.get(presentation);
  if(!index)throw Error('busyapi.documentation.projection');
  return index.coordinates.get(role)?.has(pointer)===true;
}

export function graphAddressedDisplay(text, projection, displayUri, {addresses='absolute-document'}={}) {
  // Redoc CE's skipBundle presentation API uses physical document pointers;
  // Swagger's resolver requires absolute display coordinates to avoid treating
  // those pointers as relative to an authored nested $id. Neither mode resolves
  // a target: both use exactly the canonical graph edge captured below.
  if(!['absolute-document','document-pointer'].includes(addresses))throw Error('busyapi.documentation.addresses');
  if(typeof text!=='string'||text.length>16*1024*1024||projection?.version!==1||projection.producer!=='busyapi-native-reference'||projection.producerVersion!=='1'||projection.complete!==true||typeof projection.root!=='string'||typeof projection.snapshot!=='string'||!Array.isArray(projection.sections)||projection.sections.length>40000)
    throw Error('busyapi.documentation.projection');
  // This is the native/export owner's page identity, not an authored URI to
  // resolve or fetch. Absolute display addresses prevent a retained nested
  // $id from changing a physical-document navigation coordinate.
  let page;
  try {page=new URL(displayUri);}catch{throw Error('busyapi.documentation.display-uri');}
  if(!['http:','https:','file:','busyapi-doc:'].includes(page.protocol)||page.hash||page.href!==displayUri||displayUri.length>16384)
    throw Error('busyapi.documentation.display-uri');
  const spec=JSON.parse(text);
  if(!(spec?.swagger==='2.0'||/^3\.[012]\./.test(spec?.openapi)))throw Error('busyapi.documentation.version');
  const edits=new Map(), origins=[],fields=new Map(),nodes=new Map(),sections=new Map(),aliases=new Map(),literals=new Set(),contexts=new Map();
  const coordinates=new Map(['node','field','reference'].map(role=>[role,new Set()]));
  const contextOccurrences=new Set(),navigationIds=new Set();
  let bytes=0,fieldCount=0,referenceCount=0,contextCount=0,effectiveCount=0;
  const retain=value=>{if(typeof value!=='string'||(bytes+=value.length*2)>64*1024*1024)throw Error('busyapi.documentation.value-limit');};
  const effective=values=>{
    if(!Array.isArray(values)||values.length>3)throw Error('busyapi.documentation.effective-limit');
    for(const field of values){
      if(!field||typeof field!=='object'||typeof field.name!=='string'||field.entries!==undefined&&!Array.isArray(field.entries)||field.default!==undefined&&!Array.isArray(field.default))throw Error('busyapi.documentation.effective-limit');
      retain(field.name);
      for(const entry of field.entries??[]){
        if(++effectiveCount>400000||!entry||typeof entry!=='object')throw Error('busyapi.documentation.effective-limit');
        for(const value of [entry.name,entry.location,entry.source?.pointer,entry.definition?.pointer])if(value!==undefined)retain(value);
      }
    }
    return Object.freeze(values.map(field=>Object.freeze({...field,
    ...(field.source?{source:location(field.source)}:{}),
    ...(field.entries?{entries:Object.freeze(field.entries.map(entry=>Object.freeze({...entry,source:location(entry.source),
      ...(entry.definition?{definition:location(entry.definition)}:{})})))}:{}),
    ...(field.default?{default:Object.freeze(field.default.map(value=>Object.freeze({...value})))}:{}),
  })));};
  for(const section of projection.sections) {
    if(section.source?.resource!==projection.root)throw Error('busyapi.documentation.resource-not-supplied');
    if(!Array.isArray(section.entries)||!Array.isArray(section.references)||(fieldCount+=section.entries.length)>200000||(referenceCount+=section.references.length)>20000)
      throw Error('busyapi.documentation.field-limit');
    if(nodes.has(section.source.pointer))throw Error('busyapi.documentation.ambiguous');
    at(spec,section.source.pointer);
    nodes.set(section.source.pointer,{kind:section.kind,source:location(section.source)});
    coordinates.get('node').add(section.source.pointer);
    for(const entry of section.entries)coordinates.get('field').add(entry.source.pointer);
    for(const reference of section.references)coordinates.get('reference').add(reference.source.pointer);
    const references=Object.freeze((section.references??[]).map(reference=>Object.freeze({keyword:reference.keyword,value:reference.value,source:location(reference.source),target:location(reference.target),
      ...(reference.dynamic?{dynamic:Object.freeze({anchor:reference.dynamic.anchor,candidates:Object.freeze(reference.dynamic.candidates.map(location))})}:{})})));
    const referenceFields=new Map(references.map(reference=>[reference.source.pointer,reference]));
    sections.set(section.source.pointer,Object.freeze({kind:section.kind,source:location(section.source),
      ...(typeof section.text==='string'?{text:section.text}:{}),
      entries:Object.freeze((section.entries??[]).map(entry=>Object.freeze({name:entry.name,kind:entry.kind,source:location(entry.source),
        ...(entry.target?{target:location(entry.target)}:{}),...(referenceFields.has(entry.source.pointer)?{reference:referenceFields.get(entry.source.pointer)}:{})}))),
      references,
      effective:effective(section.effective??[]),
    }));
    if(section.contexts!==undefined) {
      if(section.kind!=='operation'||!Array.isArray(section.contexts)||(contextCount+=section.contexts.length)>40000)throw Error('busyapi.documentation.operation-context');
      const values=new Map();
      for(const context of section.contexts) {
        if(typeof context.occurrence!=='string'||!context.occurrence.startsWith(projection.root+'#')||contextOccurrences.has(context.occurrence)||
            context.occurrence.length>projection.root.length+16385||typeof context.navigationId!=='string'||!/^[a-f0-9]{64}$/.test(context.navigationId)||navigationIds.has(context.navigationId)||
            context.pathItem?.resource!==projection.root||typeof context.path!=='string'||context.path.length>16384||typeof context.method!=='string'||context.method.length>256||!['operation','webhook','callback'].includes(context.role)||!Array.isArray(context.effective))
          throw Error('busyapi.documentation.operation-context');
        for(const value of [context.occurrence,context.navigationId,context.path,context.method,context.pathItem.pointer])retain(value);
        tokens(context.occurrence.slice(projection.root.length+1));
        contextOccurrences.add(context.occurrence);navigationIds.add(context.navigationId);
        values.set(context.occurrence,Object.freeze({...context,pathItem:location(context.pathItem),effective:effective(context.effective)}));
      }
      contexts.set(section.source.pointer,values);
    }
    for(const entry of section.entries??[])if(entry.kind==='data') {
      const data=at(spec,entry.source.pointer);
      if(data!==null&&typeof data==='object')literals.add(entry.source.pointer);
      const range=entry.source?.range;
      if(entry.source?.resource!==projection.root||!Array.isArray(range)||range.length!==2||!range.every(Number.isSafeInteger)||range[0]<0||range[1]<range[0]||range[1]>text.length)
        throw Error('busyapi.documentation.source-range');
      const raw=text.slice(...range);
      bytes+=raw.length*2;
      if(fields.size>=200000||bytes>64*1024*1024)throw Error('busyapi.documentation.value-limit');
      fields.set(entry.source.pointer,Object.freeze({source:location(entry.source),raw,
        text:entry.representation==='text'?entry.text:raw,representation:entry.representation,kind:section.kind,name:entry.name}));
    }
  }
  for(const section of projection.sections)for(const reference of section.references??[]) {
    if(origins.length>=20000)throw Error('busyapi.documentation.reference-limit');
    // A single supplied bundle is expected here. Identity never grants
    // retrieval permission and there is no filesystem/network fallback.
    if(reference.source?.resource!==projection.root||reference.target?.resource!==projection.root)
      throw Error('busyapi.documentation.resource-not-supplied');
    const sourceValue=at(spec,reference.source.pointer),sourceTokens=tokens(reference.source.pointer);
    // A security consumer is a property name whose value is a scopes/roles
    // array. It is not a string-valued $ref field and must never be replaced.
    const keyConnection=reference.connection==='security';
    if(typeof reference.value!=='string'||(keyConnection?sourceTokens.at(-1)!==reference.value||!Array.isArray(sourceValue):sourceValue!==reference.value))
      throw Error('busyapi.documentation.stale-reference');
    at(spec,reference.target.pointer);
    const keyword=tokens(reference.source.pointer).at(-1);
    if(keyword!==reference.keyword)throw Error('busyapi.documentation.reference-owner');
    // Dynamic evaluation is not statically rebound for a renderer. Preserve
    // its authored value and the projection's explicit navigation candidates.
    const uriReference=!reference.connection&&reference.keyword==='$ref'||reference.connection==='operationRef'||reference.connection==='discriminator';
    if(uriReference||reference.keyword==='$dynamicRef') {
      let parent=reference.source.pointer;
      while(parent) {
        if(literals.has(parent))throw Error('busyapi.documentation.dual-occurrence');
        parent=parent.slice(0,parent.lastIndexOf('/'));
      }
    }
    const address=uriReference?(addresses==='absolute-document'?displayUri:'')+fragment(reference.target.pointer):reference.value;
    const previous=edits.get(reference.source.pointer);
    if(previous!==undefined&&previous!==address)throw Error('busyapi.documentation.ambiguous');
    if(uriReference)edits.set(reference.source.pointer,address);
    if(!reference.connection&&reference.keyword==='$ref')aliases.set(reference.source.pointer.slice(0,reference.source.pointer.lastIndexOf('/')),{kind:section.kind,target:reference.target.pointer});
    origins.push(Object.freeze({source:location(reference.source),target:location(reference.target),authored:reference.value,display:address,
      ...(reference.connection?{connection:reference.connection}:{}),
      ...(reference.dynamic?{dynamic:Object.freeze({anchor:reference.dynamic.anchor,candidates:Object.freeze(reference.dynamic.candidates.map(location))})}:{}),kind:section.kind}));
  }
  // Verify every captured edge before touching even the disposable view.
  for(const [pointer,address]of edits) {
    const parts=tokens(pointer),name=parts.pop();
    if(name===undefined)throw Error('busyapi.documentation.reference-owner');
    at(spec,parts.length?'/'+parts.map(escape).join('/'):'')[name]=address;
  }
  const result=Object.freeze({spec,canonicalText:text,root:projection.root,snapshot:projection.snapshot,displayUri,addresses,referenceOrigins:Object.freeze(origins),
    representation:'graph-addressed-display-only'});
  indices.set(result,{fields,nodes,sections,aliases,coordinates,contexts});
  try {
    for(const [pointer,values]of contexts)for(const context of values.values()) {
      const source=context.occurrence.slice(projection.root.length+1),parts=tokens(source),owner=presentationSection(result,source,{followReference:true});
      if(!['paths','webhooks'].includes(parts[0])||parts.at(-1)!==context.method||
          context.role==='operation'&&parts[0]!=='paths'||context.role==='webhook'&&parts[0]!=='webhooks')throw Error('busyapi.documentation.operation-context');
      parts.splice(parts.at(-2)==='additionalOperations'?-2:-1);
      const pathItem=presentationSection(result,'/'+parts.map(escape).join('/'),{followReference:true});
      if(owner?.pointer!==pointer||owner.kind!=='operation'||sections.get(context.pathItem.pointer)?.kind!=='path-item'||pathItem?.pointer!==context.pathItem.pointer)throw Error('busyapi.documentation.operation-context');
    }
  }catch(error){indices.delete(result);throw error;}
  return result;
}
