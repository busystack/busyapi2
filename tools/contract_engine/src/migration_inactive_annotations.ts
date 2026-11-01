import {createHash} from 'node:crypto';
import {escape} from './document';
import {componentLocation} from './authoring';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import type {MigrationSource} from './migration_source';
import {restrictedBooleanSchema} from './migration_schema_values';

/** OAS 3.0.4 Schema Object fixed fields: writeOnly/deprecated default to false.
 * Their inactive values impose neither a directional rule nor deprecation.
 * Swagger has no corresponding fields. Remove only these false annotations;
 * a modern value also referenced as a boolean schema keeps a separate owner.
 * Active annotations still require their own faithful representation. */
export function migrateInactiveSchemaAnnotations(graph:ReferenceGraph,scope:GraphScope,source:MigrationSource,
    sources:ReadonlyMap<string,MigrationSource>,target:string):void {
    if(target!=='2.0'||scope.family==='2.0')return;
    const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
    if(graph.referenceObject(value,scope))return;
    for(const field of ['writeOnly','deprecated']){
        if(value?.[field]!==false)continue;
        const original=scope.pointer+'/'+escape(field),current=source.current(original);
        if(current===undefined||!source.doc.dataNode(current))continue;
        if(graph.scopeAs(scope.resource,original,'schema')){
            const entry=sources.get(graph.root)!;
            const container=componentLocation('schemas',graph.family)!;
            const stem='_migrated_annotation_'+createHash('sha256').update(JSON.stringify([scope.resource,original])).digest('hex').slice(0,24);
            let destination=container+'/'+stem,index=0;
            while(entry.doc.dataNode(destination))destination=container+'/'+stem+'_'+(++index);
            if(entry===source)source.move(current,destination,true);
            else {entry.copy(source,current,destination,true);source.remove(current);}
            // The graph may retain this independent schema role separately
            // from its physical annotation field. Lower its boolean value
            // after moving it, without giving the annotation object meaning.
            if(entry.doc.dataNode(destination)?.value===false)entry.set(destination,restrictedBooleanSchema(false,target));
            entry.presentationChanges.push(destination);
        }else source.remove(current,true,true,true);
    }
}
