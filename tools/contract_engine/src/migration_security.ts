import {escape} from './document';
import type {ReferenceGraph} from './reference_graph';
import type {MigrationIssue} from './migration_schema';
import type {SpecificationFamily} from './specification';
import {securityRequirementDefinition,securityRequirementValuesAllowed} from './security_requirements';

/** Roles are standard in 3.1/3.2 but have no in-band representation in older
 * non-OAuth requirements (3.1.2 §4.8.30; 3.0.4 §4.7.30; 2.0 §6.4.26).
 * Check original graph connections before target validation can obscure them. */
export function checkSecurityRequirementTarget(graph:ReferenceGraph,target:SpecificationFamily,issue:MigrationIssue):void {
    for(const reference of graph.references){
        if(reference.connection!=='security'||reference.resolution!=='resolved'||reference.targetResource===undefined||reference.targetPointer===undefined)continue;
        const definition=securityRequirementDefinition(graph,{resource:reference.targetResource,pointer:reference.targetPointer,kind:'security'});
        const value=definition&&graph.docs.get(definition.resource)?.dataNode(definition.pointer)?.value;
        const pointer=reference.pointer+'/'+escape(reference.keyword),roles=graph.docs.get(reference.resource)?.dataNode(pointer);
        if(roles?.kind==='array'&&!securityRequirementValuesAllowed(target,value?.type,roles.children.size))
            issue({resource:reference.resource,pointer},'migration.security.roles','The target requires an empty non-OAuth security list and cannot retain these role requirements','target-representation');
    }
}
