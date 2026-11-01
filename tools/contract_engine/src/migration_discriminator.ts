import {createHash} from 'node:crypto';
import {SourceError} from './document';
import {documentUriOccurrences} from './document_uris';
import {documentUriBase,pointerFragment,resolveUri,type GraphScope,type ReferenceGraph} from './reference_graph';
import {MigrationSource,type MigrationLocation} from './migration_source';
import type {MigrationIssue} from './migration_schema';
import {DiscriminatorModels} from './discriminator_models';

const key=(location:MigrationLocation)=>JSON.stringify([location.resource,location.pointer]);
const inside=(pointer:string,root:string)=>pointer===root||pointer.startsWith(root+'/');
const address=(location:MigrationLocation)=>location.resource+pointerFragment(location.pointer);
type Mapping=Readonly<{
    primaryTargets:ReadonlyMap<string,MigrationLocation>;
    referenceTargets:ReadonlyMap<string,MigrationLocation>;
}>;

/** Swagger selection is scoped to an actual instance and active dispatcher.
 * Same-instance allOf/ref paths inherit that state; property/item instances
 * restart it. Separate target variants model the finite active-dispatcher
 * states, retaining composition instead of flattening accepted instances. */
export function migrateSwaggerDiscriminators(graph:ReferenceGraph,sources:Map<string,MigrationSource>,issue:MigrationIssue,
    contexts:readonly ReferenceGraph[],presentation:(original:MigrationLocation)=>void):Mapping {
    const bases=graph.scopesFor('schema').filter(scope=>scope.family==='2.0'&&
        typeof graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value?.discriminator==='string'&&
        typeof graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value?.$ref!=='string');
    const primaryTargets=new Map<string,MigrationLocation>(),referenceTargets=new Map<string,MigrationLocation>();
    if(!bases.length)return {primaryTargets,referenceTargets};
    for(const base of bases)if(graph.literalContainer(base.resource,base.pointer)!==undefined){
        issue({...base,pointer:base.pointer+'/discriminator'},'migration.discriminator.literal-context','This dispatcher also belongs to literal data; separate semantic ownership is required before specialization','implementation');
        return {primaryTargets,referenceTargets};
    }
    const entry=sources.get(graph.root)!;
    const sourceOf=(location:MigrationLocation)=>({...location,range:graph.docs.get(location.resource)!.dataNode(location.pointer)!.range});
    const pristine=new Map([...sources].map(([resource,source])=>[resource,source.fork()]));
    const locations=(original:MigrationLocation):MigrationLocation[]=>[...pristine].flatMap(([resource,source])=>
        [...(resource===original.resource?source.origins.get(original.pointer):source.foreignOrigins.get(original.resource+'#'+original.pointer))??[]]
            .map(pointer=>({resource,pointer})));
    for(const scope of graph.scopesFor('schema'))if(scope.family==='2.0'){
        const mapped=locations(scope);if(mapped.length===1)primaryTargets.set(key(scope),mapped[0]);
    }
    const primary=(original:MigrationLocation):MigrationLocation=>{
        const result=primaryTargets.get(key(original));
        if(!result)throw new SourceError('migration.discriminator.owner','A selected schema needs one proved primary converted owner',sourceOf(original).range,'unsupported',sourceOf(original));
        return result;
    };
    const tables=new Map<string,ReadonlyMap<string,GraphScope>>(),selections=new Map<ReferenceGraph,DiscriminatorModels>();
    const models=(context:ReferenceGraph,base:GraphScope)=>{
        let selection=selections.get(context);
        if(!selection){selection=new DiscriminatorModels(context);selections.set(context,selection);}
        return selection.models(base);
    };
    for(const base of bases){
        const table=models(graph,base),signature=(models:ReadonlyMap<string,GraphScope>)=>
            JSON.stringify([...models].map(([name,scope])=>[name,scope.resource,scope.pointer]).sort());
        for(const context of contexts){
            if(context.root===graph.root||context.specifications.get(context.root)?.family!=='2.0'||!context.scopeAs(base.resource,base.pointer,'schema'))continue;
            if(signature(models(context,base))!==signature(table)){
                issue({...base,pointer:base.pointer+'/discriminator'},'migration.discriminator.shared-context','Captured entry namespaces select different models for this dispatcher; separate entry-owned model variants are required','implementation');
                return {primaryTargets,referenceTargets};
            }
        }
        tables.set(key(base),table);
    }
    const references=graph.references.filter(edge=>edge.kind==='schema'&&!edge.connection&&edge.keyword==='$ref'&&edge.resolution==='resolved');
    const uris=[...documentUriOccurrences(graph)],reserved=new Set<string>();
    const variants=new Map<string,MigrationLocation>(),choicesByName=new Map<string,MigrationLocation>(),processed=new Set<string>();
    let edits=0,cost=0,cloneBytes=0,generated=0,inspected=0;
    let nonObject:MigrationLocation|undefined;
    const admit=(source:MigrationSource)=>{
        if(++edits>4096||(cost+=source.doc.text.length*2)>128*1024*1024)
            throw new SourceError('limit.migration.discriminator','Discriminator specialization exceeds its bounded CST edit work',undefined,'unsupported');
    };
    const inspect=()=>{if(++inspected>2000000)throw new SourceError('limit.migration.discriminator','Specialized reference/URI inspection exceeds its bounded work',undefined,'unsupported');};
    const reserve=(kind:string,identity:string,scope:GraphScope):MigrationLocation=>{
        if(++generated>2048)throw new SourceError('limit.migration.discriminator','Discriminator specialization exceeds 2048 generated schema owners',sourceOf(scope).range,'unsupported',sourceOf(scope));
        const stem='_migrated_'+kind+'_'+createHash('sha256').update(identity).digest('hex').slice(0,24);
        let name=stem,index=0;
        while(entry.doc.nodes.has('/components/schemas/'+name)||reserved.has(name))name=stem+'_'+(++index);
        reserved.add(name);
        return {resource:graph.root,pointer:'/components/schemas/'+name};
    };
    const mappedWithin=(original:MigrationLocation,owner:MigrationLocation,destination:MigrationLocation)=>{
        const at=locations(original).filter(location=>location.resource===owner.resource&&inside(location.pointer,owner.pointer));
        if(at.length!==1)throw new SourceError('migration.discriminator.provenance','A specialized occurrence has no unique converted source coordinate',sourceOf(original).range,'unsupported',sourceOf(original));
        return {resource:destination.resource,pointer:destination.pointer+at[0].pointer.slice(owner.pointer.length)};
    };
    const set=(at:MigrationLocation,value:unknown)=>{
        const source=sources.get(at.resource)!;admit(source);source.set(at.pointer,value);
    };
    const walk=(scope:GraphScope,owner:MigrationLocation,destination:MigrationLocation,active:ReadonlySet<string>,depth:number):void=>{
        if(depth>=128)throw new SourceError('limit.migration.discriminator','Same-instance discriminator composition exceeds 128 levels',sourceOf(scope).range,'unsupported',sourceOf(scope));
        const at=mappedWithin(scope,owner,destination),state=JSON.stringify([at,[...active].sort()]);
        if(processed.has(state))return;processed.add(state);
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        if(value===null||typeof value!=='object'||Array.isArray(value))return;
        if(typeof value.$ref==='string'){
            const reference=graph.referenceAs(scope.resource,scope.pointer,'$ref','schema');
            if(reference?.resolution!=='resolved')throw new SourceError('migration.discriminator.reference','Selection requires a resolved same-instance schema reference',sourceOf(scope).range,'unsupported',sourceOf(scope));
            const target=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'schema');
            if(!target)throw new SourceError('migration.discriminator.reference','The selected reference has no captured Schema Object');
            referenceTargets.set(key({...at,pointer:at.pointer+'/$ref'}),active.size?variant(target,active):primary(target));
            return;
        }
        for(const index of graph.docs.get(scope.resource)!.dataNode(scope.pointer+'/allOf')?.children.keys()??[]){
            const child=graph.scopeAs(scope.resource,scope.pointer+'/allOf/'+index,'schema');
            if(!child)throw new SourceError('migration.discriminator.scope','The selected composition has no captured child schema');
            walk(child,owner,destination,active,depth+1);
        }
        if(typeof value.discriminator!=='string')return;
        const source=sources.get(at.resource)!;
        if(active.has(key(scope))){admit(source);source.remove(at.pointer+'/discriminator');return;}
        const table=tables.get(key(scope));
        if(!table)throw new SourceError('migration.discriminator.context','A dispatcher has no captured named-model table');
        const next=new Set(active).add(key(scope)),mapping:Record<string,string>=Object.create(null);
        if(!nonObject){
            nonObject=reserve('nonobject',graph.root,scope);
            set(nonObject,{not:{type:'object'}});
        }
        const choices:{$ref:string}[]=[{$ref:address(nonObject)}];
        for(const [name,model]of table){
            const identity=JSON.stringify([scope.resource,scope.pointer,[...active].sort(),name]);
            let selected=choicesByName.get(identity);
            if(!selected){
                selected=reserve('choice',identity,scope);choicesByName.set(identity,selected);
                const target=variant(model,next);
                set(selected,{type:'object',properties:{[value.discriminator]:{enum:[name]}},allOf:[{$ref:address(target)}]});
            }
            Object.defineProperty(mapping,name,{value:address(selected),enumerable:true});
            choices.push({$ref:address(selected)});
        }
        if(source.doc.nodes.has(at.pointer+'/anyOf')){
            if(!source.doc.nodes.has(at.pointer+'/allOf'))set({...at,pointer:at.pointer+'/allOf'},[]);
            admit(source);source.move(at.pointer+'/anyOf',at.pointer+'/allOf/'+source.doc.node(at.pointer+'/allOf').children.size+'/anyOf');
        }
        set({...at,pointer:at.pointer+'/discriminator'},{propertyName:value.discriminator,mapping});
        set({...at,pointer:at.pointer+'/anyOf'},choices);
    };
    const variant=(scope:GraphScope,active:ReadonlySet<string>):MigrationLocation=>{
        const identity=JSON.stringify([scope.resource,scope.pointer,[...active].sort()]),known=variants.get(identity);
        if(known)return known;
        if(variants.size>=1024)throw new SourceError('limit.migration.discriminator','Discriminator specialization exceeds 1024 captured schema states',sourceOf(scope).range,'unsupported',sourceOf(scope));
        const owner=primary(scope),source=pristine.get(owner.resource)!;
        cloneBytes+=source.doc.node(owner.pointer).range[1]-source.doc.node(owner.pointer).range[0];
        if(cloneBytes>16*1024*1024)throw new SourceError('limit.migration.discriminator','Specialized schema source exceeds 16 MiB',sourceOf(scope).range,'unsupported',sourceOf(scope));
        const destination=reserve('selection',identity,scope);
        variants.set(identity,destination);
        const changed=entry.presentationChanges.length;
        admit(entry);entry.copy(source,owner.pointer,destination.pointer);
        if(entry.presentationChanges.length!==changed){entry.presentationChanges.splice(changed);presentation(scope);}
        // Child-instance references restart dispatch state. Same-instance refs
        // are replaced below by walk; no textual ref-looking payload is read.
        for(const reference of references){
            inspect();if(reference.resource!==scope.resource||!inside(reference.pointer,scope.pointer))continue;
            const at=mappedWithin({...reference,pointer:reference.pointer+'/$ref'},owner,destination);
            referenceTargets.set(key(at),primary({resource:reference.targetResource!,pointer:reference.targetPointer!}));
        }
        for(const occurrence of uris){
            inspect();if(occurrence.scope.resource!==scope.resource||!inside(occurrence.scope.pointer,scope.pointer))continue;
            const at=mappedWithin({resource:occurrence.scope.resource,pointer:occurrence.pointer},owner,destination);
            const wanted=resolveUri(occurrence.value,documentUriBase(graph,occurrence.scope)).href;
            if(sources.get(at.resource)!.doc.dataNode(at.pointer)?.value!==wanted)set(at,wanted);
        }
        walk(scope,owner,destination,active,0);
        return destination;
    };
    for(const base of bases){const owner=primary(base);walk(base,owner,owner,new Set(),0);}
    return {primaryTargets,referenceTargets};
}
