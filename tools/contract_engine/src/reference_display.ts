// Bounded read-only renderer coordinates, NOT an OpenAPI bundle.
// No parser/resolver/model is introduced: exact values and typed coordinates
// come only from the existing canonical graph and native Reference projection.
import {createHash} from 'node:crypto';
import {createGraph} from './engine';
import {SourceDocument,SourceError} from './document';
import {referenceDocument} from './reference_projection';
const hash=value=>createHash('sha256').update(value).digest('hex');
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');

// A JSON string is immutable across Dart isolates. Keep the large located
// object in the bounded receiving worker instead of decoding it on one
// isolate, deep-copying it to another, and freezing it repeatedly on the UI.
// This is a wire envelope, never source/API object serialization.
export function referenceDisplayPacket(input:any) {
 return {version:1,producer:'busyapi-reference-display-packet',producerVersion:'1',encoding:'json',content:JSON.stringify(referenceDisplay(input))};
}

export function referenceDisplay(input:any) {
 const outputId=input.outputId;
 const {docs,graph}=createGraph(input),original=referenceDocument(input),root=docs.get(input.root);
 if(root.root.kind!=='object'||!graph.specifications.has(input.root)||typeof outputId!=='string'||!outputId.endsWith('.json'))throw new SourceError('documentation.display-input','Choose a supported OpenAPI root and independent JSON display identity');
 let uri:URL;try{uri=new URL(outputId);}catch{throw new SourceError('documentation.display-input','Choose an absolute HTTPS display identity');}
 if(uri.protocol!=='https:'||uri.href!==outputId||uri.hash||uri.search||uri.username||uri.password||graph.identities.has(outputId))
  throw new SourceError('documentation.display-input','Display coordinates must be independent of original resources');
 let name='x-busyapi-display-resources',suffix=0;
 while(root.root.children.has(name))name='x-busyapi-display-resources-'+hash(input.root)+'-'+(++suffix);
 const prefix=new Map([[input.root,'']]),values=[],copies=new Map<string,{resource:string;from:string;to:string}>();
 const raw=root.dataJson('');let cost=Buffer.byteLength(raw);
 const retain=(key,text)=>{
  cost+=Buffer.byteLength(key)+Buffer.byteLength(text)+4;
  if(cost>16*1024*1024)throw new SourceError('limit.documentation.display','The bounded renderer display exceeds 16 MiB');
  values.push(JSON.stringify(key)+':'+text);
 };
 for(const [id,doc] of [...docs].sort(([a],[b])=>a<b?-1:a>b?1:0))if(id!==input.root) {
  const key=hash(id);prefix.set(id,'/'+escape(name)+'/'+key);
  retain(key,doc.dataJson(''));
 }
 // The graph already owns literal-versus-semantic occurrence classification.
 // A reference into instance/extension data gets a distinct presentation copy;
 // never rewrite the literal occurrence to make the renderer resolve it.
 const literalScopes=new Map<string,{section:any;container:string}>();
 const sourceKey=(resource,pointer)=>JSON.stringify([resource,pointer]);
 for(const section of original.sections) {
  const {resource,pointer}=section.source,container=graph.literalContainer(resource,pointer);
  if(container!==undefined)literalScopes.set(sourceKey(resource,pointer),{section,container});
 }
 for(const {section,container} of literalScopes.values()) {
  const {resource,pointer}=section.source;let ancestor=pointer,owned=false;
  while(ancestor) {
   ancestor=ancestor.slice(0,ancestor.lastIndexOf('/'));
   if(literalScopes.get(sourceKey(resource,ancestor))?.container===container){owned=true;break;}
  }
  if(owned)continue;
  const key='s_'+hash(JSON.stringify([resource,pointer,section.kind]));
  retain(key,docs.get(resource).dataJson(pointer));
  copies.set(sourceKey(resource,pointer),{resource,from:pointer,to:'/'+escape(name)+'/'+key});
 }
 const text=values.length?raw.slice(0,-1)+(root.root.children.size?',':'')+JSON.stringify(name)+':{'+values.join(',')+'}}':raw;
 if(Buffer.byteLength(text)>16*1024*1024)throw new SourceError('limit.documentation.display','The bounded renderer display exceeds 16 MiB');
 // Index display ranges with the canonical source parser only. Do NOT resolve
 // or validate this presentation as a relocated API/schema resource: original
 // dialect/base meaning belongs to the immutable graph, not this coordinate map.
 const display=new SourceDocument(text,outputId);
 const placement=source=>{
  let at=source.pointer;
  while(true){const found=copies.get(sourceKey(source.resource,at));if(found)return found;if(!at)break;at=at.slice(0,at.lastIndexOf('/'));}
  return {resource:source.resource,from:'',to:prefix.get(source.resource)};
 };
 const locate=(source,owner=placement(source))=>{
  if(!prefix.has(source.resource))throw new SourceError('documentation.display-source','A renderer source is not in the approved snapshot');
  if(source.resource!==owner.resource||source.pointer!==owner.from&&!source.pointer.startsWith(owner.from+'/'))throw new SourceError('documentation.display-owner','A renderer field lost its captured occurrence owner');
  const pointer=owner.to+source.pointer.slice(owner.from.length),node=display.nodes.get(pointer);
  if(!node)throw new SourceError('documentation.display-pointer','A renderer coordinate lost its exact source value');
  return {resource:outputId,pointer,markdownBase:outputId,generation:0,range:node.range};
 };
 const provenance=[];
 const effective=fields=>fields.map(field=>({...field,...(field.source?{source:locate(field.source)}:{}),
  ...(field.entries?{entries:field.entries.map(entry=>({...entry,source:locate(entry.source),...(entry.definition?{definition:locate(entry.definition)}:{})}))}:{})}));
 const occurrence=value=>{
  if(typeof value!=='string'||!value.startsWith(input.root+'#'))throw new SourceError('documentation.display-context','An operation context lost its captured entry identity');
  return outputId+value.slice(input.root.length);
 };
 const sections=original.sections.map(section=>{
  const owner=placement(section.source),source=locate(section.source,owner);
  provenance.push({kind:section.kind,source:section.source,derived:{resource:outputId,pointer:source.pointer}});
  return {...section,source,base:outputId,retrieval:outputId,
   entries:section.entries.map(entry=>({...entry,source:entry.kind==='data'?locate(entry.source,owner):locate(entry.source),...('target' in entry?{target:locate(entry.target)}:{})})),
   references:section.references.map(reference=>{
    const source=locate(reference.source,owner);
    provenance.push({kind:'reference',source:reference.source,derived:{resource:outputId,pointer:source.pointer},
     ...(reference.connection?{connection:reference.connection}:{})});
    return {...reference,source,target:locate(reference.target),
     ...(reference.dynamic?{dynamic:{...reference.dynamic,candidates:reference.dynamic.candidates.map(value=>locate(value))}}:{})};
   }),
   usages:section.usages.map(usage=>({...usage,source:locate(usage.source)})),
   effective:effective(section.effective),
   ...(section.contexts?{contexts:section.contexts.map(context=>({...context,occurrence:occurrence(context.occurrence),pathItem:locate(context.pathItem),effective:effective(context.effective)}))}:{}),
  };
 });
 const identity=hash(text);
 const result={version:1,complete:true,producer:'busyapi-reference-display',producerVersion:'1',root:input.root,snapshot:input.snapshot,
  representation:'graph-addressed-display-only',output:{id:outputId,text,identity},original,
  projection:{...original,root:outputId,snapshot:identity,sections,displayOnly:true,coordinateSpace:'display-document'},provenance};
 if(Buffer.byteLength(JSON.stringify(result))>48*1024*1024)throw new SourceError('limit.documentation.display','The combined renderer coordinates exceed 48 MiB');
 return result;
}
