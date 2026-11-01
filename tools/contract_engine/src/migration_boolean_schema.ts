import {createHash} from 'node:crypto';
import {componentLocation} from './authoring';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import type {MigrationSource} from './migration_source';
import {restrictedBooleanSchema} from './migration_schema_values';

/** Restricted Schema Objects allow a boolean additionalProperties field but
 * not a standalone boolean schema. Preserve both roles when a captured modern
 * reference targets that field (OAS 3.0.4 §4.7.24.1; Core 2020-12 §4.3.2).
 * Schema provenance moves to a generated definition; the field's syntax and
 * value remain with its original object. No references are searched in data. */
export class BooleanSchemaMigration {
    private readonly referenced=new Set<string>();

    constructor(private readonly graph:ReferenceGraph,
        private readonly sources:ReadonlyMap<string,MigrationSource>,private readonly target:string){
        for(const reference of graph.references){
            if(reference.kind==='schema'&&!reference.connection&&reference.resolution==='resolved')
                this.referenced.add(JSON.stringify([reference.targetResource,reference.targetPointer]));
        }
    }

    lower(scope:GraphScope,source:MigrationSource,pointer:string,value:boolean):void {
        const parent=scope.pointer.slice(0,scope.pointer.lastIndexOf('/'));
        const field=scope.pointer.endsWith('/additionalProperties')&&
            this.graph.scopeAs(scope.resource,parent,'schema')!==undefined;
        if(!field){source.set(pointer,restrictedBooleanSchema(value,this.target));return;}
        if(!this.referenced.has(JSON.stringify([scope.resource,scope.pointer])))return;

        const entry=this.sources.get(this.graph.root)!;
        const container=componentLocation('schemas',this.graph.family)!;
        const stem='_migrated_additional_'+createHash('sha256')
            .update(JSON.stringify([scope.resource,scope.pointer])).digest('hex').slice(0,24);
        let destination=container+'/'+stem,index=0;
        while(entry.doc.dataNode(destination))destination=container+'/'+stem+'_'+(++index);
        entry.copy(source,pointer,destination);
        // The copy now owns incoming schema references. Leaving this physical
        // field in its target set would make reference repair ambiguous. Its
        // containing object's provenance still retains the unchanged field.
        for(const locations of source.originSets())locations.delete(pointer);
        entry.set(destination,restrictedBooleanSchema(value,this.target));
        entry.presentationChanges.push(destination);
    }
}
