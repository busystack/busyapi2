import {escape,segments,SourceError} from './document';
import type {GraphIssue,GraphScope,ReferenceGraph} from './reference_graph';
import {mediaTypes} from './media_types';
import {isNativeFamily} from './specification';

/** Only canonical media declarations are interpreted. Named reusable Media
 * Types, Schema keywords and instance/extension data are different positions.
 * OAS 3.0 §§4.7.12–17/21; OAS 2.0 §§5.2,6.4.1,6.4.7. */
export function mediaTypeIssues(graph:ReferenceGraph):GraphIssue[] {
 const issues:GraphIssue[]=[];
 const check=(scope:GraphScope,pointer:string,value:string,ranges:boolean)=>{
  try{
   if(mediaTypes(value,ranges).length!==1)
    throw new SourceError('media.type.single','This declaration requires one media type, not a comma-separated list');
  }catch(error){
   if(!(error instanceof SourceError))throw error;
   const incomplete=error.kind==='unsupported'||error.code.startsWith('limit.');
   issues.push({...scope,pointer,code:error.code,message:error.message,...(incomplete?{incomplete:true,severity:'warning' as const}:{})});
  }
 };
 for(const scope of graph.scopes.values()){
  if(!isNativeFamily(scope.family))continue;
  const node=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!;
  if(scope.kind==='content-map'&&segments(scope.pointer).at(-1)==='content'){
   const parent=graph.scopes.get(scope.resource+'#'+scope.pointer.slice(0,scope.pointer.lastIndexOf('/')));
   if(!parent||!['parameter','header','request-body','response'].includes(parent.kind)||node.kind!=='object')continue;
   for(const name of node.children.keys())check(scope,scope.pointer+'/'+escape(name),name,['request-body','response'].includes(parent.kind));
  }
  if(scope.family==='2.0'&&['root','operation'].includes(scope.kind)){
   for(const name of ['consumes','produces']){
    const types=node.children.get(name);
    if(types?.kind!=='array')continue;
    for(const [index,item]of types.children)if(typeof item.value==='string')
     check(scope,scope.pointer+'/'+name+'/'+index,item.value,false);
   }
  }
 }
 return issues;
}
