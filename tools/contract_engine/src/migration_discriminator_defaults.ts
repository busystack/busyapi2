import {createHash} from 'node:crypto';
import {SourceError} from './document';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import {pointerFragment} from './reference_graph';
import type {MigrationLocation,MigrationSource} from './migration_source';
import type {MigrationInput} from './migration';
import type {MigrationChoose,MigrationIssue} from './migration_schema';
import {SchemaPropertyRequirements} from './schema_property_requirements';
import {DiscriminatorAlternativeSelection} from './discriminator_alternatives';
import {MigrationDiscriminatorSamples,proveDiscriminatorFallbacks,type DiscriminatorFallbackCandidate} from './migration_discriminator_samples';

type OriginalChoice=MigrationLocation&{range:readonly number[];label:string};
type Plan=Readonly<{scope:GraphScope;candidates:readonly DiscriminatorFallbackCandidate[]}>;
const key=(location:MigrationLocation)=>JSON.stringify([location.resource,location.pointer]);

/** OAS 3.2.1 Discriminator Object: choose an eligible, proved alternative.
 * Earlier undefined fallback behavior remains an explicit reviewed decision;
 * setting metadata never replaces the parent or its validation constraints. */
export async function migrateDiscriminatorDefaults(input:MigrationInput,graph:ReferenceGraph,
    sources:ReadonlyMap<string,MigrationSource>,issue:MigrationIssue,choose:MigrationChoose,
    original:(location:MigrationLocation)=>OriginalChoice):Promise<void> {
    const requirements=new SchemaPropertyRequirements(graph);
    const selection=new DiscriminatorAlternativeSelection(graph),samples=new MigrationDiscriminatorSamples(graph);
    const plans:Plan[]=[],candidates:DiscriminatorFallbackCandidate[]=[];
    let proposedBytes=0,proposedChecks=0;
    for(const scope of graph.scopesFor('schema')){
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        if(scope.family!=='3.2'||typeof value?.discriminator?.propertyName!=='string'||value.discriminator.defaultMapping!==undefined)continue;
        const name=value.discriminator.propertyName,location={...scope,pointer:scope.pointer+'/discriminator'};
        if(requirements.requires(scope,name))continue;
        if(requirements.exhausted){
            issue(location,'limit.migration.discriminator.required','The bounded proof could not establish discriminator property presence','source-incomplete');
            continue;
        }
        const discovered=selection.discover(scope);
        if(discovered.problems.length){
            for(const problem of discovered.problems)issue(problem.scope,problem.code,problem.message,'implementation');
            continue;
        }
        const selected:DiscriminatorFallbackCandidate[]=[];
        for(const alternative of discovered.alternatives){
            if(requirements.requires(alternative,name))continue;
            if(candidates.length>=128){
                issue(location,'limit.migration.discriminator.alternatives','Fallback qualification exceeds 128 captured alternatives','source-incomplete');
                return;
            }
            const candidate=samples.suggest(scope,alternative,name);
            proposedBytes+=candidate.samples.reduce((bytes,raw)=>bytes+Buffer.byteLength(raw)*2,0);
            proposedChecks+=candidate.samples.length*2;
            if(proposedBytes>8*1024*1024||proposedChecks>4096){
                issue(location,'limit.migration.discriminator.samples','Fallback qualification exceeds 4096 instance checks or 8 MiB','source-incomplete');
                return;
            }
            candidates.push(candidate);selected.push(candidate);
        }
        if(!selected.length){
            issue(location,'migration.discriminator.alternative',
                'No eligible composition alternative can be qualified for an absent discriminating property; revise the alternatives before migrating','implementation');
            continue;
        }
        plans.push({scope,candidates:selected});
    }
    if(!candidates.length)return;
    const proved=await proveDiscriminatorFallbacks(input,graph,candidates);
    for(const plan of plans){
        const alternatives=plan.candidates.filter(candidate=>proved.has(candidate));
        const location={...plan.scope,pointer:plan.scope.pointer+'/discriminator',decisionKey:key(plan.scope)};
        if(!alternatives.length){
            const limited=plan.candidates.some(candidate=>candidate.limited);
            issue(location,'migration.discriminator.unproven',limited?
                'No fallback witness was established within the bounded exact-value candidate budget':
                'No proposed object without the discriminating property validates against both an alternative and the complete parent',
                'implementation');
            continue;
        }
        const choices=alternatives.map(candidate=>{
            const target=original(candidate.alternative);
            return {value:'discriminator-alternative:'+createHash('sha256').update(key(candidate.alternative)).digest('hex').slice(0,24),
                label:target.label,target:{resource:target.resource,pointer:target.pointer,range:target.range}};
        });
        const selected=choose(location,'migration.discriminator.default',
            'OpenAPI 3.2 requires a fallback for this optional discriminating property. Select an eligible composition alternative for absent or unmapped values',choices);
        if(selected===undefined)continue;
        const index=choices.findIndex(choice=>choice.value===selected);
        if(index<0)throw new SourceError('migration.discriminator.choice','The migration decision selected an unoffered discriminator alternative');
        const target=alternatives[index].alternative;
        sources.get(plan.scope.resource)!.set(location.pointer+'/defaultMapping',target.resource+pointerFragment(target.pointer));
    }
}
