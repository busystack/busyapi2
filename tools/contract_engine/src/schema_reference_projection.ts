import type {GraphReference,GraphTarget} from './reference_graph';

export const multipartProjectionRevision='1';

export type SchemaReferenceProjection =
    {state:'fixed';target:GraphTarget} |
    {state:'dynamic';candidates:readonly GraphTarget[]} |
    {state:'unresolved';resolution:string};

/** Static consumers project captured graph resolution, never resolve a
 * second URI or choose the first dynamic candidate. JSON Schema Core 8.2.3.2
 * gives pointer/static-anchor $dynamicRef the same target as $ref. A captured
 * dynamic anchor also has a fixed target when every candidate is that target;
 * differing candidates still require the evaluator's runtime binding. */
export function projectSchemaReference(reference:GraphReference):SchemaReferenceProjection {
    if(reference.kind!=='schema'||!['$ref','$dynamicRef'].includes(reference.keyword)||reference.connection)
        return {state:'unresolved',resolution:'wrong-context'};
    if(reference.resolution!=='resolved')return {state:'unresolved',resolution:reference.resolution};
    const {targetResource:resource,targetPointer:pointer}=reference;
    if(resource===undefined||pointer===undefined)return {state:'unresolved',resolution:'missing-target'};
    if(reference.keyword==='$dynamicRef'&&reference.dynamic){
        const candidates=reference.dynamic.candidates;
        if(!candidates.length)return {state:'unresolved',resolution:'missing-dynamic-targets'};
        if(candidates.some(target=>target.resource!==resource||target.pointer!==pointer))return {state:'dynamic',candidates};
    }
    return {state:'fixed',target:{resource,pointer,kind:'schema'}};
}
