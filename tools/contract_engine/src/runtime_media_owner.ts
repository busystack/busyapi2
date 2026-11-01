import {SourceError,type Range} from './document';
import type {ReferenceGraph} from './reference_graph';
import {isNativeFamily,type SpecificationFamily} from './specification';
import {responseAllowsContent} from './response_content';

export type RuntimeMediaTarget={resource:string;pointer:string};
export type CapturedRuntimeMedia={family:SpecificationFamily;source:RuntimeMediaTarget&{range:Range};schema?:RuntimeMediaTarget;itemSchema?:RuntimeMediaTarget;bodyAllowed?:boolean};

/** A missing Schema Object is not a missing media declaration. Retain its
 * canonical owner rather than borrowing the root's family or info.version. */
export function capturedRuntimeMedia(graph:ReferenceGraph) {
 const edges=new Map(graph.references.filter(edge=>edge.keyword==='$ref').map(edge=>[edge.resource+'#'+edge.pointer,edge]));
 return (target:RuntimeMediaTarget):CapturedRuntimeMedia=>{
  let {resource,pointer}=target;const seen=new Set<string>();
  for(let depth=0;depth<128;depth++){
   const key=resource+'#'+pointer,scope=graph.scopes.get(key),node=graph.docs.get(resource)?.dataNode(pointer);
   const fail=(message:string):never=>{throw new SourceError('runtime.media.owner',message,node?.range??[0,0],'unsupported',{resource,pointer,range:node?.range??[0,0]});};
   if(!scope||!['media','response'].includes(scope.kind)&&!(scope.family==='2.0'&&scope.kind==='parameter'))
    return fail('The runtime body has no captured native media owner');
   const family=scope.family;if(!isNativeFamily(family))return fail('The captured media declaration has no supported family');
   if(seen.has(key))fail('The captured media reference chain contains a cycle');seen.add(key);
   if(!node||node.value===null||typeof node.value!=='object'||Array.isArray(node.value))fail('The captured media declaration is unavailable');
   const edge=edges.get(key);
   if(edge&&edge.kind===scope.kind){
    if(edge.resolution!=='resolved')fail('The captured media reference is unresolved');
    resource=edge.targetResource!;pointer=edge.targetPointer!;continue;
   }
   if(family==='2.0'&&scope.kind==='parameter'&&node.value.in!=='body')fail('Only a captured Swagger body parameter owns an ordinary media body');
   if(family!=='2.0'&&scope.kind==='response'&&responseAllowsContent(family,node.value))fail('Choose a captured Media Type Object for this response content');
   return {family,source:{resource,pointer,range:node.range},
    ...(scope.kind==='response'?{bodyAllowed:responseAllowsContent(family,node.value)}:{}),
    ...(Object.hasOwn(node.value,'schema')?{schema:{resource,pointer:pointer+'/schema'}}:{}),
    ...(scope.family==='3.2'&&Object.hasOwn(node.value,'itemSchema')?{itemSchema:{resource,pointer:pointer+'/itemSchema'}}:{})};
  }
  throw new SourceError('limit.runtime.media.owner','The captured media chain exceeds 128 declarations',[0,0],'unsupported',{...target,range:[0,0]});
 };
}
