import {createGraph} from './engine';
import {SourceError} from './document';

/** No transformation/resolution: expose the existing graph's preserved URI
 * bindings for an exact-byte resource package. The Dart core owns all IO. */
export function describeResourcePackage(input:any) {
 const {docs,graph}=createGraph(input);
 if([...docs.values()].some(doc=>doc.issues.length)||graph.issues.length)
  throw new SourceError('bundle.graph','A resource package requires unambiguous syntax and a complete approved graph');
 const bindings=[...[...graph.identities].map(([uri,targets])=>({uri,targets,kind:'resource'})),
  ...[...graph.anchors].map(([uri,targets])=>({uri,targets,kind:'anchor'}))];
 const identities=bindings.sort((a,b)=>a.uri<b.uri?-1:a.uri>b.uri?1:0).map(({uri,targets,kind})=>{
  if(targets.length!==1)throw new SourceError('bundle.graph','A resource identity has ambiguous ownership');
  const target=targets[0],doc=docs.get(target.resource)!,node=doc.dataNode(target.pointer)!;
  let occurrence=target.pointer;while(occurrence&&!doc.nodes.has(occurrence))occurrence=occurrence.slice(0,occurrence.lastIndexOf('/'));
  return {uri,kind,resource:target.resource,pointer:target.pointer,range:node.range,
   ...(node.pointer!==target.pointer?{physicalPointer:node.pointer,occurrenceRange:doc.nodes.get(occurrence)!.range}:{})};
 });
 if(identities.length>20000||graph.references.length>20000)
  throw new SourceError('limit.bundle.references','Resource-package provenance exceeds its bounded graph budget');
 return {version:1,root:input.root,snapshot:input.snapshot,identities};
}
