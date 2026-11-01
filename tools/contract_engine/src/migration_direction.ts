import {createHash} from 'node:crypto';
import {children} from './contexts';
import {escape,SourceError} from './document';
import {documentUriOccurrences} from './document_uris';
import {documentUriBase,pointerFragment,resolveUri,type GraphScope,type ReferenceGraph} from './reference_graph';
import {propertyAccess} from './schema_access';
import {DiscriminatorModels} from './discriminator_models';
import {MigrationSource,type MigrationLocation} from './migration_source';
import type {MigrationIssue} from './migration_schema';

type Direction='request'|'response';
type LegacyOwner=Readonly<{family:string;property:boolean;origin:GraphScope}>;
type Child=Readonly<{scope:GraphScope;property:boolean;sameInstance:boolean}>;
const key=(location:MigrationLocation)=>JSON.stringify([location.resource,location.pointer]);
const inside=(pointer:string,parent:string)=>pointer===parent||pointer.startsWith(parent+'/');
const address=(location:MigrationLocation)=>location.resource+pointerFragment(location.pointer);

type DiscriminatorBindings=Readonly<{models:ReadonlyMap<string,GraphScope>;unbound:readonly GraphScope[]}>;

function discriminatorBindings(graph:ReferenceGraph,scope:GraphScope,selection:DiscriminatorModels,
    inspect:()=>void):DiscriminatorBindings {
    const doc=graph.docs.get(scope.resource)!,value=doc.dataNode(scope.pointer)?.value;
    const models=new Map<string,GraphScope>(),unbound:GraphScope[]=[];
    if(!Array.isArray(value?.oneOf)&&!Array.isArray(value?.anyOf)){
        for(const [name,model]of selection.models(scope,false))models.set(name,model);
    }else{
        for(const keyword of ['oneOf','anyOf'])for(const index of doc.dataNode(scope.pointer+'/'+keyword)?.children.keys()??[]){
            inspect();
            const reference=graph.referenceAs(scope.resource,scope.pointer+'/'+keyword+'/'+index,'$ref','schema');
            if(reference?.resolution!=='resolved')continue;
            const model=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'schema');
            if(!model)throw new SourceError('migration.direction.discriminator','A composition choice has no captured Schema Object');
            const prefix='/components/schemas/';
            if(reference.targetResource===graph.root&&reference.targetPointer!.startsWith(prefix)&&
                !reference.targetPointer!.slice(prefix.length).includes('/'))
                models.set(reference.targetPointer!.slice(prefix.length).replace(/~1/g,'/').replace(/~0/g,'~'),model);
            else unbound.push(model);
        }
    }
    for(const reference of graph.references){
        inspect();
        if(reference.connection!=='discriminator'||reference.pointer!==scope.pointer+'/discriminator/mapping'||reference.resource!==scope.resource)continue;
        if(reference.resolution!=='resolved')throw new SourceError('migration.direction.discriminator','A discriminator mapping has no captured target');
        const model=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'schema');
        if(!model)throw new SourceError('migration.direction.discriminator','A discriminator mapping has no captured Schema Object');
        models.set(reference.keyword,model);
    }
    const covered=new Set([...models.values()].map(model=>key(selection.target(model)??model)));
    return {models,unbound:unbound.filter(model=>!covered.has(key(selection.target(model)??model)))};
}

/** Preserve the legacy occurrence's access assertions rather than assigning
 * one interpretation to a shared definition. Swagger 2.0 §6.4.18.1 excludes
 * read-only request properties; 3.0 §4.7.24.2 suppresses required by direction.
 * Original neutral definitions survive. Known consumers use explicit variants.
 * All copies and replacements belong to the existing CST/provenance owner. */
export function migrateDirectionalSchemas(original:ReferenceGraph,graph:ReferenceGraph,
    sources:Map<string,MigrationSource>,families:readonly string[],target:string,issue:MigrationIssue,
    createSchemaResource:()=>MigrationSource,contexts:readonly ReferenceGraph[]):void {
    const converting=new Set(families.filter(family=>family==='2.0'&&target==='3.0'||family==='3.0'&&['3.1','3.2'].includes(target)));
    if(!converting.size)return;
    const legacy=new Map<string,LegacyOwner>();
    for(const scope of original.scopesFor('schema')){
        if(!converting.has(scope.family))continue;
        const owner={family:scope.family,property:/\/properties\/[^/]+$/.test(scope.pointer),origin:scope};
        for(const [resource,source]of sources){
            const pointers=resource===scope.resource?source.origins.get(scope.pointer):source.foreignOrigins.get(scope.resource+'#'+scope.pointer);
            for(const pointer of pointers??[]){
                const id=key({resource,pointer}),prior=legacy.get(id);
                if(prior&&(prior.family!==owner.family||prior.property!==owner.property)){
                    issue(scope,'migration.direction.context','This converted schema has conflicting original access contexts; separate owners are required','implementation');
                    return;
                }
                legacy.set(id,owner);
            }
        }
    }
    const report=(scope:GraphScope,code:string,message:string)=>
        issue(legacy.get(key(scope))?.origin??scope,code,message,'implementation');
    const scopes=graph.scopesFor('schema');
    if(scopes.length>20000)throw new SourceError('limit.migration.direction','Directional mapping exceeds 20000 schema occurrences');
    const byId=new Map(scopes.map(scope=>[key(scope),scope]));
    let inspections=0;
    const descendants=new Map<string,Child[]>(),parents=new Map<string,Set<string>>();
    const connect=(child:GraphScope,parent:GraphScope)=>{
        const id=key(child),values=parents.get(id)??new Set<string>();values.add(key(parent));parents.set(id,values);
    };
    for(const scope of scopes){
        const nested:Child[]=[];
        const visit=(value:unknown,kind:string,pointer:string,keyword:string)=>{
            for(const [name,item,next]of children(value,kind,scope.family)){
                const at=pointer+'/'+escape(name),first=keyword||name;
                if(next==='schema'){
                    const child=graph.scopeAs(scope.resource,at,'schema');
                    if(child){nested.push({scope:child,property:first==='properties',sameInstance:['allOf','anyOf','oneOf','not','if','then','else'].includes(first)});connect(child,scope);}
                }else if(next==='schema-map'||next==='schema-array')visit(item,next,at,first);
            }
        };
        visit(graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value,'schema',scope.pointer,'');
        descendants.set(key(scope),nested);
        const reference=graph.referenceAs(scope.resource,scope.pointer,'$ref','schema');
        if(reference?.resolution==='resolved'){
            const target=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'schema');
            if(target)connect(target,scope);
        }
    }
    // Explicit mappings and entry-component names are separate from schema
    // assertions. Preserve their targets when a composition gets copied.
    const selections=new Map<ReferenceGraph,DiscriminatorModels>();
    const selection=(context:ReferenceGraph)=>{
        let selected=selections.get(context);
        if(!selected){selected=new DiscriminatorModels(context,'/components/schemas');selections.set(context,selected);}
        return selected;
    };
    const bindings=new Map<string,ReadonlyMap<string,GraphScope>>(),unbound=new Map<string,readonly GraphScope[]>();
    for(const scope of scopes){
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        if(!value?.discriminator||typeof value.discriminator!=='object')continue;
        const selected=discriminatorBindings(graph,scope,selection(graph),inspect);
        bindings.set(key(scope),selected.models);unbound.set(key(scope),selected.unbound);
        for(const model of selected.models.values())connect(model,scope);
    }
    const affected=new Set<string>(),pending:string[]=[];
    for(const scope of scopes){
        const owner=legacy.get(key(scope)),value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        if(!owner||!value||typeof value!=='object'||Array.isArray(value))continue;
        const changes=owner.family==='2.0'?value.readOnly===true:
            Array.isArray(value.required)&&value.required.some((name:unknown)=>typeof name==='string'&&
                Object.values(propertyAccess(graph,scope,name)).some(flag=>flag));
        if(changes){affected.add(key(scope));pending.push(key(scope));}
    }
    while(pending.length){
        const current=pending.pop()!;
        // Replacing an occurrence also relocates its nested schema targets.
        // Include both directions of ownership before copying any references.
        const connected=[...(parents.get(current)??[]),...(descendants.get(current)??[]).map(child=>key(child.scope))];
        for(const id of connected)if(!affected.has(id)){affected.add(id);pending.push(id);}
    }
    if(!affected.size)return;
    const signature=(models:ReadonlyMap<string,GraphScope>)=>JSON.stringify([...models].map(([name,model])=>[name,model.resource,model.pointer]).sort());
    for(const scope of scopes)if(affected.has(key(scope))&&bindings.has(key(scope))){
        if(unbound.get(key(scope))?.length){
            report(unbound.get(key(scope))![0],'migration.direction.discriminator-name',
                'This external or nested discriminator choice has no captured implicit component name or explicit wire mapping');
            return;
        }
        for(const context of contexts){
            if(context.root===graph.root)continue;
            const shared=context.scopeAs(scope.resource,scope.pointer,'schema');if(!shared)continue;
            const selected=discriminatorBindings(context,shared,selection(context),inspect);
            if(selected.unbound.length||signature(selected.models)!==signature(bindings.get(key(scope))!)){
                report(scope,'migration.direction.discriminator-context',
                    'Captured entry namespaces select different discriminator models; separate entry-owned directional definitions are required');
                return;
            }
        }
    }
    const uris=[...documentUriOccurrences(graph)];
    function literalOwner(location:MigrationLocation):GraphScope|undefined {
        if(graph.literalContainer(location.resource,location.pointer)===undefined)return;
        let pointer=location.pointer;
        while(true){
            inspect();
            const id=key({resource:location.resource,pointer});
            if(affected.has(id))return byId.get(id);
            if(!pointer)return;pointer=pointer.slice(0,pointer.lastIndexOf('/'));
        }
    }
    for(const location of [...graph.references,...uris.map(uri=>({resource:uri.scope.resource,pointer:uri.pointer}))]){
        const owner=literalOwner(location);
        if(owner){report(owner,'migration.direction.shared-owner','This schema contains independently interpreted literal URI/reference data; separate ownership is required');return;}
    }
    for(const scope of scopes)if(affected.has(key(scope))){
        if(graph.literalContainer(scope.resource,scope.pointer)!==undefined||graph.hasOverlappingScope(scope.resource,scope.pointer)){
            report(scope,'migration.direction.shared-owner','This directional schema also owns literal or independently interpreted content; separate ownership is required');
            return;
        }
        sources.get(scope.resource)!.own(scope.pointer,true,true);
    }
    const pristine=new Map([...sources].map(([resource,source])=>[resource,source.fork()]));
    const entry=sources.get(graph.root)!;
    let registry:MigrationSource|undefined;
    const variants=new Map<string,MigrationLocation>();
    const neutralVariants=new Map<string,MigrationLocation>();
    const headerVariants=new Map<string,MigrationLocation>();
    const reserved=new Set<string>();
    const swagger=target==='3.0'&&converting.has('2.0');
    let edits=0,work=0,bytes=0;
    const admit=(source:MigrationSource)=>{
        if(++edits>4096||(work+=source.doc.text.length*2)>128*1024*1024)
            throw new SourceError('limit.migration.direction','Directional specialization exceeds its bounded CST edit work');
    };
    const set=(location:MigrationLocation,value:unknown)=>{const source=sources.get(location.resource)!;admit(source);source.set(location.pointer,value);};
    const replace=(location:MigrationLocation,value:unknown)=>{
        const source=sources.get(location.resource)!;
        // Retire only replaced descendants. Array positions and the selected
        // occurrence itself retain their identity and cannot shift a sibling.
        for(const values of source.originSets())for(const pointer of [...values])
            if(pointer!==location.pointer&&inside(pointer,location.pointer))values.delete(pointer);
        set(location,value);
    };
    function reserve(label:string,identity:string,container='schemas'):MigrationLocation {
        if(variants.size+neutralVariants.size+headerVariants.size>=1024)throw new SourceError('limit.migration.direction','Directional specialization exceeds 1024 states');
        const stem='_migrated_'+label+'_'+createHash('sha256').update(identity).digest('hex').slice(0,24);
        let name=stem,index=0;
        const source=container==='schemas'?(registry??=createSchemaResource()):entry;
        const prefix=container==='schemas'?'':'/components/'+container;
        while(source.doc.nodes.has(prefix+'/'+name)||reserved.has(name))name=stem+'_'+(++index);
        reserved.add(name);
        return {resource:source.doc.id,pointer:prefix+'/'+name};
    }
    function copy(scope:GraphScope,destination:MigrationLocation):void {
        const source=pristine.get(scope.resource)!,node=source.doc.node(scope.pointer);
        if((bytes+=node.range[1]-node.range[0])>16*1024*1024)
            throw new SourceError('limit.migration.direction','Directional schema copies exceed 16 MiB');
        const output=sources.get(destination.resource)!;
        admit(output);output.copy(source,scope.pointer,destination.pointer,true);
        for(const uri of uris){
            inspect();
            if(uri.scope.resource===scope.resource&&inside(uri.pointer,scope.pointer)&&graph.literalContainer(uri.scope.resource,uri.pointer)===undefined)
                set({resource:destination.resource,pointer:destination.pointer+uri.pointer.slice(scope.pointer.length)},resolveUri(uri.value,documentUriBase(graph,uri.scope)).href);
        }
        for(const reference of graph.references){
            inspect();
            if(!['$ref','$dynamicRef','operationRef'].includes(reference.keyword)||reference.resolution!=='resolved'||
                reference.resource!==scope.resource||!inside(reference.pointer,scope.pointer))continue;
            if(graph.literalContainer(reference.resource,reference.pointer)!==undefined)continue;
            set({resource:destination.resource,pointer:destination.pointer+reference.pointer.slice(scope.pointer.length)+'/'+escape(reference.keyword)},
                address({resource:reference.targetResource!,pointer:reference.targetPointer!}));
        }
    }
    function inspect():void {
        if(++inspections>2000000)throw new SourceError('limit.migration.direction','Directional reference and URI inspection exceeds its bounded work');
    }
    function neutral(scope:GraphScope,depth=0):MigrationLocation {
        const identity=key(scope),known=neutralVariants.get(identity);
        if(known)return known;
        if(depth>128)throw new SourceError('limit.migration.direction','Neutral schema reference inspection exceeds 128 levels');
        const destination=reserve('neutral',identity);neutralVariants.set(identity,destination);
        copy(scope,destination);
        for(const reference of graph.references){
            inspect();
            if(reference.keyword!=='$ref'||reference.kind!=='schema'||reference.resolution!=='resolved'||
                reference.resource!==scope.resource||!inside(reference.pointer,scope.pointer))continue;
            if(graph.literalContainer(reference.resource,reference.pointer)!==undefined)continue;
            const reached=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'schema');
            if(!reached)throw new SourceError('migration.direction.reference','A neutral schema reference has no captured target');
            const target=affected.has(key(reached))?neutral(reached,depth+1):reached;
            set({resource:destination.resource,pointer:destination.pointer+reference.pointer.slice(scope.pointer.length)+'/$ref'},address(target));
        }
        for(const nested of scopes)if(nested.resource===scope.resource&&inside(nested.pointer,scope.pointer)&&bindings.has(key(nested)))
            rewriteBindings(nested,{resource:destination.resource,pointer:destination.pointer+nested.pointer.slice(scope.pointer.length)},undefined,depth);
        return destination;
    }
    function rewriteBindings(scope:GraphScope,location:MigrationLocation,direction:Direction|undefined,depth:number):void {
        for(const [name,model]of bindings.get(key(scope))??[]){
            const selected=affected.has(key(model))?(direction?variant(model,direction,false,depth+1):neutral(model,depth+1)):model;
            set({...location,pointer:location.pointer+'/discriminator/mapping/'+escape(name)},address(selected));
        }
        const fallback=graph.references.find(reference=>reference.connection==='discriminator'&&reference.resource===scope.resource&&
            reference.pointer===scope.pointer+'/discriminator'&&reference.keyword==='defaultMapping');
        if(fallback?.resolution==='resolved'){
            const model=graph.scopeAs(fallback.targetResource!,fallback.targetPointer!,'schema');
            if(!model)throw new SourceError('migration.direction.discriminator','The default mapping has no captured Schema Object');
            const selected=affected.has(key(model))?(direction?variant(model,direction,false,depth+1):neutral(model,depth+1)):model;
            set({...location,pointer:location.pointer+'/discriminator/defaultMapping'},address(selected));
        }
    }
    function variant(scope:GraphScope,direction:Direction,property:boolean,depth=0):MigrationLocation {
        const identity=JSON.stringify([key(scope),direction,property]),known=variants.get(identity);
        if(known)return known;
        if(depth>128)throw new SourceError('limit.migration.direction','Directional schema references exceed 128 levels');
        const destination=reserve(direction,identity);
        variants.set(identity,destination);
        let assertions=destination;
        if(swagger){
            // Keep neutral examples/defaults associated with their unchanged
            // constraints. The second branch adds directional assertions only.
            set(destination,{allOf:[{$ref:address(neutral(scope))}]});
            assertions={...destination,pointer:destination.pointer+'/allOf/1'};
        }
        copy(scope,assertions);
        if(swagger)sources.get(destination.resource)!.associate(pristine.get(scope.resource)!,scope.pointer,destination.pointer);
        walk(scope,assertions,direction,property,depth);
        sources.get(destination.resource)!.presentationChanges.push(destination.pointer);
        return destination;
    }
    function walk(scope:GraphScope,location:MigrationLocation,direction:Direction,property:boolean,depth:number):void {
        if(depth>128)throw new SourceError('limit.migration.direction','Directional schema traversal exceeds 128 levels');
        const source=sources.get(location.resource)!,value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        if(!value||typeof value!=='object'||Array.isArray(value))return;
        const owner=legacy.get(key(scope));
        if(owner?.family==='2.0'&&direction==='request'&&value.readOnly===true&&(property||owner.property)){
            // Other annotations and their original associations remain in the
            // neutral branch; only this generated assertion is unsatisfiable.
            replace(location,{not:{}});return;
        }
        if(swagger){
            for(const annotation of ['example','examples','default','readOnly'])if(source.doc.nodes.has(location.pointer+'/'+annotation)){
                admit(source);source.remove(location.pointer+'/'+annotation,true,true,true);
            }
        }
        const reference=graph.referenceAs(scope.resource,scope.pointer,'$ref','schema');
        if(reference?.resolution==='resolved'){
            const reached=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'schema');
            if(!reached)throw new SourceError('migration.direction.reference','A directional schema reference has no captured target');
            set({...location,pointer:location.pointer+'/$ref'},affected.has(key(reached))?
                address(variant(reached,direction,property,depth+1)):address(reached));
        }
        rewriteBindings(scope,location,direction,depth);
        const at=location.pointer;
        if(owner?.family==='3.0'&&Array.isArray(value.required)){
            const omitted=value.required.map((name:unknown,index:number)=>({name,index})).filter(({name})=>{
                if(typeof name!=='string')return false;
                const access=propertyAccess(graph,scope,name);
                return direction==='request'?access.readOnly:access.writeOnly;
            });
            for(const {index}of omitted.sort((left,right)=>right.index-left.index)){
                admit(source);source.remove(at+'/required/'+index,true,true,true);
            }
            if(omitted.length&&source.doc.node(at+'/required').children.size===0){admit(source);source.remove(at+'/required',true,true,true);}
        }
        for(const child of descendants.get(key(scope))??[]){
            const pointer=at+child.scope.pointer.slice(scope.pointer.length);
            walk(child.scope,{resource:location.resource,pointer},direction,child.property||child.sameInstance&&property,depth+1);
        }
    }
    function directions(scope:GraphScope,seen=new Set<string>(),followHeaders=true):Set<Direction> {
        const identity=key(scope);if(seen.has(identity))return new Set<Direction>();
        if(seen.size>=128)throw new SourceError('limit.migration.direction','Directional consumer inspection exceeds 128 references');
        const visited=new Set(seen).add(identity);
        let pointer=scope.pointer;let header:GraphScope|undefined;let encoding=false;
        while(true){
            if(graph.scopeAs(scope.resource,pointer,'response'))return new Set<Direction>(['response']);
            if(graph.scopeAs(scope.resource,pointer,'request-body')||graph.scopeAs(scope.resource,pointer,'parameter'))return new Set<Direction>(['request']);
            encoding||=graph.scopeAs(scope.resource,pointer,'encoding')!==undefined;
            header??=graph.scopeAs(scope.resource,pointer,'header');
            if(!pointer)break;pointer=pointer.slice(0,pointer.lastIndexOf('/'));
        }
        if(encoding)return new Set<Direction>(['request']);
        if(!followHeaders)return new Set<Direction>();
        const result=new Set<Direction>();
        if(header)for(const reference of graph.references)if(reference.kind==='header'&&reference.resolution==='resolved'&&
            reference.targetResource===header.resource&&reference.targetPointer===header.pointer)
            for(const direction of directions(reference,visited))result.add(direction);
        return result;
    }
    function containingHeader(scope:GraphScope):GraphScope|undefined {
        let pointer=scope.pointer;
        while(true){
            const header=graph.scopeAs(scope.resource,pointer,'header');if(header)return header;
            if(!pointer)return;pointer=pointer.slice(0,pointer.lastIndexOf('/'));
        }
    }
    const schemaRoots=scopes.filter(scope=>{
        let pointer=scope.pointer;
        while(pointer){pointer=pointer.slice(0,pointer.lastIndexOf('/'));if(byId.has(key({resource:scope.resource,pointer})))return false;}
        return true;
    });
    const headerSchemas=new Map<string,GraphScope[]>(),affectedHeaders=new Set<string>();
    for(const scope of schemaRoots)if(affected.has(key(scope))){
        const header=containingHeader(scope);if(!header)continue;
        const id=key(header),owned=headerSchemas.get(id)??[];owned.push(scope);headerSchemas.set(id,owned);affectedHeaders.add(id);
    }
    const headerReferences=graph.references.filter(reference=>reference.kind==='header'&&reference.resolution==='resolved'&&reference.keyword==='$ref');
    let changed=true;
    while(changed){
        changed=false;
        for(const reference of headerReferences)if(affectedHeaders.has(key({resource:reference.targetResource!,pointer:reference.targetPointer!}))&&!affectedHeaders.has(key(reference))){affectedHeaders.add(key(reference));changed=true;}
    }
    function headerVariant(scope:GraphScope,direction:Direction,depth=0):MigrationLocation {
        const identity=JSON.stringify([key(scope),direction]),known=headerVariants.get(identity);
        if(known)return known;
        if(depth>128||headerVariants.size>=512)throw new SourceError('limit.migration.direction','Directional Header specialization exceeds its bounded state/depth');
        const destination=reserve('header_'+direction,identity,'headers');headerVariants.set(identity,destination);copy(scope,destination);
        const reference=graph.referenceAs(scope.resource,scope.pointer,'$ref','header');
        if(reference?.resolution==='resolved'){
            const reached=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'header');
            if(!reached)throw new SourceError('migration.direction.header','The captured Header reference has no typed target');
            set({...destination,pointer:destination.pointer+'/$ref'},address(headerVariant(reached,direction,depth+1)));
        }else{
            for(const schema of headerSchemas.get(key(scope))??[]){
                const at={resource:destination.resource,pointer:destination.pointer+schema.pointer.slice(scope.pointer.length)};
                replace(at,{$ref:address(variant(schema,direction,false))});
            }
        }
        sources.get(destination.resource)!.presentationChanges.push(destination.pointer);
        return destination;
    }
    // A reusable Header can occur in both request encoding and responses. Split
    // its reference graph as well, so one physical schema is never assigned two
    // directions and an alias chain retains its own original definition.
    for(const reference of headerReferences){
        if(!affectedHeaders.has(key({resource:reference.targetResource!,pointer:reference.targetPointer!})))continue;
        const roles=directions(reference,new Set<string>(),false);if(roles.size!==1)continue;
        if(graph.literalContainer(reference.resource,reference.pointer)!==undefined||graph.hasOverlappingScope(reference.resource,reference.pointer)){
            issue(reference,'migration.direction.shared-owner','This Header reference also owns literal or independently interpreted content; separate ownership is required','implementation');return;
        }
        const reached=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'header');
        if(!reached)throw new SourceError('migration.direction.header','The selected Header reference has no captured target');
        set({resource:reference.resource,pointer:reference.pointer+'/$ref'},address(headerVariant(reached,[...roles][0])));
    }
    // Definitions that remain neutral must not keep links into an inline
    // occurrence whose descendants are about to be replaced. Their own stable
    // copies retain the original schema and exact payload associations.
    for(const reference of graph.references){
        if(reference.keyword!=='$ref'||reference.kind!=='schema'||reference.resolution!=='resolved')continue;
        const reached=graph.scopeAs(reference.targetResource!,reference.targetPointer!,'schema');
        if(reached&&affected.has(key(reached)))set({resource:reference.resource,pointer:reference.pointer+'/$ref'},address(neutral(reached)));
    }
    for(const scope of scopes)if(affected.has(key(scope))&&bindings.has(key(scope)))rewriteBindings(scope,scope,undefined,0);
    for(const scope of schemaRoots){
        if(!affected.has(key(scope)))continue;
        const header=containingHeader(scope);
        if(header&&affectedHeaders.has(key(header))&&!directions(scope,new Set<string>(),false).size)continue;
        const roles=directions(scope);
        if(roles.size>1){
            if(header&&affectedHeaders.has(key(header)))continue;
            report(scope,'migration.direction.shared-owner','This request/response container needs separate occurrence-owned definitions before its schema can be specialized');return;
        }
        if(!roles.size)continue;
        if(graph.literalContainer(scope.resource,scope.pointer)!==undefined||graph.hasOverlappingScope(scope.resource,scope.pointer)){
            report(scope,'migration.direction.shared-owner','This directional occurrence also owns literal or independently interpreted content; separate ownership is required');return;
        }
        const direction=[...roles][0];
        const selected=variant(scope,direction,false);
        replace(scope,{$ref:address(selected)});
    }
}
