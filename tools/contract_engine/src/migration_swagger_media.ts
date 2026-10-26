import {createHash} from 'node:crypto';
import {escape} from './document';
import {pointerFragment,type ReferenceGraph,type GraphTarget} from './reference_graph';
import {MigrationSource,type MigrationLocation} from './migration_source';
import type {MigrationIssue} from './migration_schema';
import {swaggerMedia} from './swagger_operation';

type MediaOwner=MigrationLocation&{schema?:MigrationLocation;media:readonly string[]};
const key=(location:MigrationLocation)=>location.resource+'#'+location.pointer;
const reference=(location:MigrationLocation)=>location.resource+pointerFragment(location.pointer);
const mediaKey=(media:readonly string[])=>JSON.stringify([...new Set(media)].sort());

/** Swagger §6.4.7 media overrides belong to each operation, not to the shared
 * Parameter/Response definition. OAS 3.0 §§4.7.13/4.7.17 instead put content on
 * that definition. Preserve one schema owner and specialize the media wrapper.
 * All copies are CST planning copies, with original payload provenance. */
export function swaggerMediaMigration(graph:ReferenceGraph,sources:Map<string,MigrationSource>,issue:MigrationIssue) {
    const entry=sources.get(graph.root)!;
    const bodies=new Map<string,MediaOwner>(),variants=new Map<string,MigrationLocation>();
    const edges=new Map(graph.references.filter(edge=>edge.keyword==='$ref').map(edge=>[key(edge),edge]));
    const component=(group:'schemas'|'requestBodies'|'responses',scope:MigrationLocation,variant='')=>{
        const stem='_migrated_'+createHash('sha256').update(JSON.stringify([scope.resource,scope.pointer,variant])).digest('hex').slice(0,24);
        let name=stem,index=0;
        while(entry.doc.nodes.has('/components/'+group+'/'+name)||group==='schemas'&&entry.doc.nodes.has('/definitions/'+name))name=stem+'_'+(++index);
        return {resource:graph.root,pointer:'/components/'+group+'/'+name};
    };
    const schemaOwner=(scope:MigrationLocation,pointer:string):MigrationLocation|undefined=>{
        const source=sources.get(scope.resource)!;
        if(!source.doc.nodes.has(pointer+'/schema'))return;
        const destination=component('schemas',{resource:scope.resource,pointer:scope.pointer+'/schema'});
        if(source===entry)entry.move(pointer+'/schema',destination.pointer);
        else {entry.copy(source,pointer+'/schema',destination.pointer);source.remove(pointer+'/schema');}
        return destination;
    };
    const content=(owner:MediaOwner,media:readonly string[])=>{
        const source=sources.get(owner.resource)!;
        source.ensure(owner.pointer+'/content');
        for(const name of media){
            const pointer=owner.pointer+'/content/'+escape(name);
            if(!source.doc.nodes.has(pointer))source.set(pointer,owner.schema?{schema:{$ref:reference(owner.schema)}}:{});
        }
    };
    const variant=(owner:MediaOwner,group:'requestBodies'|'responses',media:readonly string[])=>{
        if(mediaKey(owner.media)===mediaKey(media))return owner;
        const identity=JSON.stringify([owner.resource,owner.pointer,mediaKey(media)]),cached=variants.get(identity);
        if(cached)return cached;
        const destination=component(group,owner,mediaKey(media)),source=sources.get(owner.resource)!;
        entry.copy(source,owner.pointer,destination.pointer);
        // Response examples are independently media-keyed in Swagger. Their
        // representations remain present even outside an operation's produces.
        for(const [name,node]of entry.doc.node(destination.pointer+'/content').children)
            if(!media.includes(name)&&!node.children.has('example'))entry.remove(node.pointer);
        content({...destination,schema:owner.schema,media},media);
        variants.set(identity,destination);
        return destination;
    };
    const body=(definition:MigrationLocation,media:readonly string[]):MigrationLocation|undefined=>{
        let owner=bodies.get(key(definition));
        if(!owner){
            const source=sources.get(definition.resource)!,pointer=source.current(definition.pointer);
            if(pointer===undefined)return;
            const destination=source===entry?component('requestBodies',definition):{resource:definition.resource,pointer};
            if(source===entry)source.move(pointer,destination.pointer);
            source.remove(destination.pointer+'/name');source.remove(destination.pointer+'/in');
            owner={...destination,schema:schemaOwner(definition,destination.pointer),media:[...media]};
            content(owner,media);bodies.set(key(definition),owner);
        }
        return variant(owner,'requestBodies',media);
    };
    const unusedBodies=()=>{
        for(const scope of graph.scopes.values())if(scope.family==='2.0'&&scope.kind==='parameter'){
            const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value;
            if(value?.in==='body'&&typeof value.$ref!=='string'&&!bodies.has(key(scope)))body(scope,swaggerMedia(graph,graph.root,'','consumes'));
        }
    };
    const responses=():ReadonlyMap<string,MigrationLocation>=>{
        const uses=new Map<string,{occurrence:GraphTarget;media:string[]}[]>(),retargets=new Map<string,MigrationLocation>();
        const primary=new Map<string,MigrationLocation>(bodies);
        for(const operation of graph.operations()){
            const declarations=graph.docs.get(operation.source.resource)!.dataNode(operation.source.pointer+'/responses');
            for(const name of declarations?.children.keys()??[]){
                if(name.startsWith('x-'))continue;
                const occurrence={resource:operation.source.resource,pointer:operation.source.pointer+'/responses/'+escape(name),kind:'response'};
                let current:MigrationLocation=occurrence;const seen=new Set<string>();
                for(let depth=0;depth<=128;depth++){
                    const identity=key(current),value=graph.docs.get(current.resource)?.dataNode(current.pointer)?.value;
                    if(seen.has(identity)||depth===128){issue(occurrence,'migration.response.reference','A response reference chain has no bounded concrete owner','source-incomplete');break;}
                    seen.add(identity);
                    if(typeof value?.$ref!=='string'){
                        const consumers=uses.get(identity)??[];
                        consumers.push({occurrence,media:swaggerMedia(graph,operation.source.resource,operation.source.pointer,'produces')});
                        uses.set(identity,consumers);break;
                    }
                    const edge=edges.get(identity);
                    if(edge?.kind!=='response'||edge.resolution!=='resolved'){
                        issue(occurrence,'migration.response.reference','A response reference has no captured concrete owner','source-incomplete');break;
                    }
                    current={resource:edge.targetResource!,pointer:edge.targetPointer!};
                }
            }
        }
        for(const scope of graph.scopes.values())if(scope.family==='2.0'&&scope.kind==='response'){
            const source=sources.get(scope.resource)!,pointer=source.current(scope.pointer);
            if(pointer===undefined||typeof graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value?.$ref==='string')continue;
            const consumers=uses.get(key(scope))??[],media=consumers[0]?.media??swaggerMedia(graph,graph.root,'','produces');
            const schema=schemaOwner(scope,pointer);
            const owner:MediaOwner={resource:scope.resource,pointer,schema,media:schema?media:[]};
            primary.set(key(scope),owner);
            const examples=source.doc.dataNode(pointer+'/examples');
            // Swagger 2.0 §6.4.12: no schema means no response content.
            // An unconstrained 3.x Media Type Object would activate a body.
            if(schema)content(owner,[...new Set([...media,...examples?.children.keys()??[]])]);
            else if(examples?.children.size)issue({...scope,pointer:scope.pointer+'/examples'},'migration.response.examples-without-schema','These authored examples need a target owner that does not activate response content','implementation');
            for(const name of [...examples?.children.keys()??[]])source.move(pointer+'/examples/'+escape(name),pointer+'/content/'+escape(name)+'/example');
            source.remove(pointer+'/examples');
            for(const consumer of consumers){
                const selected=variant(owner,'responses',schema?consumer.media:[]);
                if(typeof graph.docs.get(consumer.occurrence.resource)!.dataNode(consumer.occurrence.pointer)!.value?.$ref==='string')retargets.set(key(consumer.occurrence),selected);
            }
        }
        // Wrapper duplication has one retained primary declaration. Repair
        // intermediate chains to it; only concrete operation occurrences select
        // a media-specialized wrapper. Schema targets have one separate owner.
        for(const edge of graph.references)if(edge.keyword==='$ref'&&edge.resolution==='resolved'&&!retargets.has(key(edge))){
            const destination=primary.get(key({resource:edge.targetResource!,pointer:edge.targetPointer!}));
            if(destination)retargets.set(key(edge),destination);
        }
        return retargets;
    };
    return {body,unusedBodies,responses};
}
