import {escape,SourceError,type SourceDocument} from './document';
import type {ReferenceGraph,GraphScope} from './reference_graph';
import {supportedSchemaDialect} from './reference_graph';
import {schemaKeywordKnown} from './schema_evaluation';

/** Unknown keywords are annotations (Core 4.3.1). Another object context may
 * repair a URI or name in their values; that does not preserve the annotation.
 * Check the captured schema interpretation before any transformed publication. */
export function assertRoleAnnotations(graph:ReferenceGraph,scope:GraphScope,after:SourceDocument,pointer:string):void {
    if(!graph.hasOverlappingScope(scope.resource,scope.pointer))return;
    const doc=graph.docs.get(scope.resource)!,node=doc.dataNode(scope.pointer);
    if(!node||node.kind!=='object')return;
    if(!after.dataNode(pointer))throw new SourceError('schema.role.missing','The transformed object would remove an independently interpreted schema; a separate context mapping is required',node.range,'unsupported',{resource:scope.resource,pointer:scope.pointer,range:node.range});
    if(typeof scope.dialect!=='string'||!supportedSchemaDialect(scope))
        throw new SourceError('schema.role.dialect','An overlapping schema needs its supported captured dialect before transformation',node.range,'unsupported',{resource:scope.resource,pointer:scope.pointer,range:node.range});
    for(const name of node.children.keys()){
        if(schemaKeywordKnown(scope.dialect,name))continue;
        const from=scope.pointer+'/'+escape(name),to=pointer+'/'+escape(name),value=doc.dataNode(from)!;
        if(!after.dataNode(to)||doc.dataJson(from)!==after.dataJson(to))
            throw new SourceError('schema.role.annotation','The transformed object would change an independently interpreted schema annotation; a separate context mapping is required',value.range,'unsupported',{resource:scope.resource,pointer:from,range:value.range});
    }
}
