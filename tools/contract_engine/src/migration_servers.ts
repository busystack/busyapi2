import {modernFamily} from './specification';
import {finiteServerVariableValues} from './server_semantics';
import {resolveUri,type ReferenceGraph} from './reference_graph';
import type {MigrationSource} from './migration_source';
import type {MigrationIssue} from './migration_schema';

/** 3.0 §4.7.6 sends the declared default even outside its recommended enum.
 * Modern families require membership. Appending only that already permitted
 * value retains every substitution while satisfying the target requirement. */
export function migrateServerVariableDefaults(graph:ReferenceGraph,sources:Map<string,MigrationSource>,from:string,target:string,issue:MigrationIssue):void {
 if(from!=='3.0'||!modernFamily(target))return;
 for(const scope of graph.scopes.values()){
  if(scope.kind!=='server-variable'||scope.family!==from)continue;
  const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
  const choices=finiteServerVariableValues(value);
  if(!choices||!Array.isArray(value.enum)||value.enum.includes(value.default))continue;
  const source=sources.get(scope.resource)!,original=scope.pointer+'/enum',pointer=source.current(original);
  if(pointer===undefined){issue({...scope,pointer:original},'migration.server.variable-owner','The Server variable choices have no surviving planning owner','implementation');continue;}
  const node=source.doc.dataNode(pointer);
  if(node?.kind!=='array'){issue({...scope,pointer:original},'migration.server.variable-owner','The Server variable choices no longer have an array representation','implementation');continue;}
  source.set(pointer+'/'+node.children.size,value.default);
 }
}

/** Omitted/empty root Servers mean '/' relative to the API retrieval URI.
 * Materialize that effective default only in the reviewed output copy; a
 * new retrieval directory must not silently choose a different API origin. */
export function retainDefaultServers(graph:ReferenceGraph,sources:Map<string,MigrationSource>):void {
 for(const [resource,specification]of graph.specifications){
  if(specification.family==='2.0')continue;
  const root=graph.docs.get(resource)!.root;
  if(!root.children.has('servers')||Array.isArray(root.value.servers)&&root.value.servers.length===0)
   sources.get(resource)!.set('/servers',[{url:resolveUri('/',graph.retrievals.get(resource)!).href}]);
 }
}
