import type {ReferenceGraph} from './reference_graph';
import {pointerFragment} from './reference_graph';
import type {MigrationSource} from './migration_source';
import type {MigrationIssue} from './migration_schema';
import {SchemaPropertyRequirements} from './schema_property_requirements';

/** OAS 3.2 §4.30 requires a fallback when the discriminating property is
 * optional. Earlier families leave that behavior undefined: choosing one is
 * a reviewed decision, never an inferred equivalence or validation bypass. */
export function migrateDiscriminatorDefaults(graph:ReferenceGraph,
    sources:ReadonlyMap<string,MigrationSource>,issue:MigrationIssue):void {
    const proof=new SchemaPropertyRequirements(graph);
    for(const scope of graph.scopesFor('schema')){
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        if(scope.family!=='3.2'||typeof value?.discriminator?.propertyName!=='string'||
            value.discriminator.defaultMapping!==undefined)continue;
        if(proof.requires(scope,value.discriminator.propertyName))continue;
        const location={...scope,pointer:scope.pointer+'/discriminator'};
        if(proof.exhausted){
            issue(location,'limit.migration.discriminator.required',
                'The bounded proof could not establish discriminator property presence','source-incomplete');
            continue;
        }
        if(issue(location,'migration.discriminator.default',
            'OpenAPI 3.2 needs a required discriminating property or an explicit fallback. Select this occurrence’s schema as the fallback for absent or unmapped values, or revise the source',
            'decision',['use-schema-as-default']))
            sources.get(scope.resource)!.set(location.pointer+'/defaultMapping',scope.resource+pointerFragment(scope.pointer));
    }
}
