import type {GraphScope,ReferenceGraph} from './reference_graph';

/** Swagger Parameter/Header/Items Objects expose a restricted flat schema,
 * while retaining their native object kind (2.0 §§6.4.9–6.4.12). */
export function flatSchemaContext(graph:ReferenceGraph,scope:GraphScope):boolean {
    if(scope.family!=='2.0')return false;
    const value=graph.docs.get(scope.resource)?.dataNode(scope.pointer)?.value;
    return scope.kind==='parameter'&&value?.in!=='body'&&typeof value?.$ref!=='string'||['header','items'].includes(scope.kind);
}

/** A consumer requesting schema semantics must select that interpretation;
 * physical authoring ownership remains available through the graph itself. */
export function schemaContext(graph:ReferenceGraph,resource:string,pointer:string):GraphScope|undefined {
    const schema=graph.scopeAs(resource,pointer,'schema');
    if(schema)return schema;
    const physical=graph.scopes.get(resource+'#'+pointer);
    return physical&&flatSchemaContext(graph,physical)?physical:undefined;
}
