import type {createGraph,Resource} from './engine';
import type {ReferenceGraph,GraphScope} from './reference_graph';
import type {MigrationIssue} from './migration_schema';
import type {MigrationLocation,MigrationSource} from './migration_source';
import {requestOperation} from './execution';
import {ignoresRequestBody} from './operation_semantics';
import {modernFamily} from './specification';
import {segments} from './document';
import {standardOperationMethods} from './contexts';

/** Swagger 2.0 Path Item fixed fields cannot retain TRACE or additional
 * methods. Refuse at the operation before offering body-only decisions. */
export function checkOperationTarget(graph:ReferenceGraph,target:string,issue:MigrationIssue):void {
    if(target!=='2.0')return;
    for(const scope of graph.scopes.values()) {
        if(scope.kind!=='operation')continue;
        const contexts=graph.operationContexts(scope.resource,scope.pointer);
        const methods=contexts.length?contexts.map(context=>context.method):[segments(scope.pointer).at(-1)!];
        if(methods.some(method=>!standardOperationMethods(target).includes(method)))
            issue(scope,'migration.operation.method','Swagger 2.0 cannot represent this operation method','target-representation');
    }
}

/** Check effective bodies before structural mappings can hide their original
 * meaning. OAS 3.0's ignored declaration cannot represent an active body. */
export function checkRequestBodyTarget(context:ReturnType<typeof createGraph>,resources:Resource[],target:string,issue:MigrationIssue):void {
    if(target!=='3.0')return;
    for(const scope of context.graph.scopes.values()) {
        if(scope.kind!=='operation'||!modernFamily(scope.family)||!context.docs.get(scope.resource)!.dataNode(scope.pointer)?.children.has('requestBody'))continue;
        const contexts=context.graph.operationContexts(scope.resource,scope.pointer);
        // Reusable definitions also retain their declared fixed method, even
        // when no Paths occurrence consumes them in the captured root.
        const methods=contexts.length?contexts.map(occurrence=>occurrence.method):[segments(scope.pointer).at(-1)!];
        if(methods.some(method=>ignoresRequestBody('3.0',method.toUpperCase())))
            issue({resource:scope.resource,pointer:scope.pointer+'/requestBody'},'migration.body.target-ignored','OpenAPI 3.0 consumers must ignore this method\'s request body; the target cannot retain its active request semantics','target-representation');
    }
    for(const operation of context.graph.operations()) {
        if(operation.role!=='operation'||context.graph.scope(operation.source.resource,operation.source.pointer).family!=='2.0')continue;
        const plan=requestOperation({root:context.graph.root,snapshot:'migration-body',resources,
            resource:operation.source.resource,pointer:operation.source.pointer,occurrence:operation.occurrence},context);
        if(plan.requestBody&&ignoresRequestBody('3.0',plan.operation.method))
            issue(plan.requestBody.source,'migration.body.target-ignored',`OpenAPI 3.0 consumers must ignore this ${plan.operation.method} request body; the target cannot retain its active request semantics`,'target-representation');
    }
}

/** A source 3.0 ignored body must not become active in another family.
 * A composed Swagger upgrade retains its originally active body instead. */
export function migrateOperationBodies(graph:ReferenceGraph,sources:Map<string,MigrationSource>,from:string,to:string,original:(scope:GraphScope)=>string,issue:MigrationIssue):MigrationLocation[] {
    const omitted:MigrationLocation[]=[];
    if(from!=='3.0'||to==='3.0')return omitted;
    for(const scope of graph.scopes.values()) {
        if(scope.kind!=='operation'||scope.family!==from||original(scope)!=='3.0'||!graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.children.has('requestBody'))continue;
        const contexts=graph.operationContexts(scope.resource,scope.pointer),ignored=contexts.filter(context=>ignoresRequestBody(scope.family,context.method.toUpperCase()));
        if(!ignored.length)continue;
        const location={resource:scope.resource,pointer:scope.pointer+'/requestBody'};
        if(ignored.length!==contexts.length) {
            issue(location,'migration.body.shared-context','This shared operation has both applicable and ignored request-body occurrences; it needs separate target operations to retain both meanings','implementation');
        }else if(issue(location,'migration.body.ignored-activation','The target would activate a request body ignored by OpenAPI 3.0 consumers. Explicitly omit that declaration from the migrated copy to preserve effective request semantics','decision',['omit-ignored-body'])) {
            const source=sources.get(scope.resource)!,pointer=source.current(location.pointer);
            if(pointer!==undefined){source.remove(pointer);omitted.push(location);}
        }
    }
    return omitted;
}
