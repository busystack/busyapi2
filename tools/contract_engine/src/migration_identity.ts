import {escape} from './document';
import {documentUriOccurrences} from './document_uris';
import {documentUriBase,implicitNameReference,resolveUri,type ReferenceGraph} from './reference_graph';
import type {MigrationSource,MigrationLocation} from './migration_source';
import type {MigrationIssue} from './migration_schema';

/** OAS 3.2 §§4.1.1–4.1.2: lower a document identity only after capturing the
 * URI meaning of every affected occurrence. API URLs retain their retrieval/
 * Server context. Temporary graph aliases are not a new acquisition authority;
 * normal relocation and cold proofs must remove dependency on those aliases. */
export function migrateDocumentIdentities(graph:ReferenceGraph,sources:ReadonlyMap<string,MigrationSource>,
    target:string,issue:MigrationIssue):ReadonlyMap<string,readonly string[]> {
    const identities=new Map<string,readonly string[]>();
    if(target==='3.2')return identities;
    for(const [resource,specification]of graph.specifications){
        const doc=graph.docs.get(resource)!;
        if(specification.family!=='3.2'||typeof doc.dataNode('/$self')?.value!=='string')continue;
        if(graph.hasOverlappingScope(resource,'')){
            issue({resource,pointer:'/$self'},'migration.identity.shared-owner',
                'This document also has an independent schema interpretation; lowering its identity needs separate source ownership','implementation');
            continue;
        }
        identities.set(resource,[graph.retrievals.get(resource)!,graph.scope(resource,'').base]);
    }
    const set=(location:MigrationLocation,value:string)=>{
        const source=sources.get(location.resource)!,at=source.current(location.pointer);
        if(at===undefined||source.doc.dataNode(at)?.value===value)return;
        if(graph.literalContainer(location.resource,location.pointer)!==undefined){
            issue(location,'migration.identity.literal-owner',
                'This URI also belongs to literal data; lowering its document base needs a separate occurrence-owned representation','implementation');
            return;
        }
        source.set(at,value);
    };
    for(const occurrence of documentUriOccurrences(graph)){
        if(!identities.has(occurrence.scope.resource)||occurrence.scope.kind==='server')continue;
        set({resource:occurrence.scope.resource,pointer:occurrence.pointer},
            resolveUri(occurrence.value,documentUriBase(graph,occurrence.scope)).href);
    }
    for(const scope of graph.scopesFor('schema')){
        if(!identities.has(scope.resource))continue;
        if(typeof graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value?.$id==='string')
            set({...scope,pointer:scope.pointer+'/$id'},scope.base);
    }
    for(const reference of graph.references){
        if(!identities.has(reference.resource)||reference.resolution!=='resolved'||implicitNameReference(reference))continue;
        if(!['$ref','$dynamicRef','operationRef'].includes(reference.keyword)&&reference.connection!=='discriminator')continue;
        set({...reference,pointer:reference.pointer+'/'+escape(reference.keyword)},resolveUri(reference.value,reference.base).href);
    }
    for(const [resource]of identities)sources.get(resource)!.remove('/$self');
    return identities;
}
