import {nativeFamilies,type Specification,type SpecificationFamily} from './specification';

export type MigrationStage=Readonly<{from:SpecificationFamily;to:SpecificationFamily}>;
/** Coordinate family stages without passing an already-newer description
 * through an older dialect. Swagger downgrades remain direct: its Draft 4
 * unions and tuples need not pass through 3.0's narrower Schema Object. */
export function migrationStages(specifications:Iterable<Specification>,target:SpecificationFamily):readonly MigrationStage[] {
    const active=new Set([...specifications].map(specification=>specification.family)),stages:MigrationStage[]=[];
    const step=(from:SpecificationFamily,to:SpecificationFamily)=>{
        if(!active.has(from))return;
        stages.push({from,to});active.delete(from);active.add(to);
    };
    if(target==='2.0')for(const from of nativeFamilies.slice(1))step(from,target);
    else {
        const finish=nativeFamilies.indexOf(target);
        for(let index=0;index<finish;index++)step(nativeFamilies[index],nativeFamilies[index+1]);
        for(let index=nativeFamilies.length-1;index>finish;index--)step(nativeFamilies[index],nativeFamilies[index-1]);
    }
    return stages;
}

export type EntryMigrationRoute=Readonly<{resource:string;from:Specification;target:Specification;stages:readonly MigrationStage[]}>;
export function entryMigrationRoutes(specifications:ReadonlyMap<string,Specification>,target:Specification):readonly EntryMigrationRoute[] {
    return [...specifications].map(([resource,from])=>({resource,from,target,stages:migrationStages([from],target.family)}));
}

export type MigrationBatch=Readonly<{sources:readonly SpecificationFamily[];to:SpecificationFamily}>;
/** Connected modern descriptions must reach Swagger together: validating a
 * half-converted graph would interpret their references across dialect families. */
export function migrationBatches(specifications:ReadonlyMap<string,Specification>,target:SpecificationFamily):readonly MigrationBatch[] {
    if(target==='2.0'){
        const sources=nativeFamilies.filter(family=>family!=='2.0'&&[...specifications.values()].some(specification=>specification.family===family));
        return sources.length?[{sources,to:target}]:[];
    }
    return migrationStages(specifications.values(),target).map(stage=>({sources:[stage.from],to:stage.to}));
}
