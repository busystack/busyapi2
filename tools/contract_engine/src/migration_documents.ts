import {createGraph,type Resource} from './engine';
import type {MigrationIssue} from './migration_schema';
import type {MigrationLocation} from './migration_source';
import type {ReferenceGraph} from './reference_graph';
import {escape} from './document';

type Context=ReturnType<typeof createGraph>;

/** Each complete description is also an entry context. Shared bytes need one
 * transformation, so differing schema contexts cannot be merged by choosing
 * whichever entry happened to be visited first. Named connections are proved
 * separately against each migrated entry's namespace. */
export function migrationDocumentContexts(input:{root:string;resources:Resource[]},primary:Context,issue:MigrationIssue):readonly Context[] {
    const contexts=[primary];
    for(const [root]of primary.graph.specifications){
        if(root===input.root)continue;
        contexts.push(createGraph({...input,root}));
    }
    const scopes=new Map<string,string>();
    for(const {graph}of contexts){
        for(const [key,scope]of graph.scopes){
            const identity=JSON.stringify([scope.kind,scope.family,scope.dialect,scope.base,scope.resourcePointer]);
            if(scopes.has(key)&&scopes.get(key)!==identity)
                issue(scope,'migration.documents.context','This shared source has different schema or object contexts in captured descriptions; one converted owner is not proved equivalent','implementation');
            scopes.set(key,identity);
        }
    }
    return contexts;
}

/** Native target validity alone cannot establish that an implicit name still
 * selects the original definition. Prove its relocated physical owner for
 * every source entry, including names that intentionally vary by entry. */
export function proveMigrationConnections(source:ReferenceGraph,target:ReferenceGraph,mapped:(location:MigrationLocation)=>readonly MigrationLocation[],issue:MigrationIssue):void {
    const connections=new Map(target.references.filter(reference=>reference.connection||reference.keyword==='$dynamicRef').map(reference=>[JSON.stringify([reference.resource,reference.pointer+'/'+escape(reference.keyword)]),reference]));
    for(const reference of source.references){
        if((!reference.connection&&reference.keyword!=='$dynamicRef')||reference.resolution!=='resolved')continue;
        const field={resource:reference.resource,pointer:reference.pointer+'/'+escape(reference.keyword)};
        const fields=mapped(field),targets=mapped({resource:reference.targetResource!,pointer:reference.targetPointer!});
        if(!fields.length||fields.some(field=>{
            const connection=connections.get(JSON.stringify([field.resource,field.pointer]));
            return !connection||connection.resolution!=='resolved'||!targets.some(target=>target.resource===connection.targetResource&&target.pointer===connection.targetPointer);
        }))issue({...field,original:field},'migration.invariant.connection','The migrated entry does not retain this reference or implicit name\'s captured target','implementation');
        if(reference.keyword==='$dynamicRef')for(const field of fields){
            const connection=connections.get(JSON.stringify([field.resource,field.pointer]));
            const expected=reference.dynamic?.candidates.flatMap(candidate=>mapped(candidate));
            const actual=connection?.dynamic?.candidates;
            const identities=(values:readonly MigrationLocation[]|undefined)=>values===undefined?undefined:[...new Set(values.map(value=>JSON.stringify([value.resource,value.pointer])))].sort();
            if(reference.dynamic?.candidates.some(candidate=>!mapped(candidate).length)||Boolean(reference.dynamic)!==Boolean(connection?.dynamic)||JSON.stringify(identities(expected))!==JSON.stringify(identities(actual)))
                issue({...field,original:{resource:reference.resource,pointer:reference.pointer+'/'+escape(reference.keyword)}},'migration.invariant.dynamic','The migrated entry changes a captured dynamic reference scope or candidate owner','implementation');
        }

    }
}
