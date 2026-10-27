import {escape} from './document';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import type {MigrationIssue} from './migration_schema';
import type {MigrationSource} from './migration_source';
import type {SchemaPropertyRequirements} from './schema_property_requirements';

/** Validation 2020-12 6.5.4: presence implies required properties, regardless
 * of the triggering value. OAS 3.0's anyOf/not/required express the same rule.
 * Move each original array through the CST so its values and comments survive. */
export function migrateDependentRequired(graph:ReferenceGraph,scope:GraphScope,source:MigrationSource,pointer:string,target:string,requirements:SchemaPropertyRequirements,issue:MigrationIssue):void {
    const doc=graph.docs.get(scope.resource)!,original=scope.pointer+'/dependentRequired',node=doc.dataNode(original);
    if(!node)return;
    // This map's independent schema role has unknown keywords, rather than
    // the dependency assertions attached to its containing Schema Object.
    if(graph.scopes.get(scope.resource+'#'+original)?.kind==='schema'){
        issue({...scope,pointer:original},'migration.schema.dependency-shared-role','The dependency map is also used as a Schema Object and needs a separate faithful representation','implementation');return;
    }
    if(node.kind!=='object'){
        issue({...scope,pointer:original},'migration.schema.dependent-required','Expected a captured dependentRequired map before conversion','source-incomplete');return;
    }
    const required=new Set<string>();
    for(const item of doc.dataNode(scope.pointer+'/required')?.children.values()??[])if(typeof item.value==='string')required.add(item.value);
    const dependencies=new Map<string,string[]>(),entries:{trigger:string;pointer:string;tautology:boolean}[]=[];
    for(const [trigger,array]of node.children){
        const values:string[]=[];
        if(array.kind!=='array'){
            issue({...scope,pointer:original+'/'+escape(trigger)},'migration.schema.dependent-required','Expected a captured property-name array before conversion','source-incomplete');return;
        }
        for(const item of array.children.values()){
            if(typeof item.value!=='string'){
                issue({...scope,pointer:item.pointer},'migration.schema.dependent-required','Expected a captured property name before conversion','source-incomplete');return;
            }
            values.push(item.value);
        }
        const at=original+'/'+escape(trigger);
        if(source.current(at)===undefined){issue({...scope,pointer:at},'migration.schema.dependency-owner','The dependency array has no unique surviving planning owner','implementation');return;}
        dependencies.set(trigger,values);
        entries.push({trigger,pointer:at,tautology:values.every(value=>value===trigger)});
        if(target==='2.0'&&!required.has(trigger)&&requirements.requires(scope,trigger))required.add(trigger);
    }
    // Required seeds activate transitive and cyclic dependencies by presence.
    const queue=[...required];
    for(let index=0;index<queue.length;index++)for(const name of dependencies.get(queue[index])??[])
        if(!required.has(name)){required.add(name);queue.push(name);}
    const active=entries.filter(entry=>!entry.tautology);
    if(target==='2.0')for(const entry of active)if(!required.has(entry.trigger)){
        issue({...scope,pointer:entry.pointer},'migration.schema.dependency-conditional',requirements.exhausted?'The captured property-presence proof exhausted its budget before establishing a faithful Swagger 2.0 mapping':'The captured property-presence proof cannot establish a faithful Swagger 2.0 mapping for this conditional dependency','implementation');return;
    }
    if(active.length){
        let collection=pointer+'/allOf';
        const branches=active.map(entry=>required.has(entry.trigger)?{}:{anyOf:[{not:{required:[entry.trigger]}},{}]});
        if(source.doc.nodes.has(collection)){
            const branch=collection+'/'+source.doc.node(collection).children.size;
            source.set(branch,{allOf:branches});collection=branch+'/allOf';
        }else source.set(collection,branches);
        for(const [index,entry]of active.entries()){
            const at=source.current(entry.pointer);
            if(at===undefined){issue({...scope,pointer:entry.pointer},'migration.schema.dependency-owner','The dependency array lost its planning owner','implementation');return;}
            source.move(at,collection+'/'+index+(required.has(entry.trigger)?'/required':'/anyOf/1/required'));
        }
    }
    const at=source.current(original);if(at!==undefined)source.remove(at,true,true,true);
}
