import {supportedSchemaDialect} from './reference_graph';
import {segments} from './document';
import type {GraphScope,GraphTarget,GraphIssue,ReferenceGraph} from './reference_graph';

export const xmlContextRevision='1';
export type XmlInferredName=
    Readonly<{kind:'component'|'property'|'item';name:string;source:GraphTarget}>|
    Readonly<{kind:'missing'}>;

/** OAS 3.2 §4.26.3 names come from typed schema positions, never file names,
 * operation identifiers or lookalike keys in example/extension payloads. */
export function xmlInferredName(graph:ReferenceGraph,schema:GraphScope):XmlInferredName {
    let current=schema,item=false;
    while(true){
        const tokens=segments(current.pointer),parent=current.pointer.slice(0,current.pointer.lastIndexOf('/'));
        const map=graph.scopes.get(current.resource+'#'+parent);
        if(tokens.at(-2)==='properties'&&map?.kind==='schema-map'){
            const owner=graph.scopes.get(current.resource+'#'+parent.slice(0,-'/properties'.length));
            if(owner?.kind==='schema')return {kind:item?'item':'property',name:tokens.at(-1)!,source:current};
        }
        if(!item&&tokens.length===3&&tokens[0]==='components'&&tokens[1]==='schemas'&&map?.kind==='schema-map'&&
            graph.scopes.get(current.resource+'#/components')?.kind==='components')return {kind:'component',name:tokens[2],source:current};
        let owner:GraphScope|undefined;
        if(tokens.at(-1)==='items'&&map?.kind==='schema')owner=map;
        else if(tokens.at(-2)==='prefixItems'&&map?.kind==='schema-array')owner=graph.scopes.get(current.resource+'#'+parent.slice(0,-'/prefixItems'.length));
        if(owner?.kind!=='schema')return {kind:'missing'};
        item=true;current=owner;
    }
}

/** OAS 3.2 §4.26.3 requires an authored name for explicit named nodes
 * outside positions with an inferred name. Presence does not make that field
 * optional: Design/Source metadata and diagnostics share this requirement. */
export function xmlRequiresExplicitName(graph:ReferenceGraph,scope:GraphScope):boolean {
    if(scope.kind!=='xml'||scope.family!=='3.2'||!supportedSchemaDialect(scope))return false;
    const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
    if(!['element','attribute'].includes(value?.nodeType))return false;
    const schema=graph.scopes.get(scope.resource+'#'+scope.pointer.slice(0,-'/xml'.length));
    return schema?.kind==='schema'&&xmlInferredName(graph,schema).kind==='missing';
}

/** Informational meta-schemas cannot infer a node name from its containing
 * OpenAPI position. Keep contextual violations source-located in the graph. */
export function xmlRelationships(graph:ReferenceGraph):GraphIssue[] {
    const issues:GraphIssue[]=[];
    for(const scope of graph.scopes.values()){
        if(!xmlRequiresExplicitName(graph,scope))continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value;
        if(Object.hasOwn(value,'name'))continue;
        issues.push({...scope,code:'xml.name.required',message:'This XML node has no component or property name to inherit; add xml.name'});
    }
    return issues;
}
