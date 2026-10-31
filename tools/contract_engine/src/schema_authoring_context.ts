import type {GraphScope, ReferenceGraph} from './reference_graph';

export type SchemaAuthoringContext = Readonly<{
    root: string; rootVersion: string | null; resource: string; resourceVersion: string | null; pointer: string;
    family: string; dialect: string | null; base: string; resourcePointer: string;
}>;

/** Authoring metadata belongs to an occurrence in a captured graph. Equal
 * choice lists do not make a review transferable to a different declaration,
 * resource identity or schema dialect. */
export function schemaAuthoringContext(graph: ReferenceGraph, scope: GraphScope): SchemaAuthoringContext {
    return {root: graph.root, rootVersion: graph.specifications.get(graph.root)?.declaredVersion ?? null,
        resource: scope.resource, resourceVersion: graph.specifications.get(scope.resource)?.declaredVersion ?? null,
        pointer: scope.pointer, family: scope.family, dialect: scope.dialect,
        base: scope.base, resourcePointer: scope.resourcePointer};
}

export function sameSchemaAuthoringContext(expected: unknown, current: SchemaAuthoringContext): boolean {
    if (!expected || typeof expected !== 'object' || Array.isArray(expected)) return false;
    const supplied = expected as Record<string, unknown>;
    return (Object.keys(current) as (keyof SchemaAuthoringContext)[]).every(key => supplied[key] === current[key]);
}
