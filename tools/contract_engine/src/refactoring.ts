import { createHash } from 'node:crypto';
import { createGraph, propose, Resource } from './engine';
import { escape, segments, SourceError } from './document';
import { GraphReference, resolveUri, pointerFragment } from './reference_graph';
import {securityConfigurationCopies,type SecurityBindingChange} from './security_configuration';
import {componentNamePolicy,permitsMemberName,responseStatusNamePolicy,schemaDefinitionNamePolicy} from './member_names';

/** Semantic plans operate on each entry description's namespace separately.
 * Physical edits are coalesced only after every occurrence agrees. There is no
 * resource acquisition here, and no string scan of examples or extensions.
 */
export function planRename(input: any) {
    const resources = input.resources as Resource[];
    if (!Array.isArray(input.contexts) || !input.contexts.length || input.contexts.length > 128)
        throw new SourceError('refactor.context', 'Choose the configured roots whose usages are being reviewed');
    const source = resources.find(r => r.id === input.target?.resource);
    if (!source || source.generation !== input.target.generation)
        throw new SourceError('edit.stale', 'The captured definition changed');
    const parts = segments(input.target.pointer);
    const property = input.property === true;
    const response = input.response === true;
    const schemaDefinition = input.schemaDefinition === true;
    if ([property,response,schemaDefinition].filter(Boolean).length>1)
        throw new SourceError('refactor.context','Choose one kind of authored binding');
    if (typeof input.name !== 'string' || input.name.length > 4096 || (property ? parts.length < 2 || parts.at(-2) !== 'properties' : response ? parts.at(-2)!=='responses' : schemaDefinition ? parts.at(-2)!=='$defs' : !(parts.length===2&&['definitions','parameters','responses','securityDefinitions'].includes(parts[0]) || parts.length===3&&parts[0]==='components'&&['schemas','parameters','responses','headers','requestBodies','examples','links','callbacks','pathItems','securitySchemes','mediaTypes'].includes(parts[1]))))
        throw new SourceError('refactor.name', 'Choose a component definition and a legal component name');
    const oldName = parts.at(-1)!, oldPointer = input.target.pointer;
    const nextPointer = '/' + parts.slice(0,-1).map(escape).join('/') + '/' + escape(input.name);
    const moves = [{resource:source.id,from:oldPointer,to:nextPointer}];
    const transition = (resource: string, pointer: string) => {
        let next=pointer;
        for(const move of [...moves].sort((a,b)=>b.from.length-a.from.length))if(move.resource===resource&&(next===move.from||next?.startsWith(move.from+'/')))next=move.to+next.slice(move.from.length);
        return next;
    };
    const graphs:({context:any}&ReturnType<typeof createGraph>)[] = input.contexts.map((context: any) => {
        if (!Array.isArray(context.resources) || !context.resources.includes(context.root) || context.resources.some((id: string) => !resources.some(r => r.id === id)))
            throw new SourceError('refactor.context', 'A root context contains an unavailable resource');
        return {context, ...createGraph({root: context.root, resources: resources.filter(r => context.resources.includes(r.id))})};
    });
    const definition = graphs.map((g: any) => g.docs.get(source.id)?.nodes.get(oldPointer)).find(Boolean);
    if(schemaDefinition&&(!definition||!definition.keyRange||definition.shared||definition.keyShared))
        throw new SourceError('refactor.definition','The definition needs an unambiguous physical key, not an alias or reference projection');
    const owners=graphs.flatMap(({graph})=>{
        const scope=graph.scopes.get(source.id+'#'+oldPointer);
        return scope?[{graph,scope}]:[];
    });
    if(schemaDefinition&&(!owners.length||owners.some(({graph,scope})=>!schemaDefinitionNamePolicy(graph,scope))))
        throw new SourceError('refactor.schema-definition.context','The captured roots must establish a $defs binding in a supported schema dialect',definition.range,undefined,{resource:source.id,pointer:oldPointer,range:definition.range});
    if(!property&&(!owners.length||owners.some(({graph,scope})=>!permitsMemberName(schemaDefinition?schemaDefinitionNamePolicy(graph,scope):response?responseStatusNamePolicy(scope.family):componentNamePolicy(scope.family),input.name))))
        throw new SourceError('refactor.name','Choose a name permitted by every owning specification family',input.target.range,undefined,{resource:source.id,pointer:oldPointer,range:input.target.range});
    if(!property&&!response&&!schemaDefinition&&parts.length===2&&!graphs.some((g:any)=>g.graph.specifications.get(source.id)?.family==='2.0'))throw new SourceError('refactor.definition','Choose a native Swagger reusable definition');
    if (!definition || !definition.keyRange || definition.shared || definition.keyShared)
        throw new SourceError('refactor.definition', 'The definition needs an unambiguous physical key, not an alias or reference projection');
    if (!graphs.some((g: any) => g.graph.scopes.has(source.id + '#' + oldPointer)))
        throw new SourceError('refactor.definition', 'This preserved content is not a component family in the selected specification');
    const ownerPointer = parts.length === 2 ? '' : '/' + parts.slice(0,-2).map(escape).join('/');
    if (property && !graphs.some((g:any)=>g.graph.scopes.get(source.id+'#'+ownerPointer)?.kind==='schema' && g.graph.scopes.get(source.id+'#'+oldPointer)?.kind==='schema'))
        throw new SourceError('refactor.property.context','Choose a property in an authored Schema Object');
    if(response&&!graphs.some((g:any)=>g.graph.scopes.get(source.id+'#'+oldPointer)?.kind==='response'&&g.graph.scopes.get(source.id+'#'+ownerPointer)?.kind==='operation'))throw new SourceError('refactor.response.context','Choose an authored operation response');
    if ((property||schemaDefinition) && input.name !== oldName && graphs.some((g:any)=>g.graph.literalContainer(source.id,oldPointer)!==undefined))
        throw new SourceError('refactor.literal.ownership','This property also belongs to literal data; a semantic rename cannot preserve both source meanings',definition.keyRange);
    if (input.target.range && JSON.stringify(definition.range) !== JSON.stringify(input.target.range) || input.target.expected !== undefined && source.text.slice(definition.range[0], definition.range[1]) !== input.target.expected)
        throw new SourceError('edit.stale', 'The captured definition occurrence changed');
    for (const g of graphs) {
        for (const doc of g.docs.values()) if (doc.issues.length) throw new SourceError('refactor.syntax', 'Repair ambiguous source syntax before reviewing semantic consumers');
        if (g.graph.issues.length) throw new SourceError('refactor.graph', 'Resolve unavailable, invalid or ambiguous semantic connections before renaming a component');
        const doc = g.docs.get(source.id);
        if (nextPointer !== oldPointer && doc?.nodes.has(nextPointer)) throw new SourceError('edit.collision', 'The destination component already exists');
    }
    const actions = new Map<string, Map<string, any>>(), usages = new Map<string, any>();
    const warnings = new Set<string>();
    const add = (resource: string, pointer: string, action: any, ref?: GraphReference, root?: string) => {
        const key = action.kind + ':' + pointer;
        const edits = actions.get(resource) ?? new Map<string, any>();
        const previous = edits.get(key);
        if (previous && JSON.stringify(previous) !== JSON.stringify(action)) throw new SourceError('refactor.context.ambiguous', 'One physical occurrence requires different repairs in different roots');
        edits.set(key, action); actions.set(resource, edits);
        if (ref) {
            const id = resource + '#' + pointer;
            const usage = usages.get(id) ?? {resource, pointer, value: ref.value, connection: ref.connection ?? ref.keyword, roots: [], target: {resource: ref.targetResource, pointer: ref.targetPointer}};
            if (!usage.roots.includes(root)) usage.roots.push(root);
            usages.set(id, usage);
        }
    };
    if (nextPointer === oldPointer) return {version: 1, snapshot: input.snapshot, edits: [], usages: [], from: input.target, to: {...input.target, pointer: nextPointer}, ...(schemaDefinition?{kind:'schema-definition-rename'}:{}), checkedRoots: input.contexts.map((c: any) => c.root)};
    if (property) {
        const doc=graphs.find((g:any)=>g.docs.has(source.id))!.docs.get(source.id)!;
        const constraint=(pointer:string)=>{
            const node=doc.dataNode(pointer);
            if(node&&(node.shared||node.pointer!==pointer))throw new SourceError('refactor.property.shared','An aliased structural relationship needs explicit source ownership');
            return node;
        };
        const renameKey=(pointer:string)=>{
            const node=constraint(pointer);if(!node)return;
            const tokens=segments(pointer),next='/'+[...tokens.slice(0,-1),input.name].map(escape).join('/');
            if(doc.nodes.has(next))throw new SourceError('edit.collision','A structural property relationship already uses the destination name');
            if(!moves.some(m=>m.from===pointer))moves.push({resource:source.id,from:pointer,to:next});
        };
        const renameList=(list:any)=>{
            if(list)list=constraint(list.pointer);
            if(list?.kind!=='array')return;
            const children=[...list.children.values()] as any[];
            if(children.some(child=>child.value===oldName)&&children.some(child=>child.value===input.name))throw new SourceError('edit.collision','A same-instance name list already uses the destination name');
            for(const child of children){constraint(child.pointer);if(child.value===oldName)add(source.id,child.pointer,{kind:'set',pointer:child.pointer,value:input.name});}
        };
        const sameInstance=(pointer:string,depth=0)=>{
            if(depth>128)throw new SourceError('limit.refactor','Property relationship nesting exceeds its bound');
            const n=doc.dataNode(pointer);
            if(!n||n.shared||n.pointer!==pointer)throw new SourceError('refactor.property.shared','An aliased same-instance constraint needs explicit source ownership');
            if(!n.value||typeof n.value!=='object'||Array.isArray(n.value))return;
            if(n.value.$ref||n.value.$dynamicRef)throw new SourceError('refactor.property.reference','A same-instance reference may constrain this wire name; explicitly resolve its shared ownership before renaming');
            if(doc.dataNode(pointer+'/properties/'+escape(input.name)))throw new SourceError('edit.collision','A same-instance property already uses the destination name');
            renameKey(pointer+'/properties/'+escape(oldName));
            renameList(constraint(pointer+'/required'));
            const dependencies=constraint(pointer+'/dependentRequired');
            if(dependencies?.kind==='object')for(const [name,list]of dependencies.children){
                if(name===oldName)renameKey(list.pointer);
                renameList(list);
            }
            constraint(pointer+'/discriminator');
            const discriminator=constraint(pointer+(graphs.some((g:any)=>g.graph.scope(source.id,pointer).family==='2.0')?'/discriminator':'/discriminator/propertyName'));
            if(discriminator?.value===oldName)add(source.id,discriminator.pointer,{kind:'set',pointer:discriminator.pointer,value:input.name});
            for(const keyword of ['propertyNames','patternProperties'])if(n.children.has(keyword))warnings.add(pointer+'/'+keyword);
            for(const keyword of ['allOf','anyOf','oneOf']){
                const list=constraint(pointer+'/'+keyword);if(list?.kind==='array')for(const child of list.children.values())sameInstance(child.pointer,depth+1);
            }
            for(const keyword of ['not','if','then','else'])if(n.children.has(keyword))sameInstance(n.children.get(keyword)!.pointer,depth+1);
            const dependent=constraint(pointer+'/dependentSchemas');
            if(dependent?.kind==='object')for(const [name,child]of dependent.children){if(name===oldName)renameKey(child.pointer);sameInstance(child.pointer,depth+1);}
        };
        // Climb only inline applicators that evaluate the very same instance.
        // Child properties/items and unapplied $defs are separate rename scopes;
        // URI resource boundaries alone do not create a different instance.
        let instanceOwner=ownerPointer;
        for(let depth=0;depth<128;depth++) {
            const path=segments(instanceOwner),last=path.at(-1),keyword=path.at(-2);
            const count=['allOf','anyOf','oneOf'].includes(keyword??'')&&/^\d+$/.test(last??'')||keyword==='dependentSchemas'?2:['not','if','then','else'].includes(last??'')?1:0;
            if(!count)break;
            const parent=path.slice(0,-count),pointer=parent.length?'/'+parent.map(escape).join('/'):'';
            if(!graphs.some((g:any)=>g.graph.scopes.get(source.id+'#'+pointer)?.kind==='schema'))break;
            instanceOwner=pointer;
        }
        sameInstance(instanceOwner);
    }
    const affected = (ref: GraphReference) => typeof ref.targetPointer==='string'&&transition(ref.targetResource!,ref.targetPointer)!==ref.targetPointer;
    const repaired = (ref: GraphReference, graph: any) => {
        if (!property && ref.connection === 'security' && ref.value === oldName) return input.name;
        if (!property && ref.connection === 'discriminator' && ref.value === oldName) return input.name;
        const uri = resolveUri(ref.value, ref.base), fragment = decodeURIComponent(uri.hash.slice(1));
        // Anchors and declared resource identifiers survive a key rename.
        if (!fragment.startsWith('/')) return ref.value;
        uri.hash = '';
        const identity = graph.identities.get(uri.href);
        if (identity?.length !== 1) throw new SourceError('refactor.identity', 'The reference resource identity is ambiguous');
        const basePointer = transition(identity[0].resource, identity[0].pointer);
        const target = transition(ref.targetResource!, ref.targetPointer!);
        if (target !== basePointer && !target.startsWith(basePointer + '/')) throw new SourceError('refactor.identity', 'The moved definition escapes the referenced schema resource');
        const pointer = target.slice(basePointer.length);
        if (pointer === fragment) return ref.value;
        return ref.value.slice(0, ref.value.indexOf('#')) + pointerFragment(pointer);
    };
    for (const {context, graph, docs} of graphs) {
        for (const ref of graph.references) {
            if (ref.resolution !== 'resolved' || !affected(ref)) continue;
            const pointer = ref.pointer + '/' + escape(ref.keyword), next = repaired(ref, graph);
            if (next === ref.value) {
                const id = ref.resource + '#' + pointer;
                usages.set(id, {...usages.get(id), resource: ref.resource, pointer, value: ref.value, connection: ref.connection ?? ref.keyword, unchangedIdentity: true, roots: [...new Set([...(usages.get(id)?.roots ?? []), context.root])], target: {resource: ref.targetResource, pointer: ref.targetPointer}});
                continue;
            }
            const doc = docs.get(ref.resource)!;
            if (graph.literalContainer(ref.resource,pointer)!==undefined)
                throw new SourceError('refactor.literal.ownership','A required reference repair also changes literal data; resolve the dual source ownership explicitly before renaming',doc.dataNode(pointer)?.range);
            doc.assertSafe(pointer);
            if (ref.connection === 'security') add(ref.resource, pointer, {kind: 'rename', pointer, name: next}, ref, context.root);
            else add(ref.resource, pointer, {kind: 'set', pointer, value: next}, ref, context.root);
        }
        if(!property&&!schemaDefinition&&parts[0]==='definitions')for(const scope of graph.scopes.values()) {
            if(scope.family!=='2.0'||scope.kind!=='schema'||typeof docs.get(scope.resource)!.dataNode(scope.pointer)?.value?.discriminator!=='string')continue;
            const inherits=(at:string,seen=new Set<string>()):boolean=>{
                if(at===scope.pointer&&source.id===scope.resource)return true;
                if(seen.has(at)||seen.size>=128)return false;seen.add(at);
                const node=docs.get(source.id)?.dataNode(at);
                return (node?.value?.allOf??[]).some((_:unknown,index:number)=>{const ref=graph.references.find((r:GraphReference)=>r.resource===source.id&&r.pointer===at+'/allOf/'+index&&r.keyword==='$ref');return ref?.targetResource===scope.resource&&ref.targetPointer===scope.pointer||ref?.targetResource===source.id&&inherits(ref.targetPointer!,seen);});
            };
            if(inherits(oldPointer))throw new SourceError('refactor.discriminator.wire-name','Renaming this Swagger model changes its implicit discriminator wire value; the family has no faithful explicit mapping',definition.keyRange);
        }
        // A renamed component must not silently change an implicit discriminator
        // wire value. Preserve it with an explicit, graph-proven mapping.
        if (!property && !schemaDefinition && parts[1] === 'schemas') for (const scope of graph.scopes.values()) {
            if (scope.kind !== 'schema') continue;
            const node = docs.get(scope.resource)!.dataNode(scope.pointer)!, discriminator = node.value?.discriminator;
            if (!discriminator || typeof discriminator.propertyName !== 'string') continue;
            for (const keyword of ['oneOf', 'anyOf']) {
                const children = node.value[keyword];
                if (!Array.isArray(children)) continue;
                for (let i = 0; i < children.length; i++) {
                    const ref = graph.references.find((r: GraphReference) => r.resource === scope.resource && r.pointer === scope.pointer + '/' + keyword + '/' + i && r.keyword === '$ref');
                    if (!ref || !affected(ref) || ref.targetPointer !== oldPointer) continue;
                    if (discriminator.mapping && Object.hasOwn(discriminator.mapping, oldName)) continue;
                    const pointer = scope.pointer + '/discriminator/mapping/' + escape(oldName);
                    add(scope.resource, pointer, {kind: 'create', pointer, value: repaired(ref, graph)}, ref, context.root);
                }
            }
        }
        if (!property && parts[1] === 'schemas') for (const ref of graph.references) {
            if (ref.resource !== source.id || !ref.pointer.startsWith(oldPointer + '/allOf/') || ref.keyword !== '$ref' || ref.resolution !== 'resolved') continue;
            const parent = docs.get(ref.targetResource!)!.dataNode(ref.targetPointer!)!.value;
            if (!parent?.discriminator || typeof parent.discriminator.propertyName !== 'string' || parent.discriminator.mapping && Object.hasOwn(parent.discriminator.mapping, oldName)) continue;
            const pointer = ref.targetPointer + '/discriminator/mapping/' + escape(oldName);
            const rootDefinition = graph.docs.get(context.root)?.nodes.get(oldPointer);
            if (context.root !== source.id || !rootDefinition) throw new SourceError('refactor.discriminator', 'The inherited discriminator needs an explicit cross-document mapping before this rename');
            add(ref.targetResource!, pointer, {kind: 'create', pointer, value: input.name}, ref, context.root);
        }
    }
    for(const action of input.actions??[]) {
        const field=['set','setData'].includes(action.kind)&&action.pointer.startsWith(oldPointer+'/');
        const membership=property&&action.kind==='setRequired'&&action.pointer===ownerPointer&&action.name===input.name;
        if(!field&&!membership)throw new SourceError('refactor.action','Combined form edits must belong to the captured definition');
        if(!membership)add(source.id,action.pointer,action);
    }
    for(const move of [...moves].sort((a,b)=>b.from.length-a.from.length))add(move.resource,move.from,{kind:'rename',pointer:move.from,name:input.name});
    for(const action of input.actions??[])if(action.kind==='setRequired'){
        const pointer=transition(source.id,action.pointer);
        add(source.id,pointer,{...action,pointer});
    }
    const edits: any[] = [], outputs = new Map<string, string>();
    for (const [id, values] of actions) {
        const resource = resources.find(r => r.id === id)!;
        const result = propose({...input, target: {resource: id, generation: resource.generation, pointer: ''}, actions: [...values.values()]});
        edits.push(...result.edits);
        let text = resource.text;
        for (const e of [...result.edits].reverse()) text = text.slice(0, e.start) + e.replacement + text.slice(e.end);
        outputs.set(id, text);
    }
    // Re-resolve *all* established consumers, including unchanged occurrences
    // shared by several entry descriptions. A partial repair is not a rename.
    const securityBindings:SecurityBindingChange[]=[];
    for (const {context, graph} of graphs) {
        const after = createGraph({root: context.root, resources: resources.filter(r => context.resources.includes(r.id)).map(r => outputs.has(r.id) ? {...r, text: outputs.get(r.id)!} : r)}).graph;
        if (after.issues.length) throw new SourceError('refactor.proof', 'The derived snapshot introduces an unresolved or ambiguous semantic connection');
        for (const ref of graph.references) {
            const pointer = transition(ref.resource, ref.pointer);
            const keyword = !property && ref.connection === 'security' && affected(ref) ? repaired(ref,graph) : ref.keyword;
            const next = after.references.find(r => r.resource === ref.resource && r.pointer === pointer && r.keyword === keyword);
            if (!next || next.resolution !== ref.resolution || next.targetResource !== ref.targetResource || next.targetPointer !== transition(ref.targetResource!, ref.targetPointer!) || next.base !== ref.base || JSON.stringify(next.dynamic?.candidates.map(t => [t.resource, t.pointer]).sort()) !== JSON.stringify(ref.dynamic?.candidates.map(t => [t.resource, transition(t.resource, t.pointer)]).sort()))
                throw new SourceError('refactor.proof', 'A semantic consumer would change meaning in one of the configured roots');
            if(input.configuration&&ref.connection==='security')securityBindings.push({root:context.root,before:ref,after:next});
        }
    }
    const changes = [...outputs].map(([id, text]) => ({resource: id, before: resources.find(r => r.id === id)!.text, after: text}));
    const configuration=securityConfigurationCopies(input.configuration,securityBindings);
    if(configuration?.actions.length){
        if(resources.some(resource=>resource.id===configuration.source.id))throw new SourceError('refactor.configuration.ownership','Project configuration cannot also be an edited API graph resource');
        const result=propose({...input,resources:[configuration.source],target:{resource:configuration.source.id,generation:configuration.source.generation,pointer:''},actions:configuration.actions});
        let text=configuration.source.text;for(const edit of [...result.edits].reverse())text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
        if(Buffer.byteLength(text,'utf8')>65536)throw new SourceError('limit.refactor.configuration','The repaired project configuration would exceed 64 KiB',[0,configuration.source.text.length],'unsupported',{resource:configuration.source.id,pointer:'',range:[0,configuration.source.text.length]});
        edits.push(...result.edits);changes.push({resource:configuration.source.id,before:configuration.source.text,after:text});
        for(const usage of configuration.usages)usages.set(JSON.stringify([usage.resource,usage.pointer,usage.target.resource,usage.target.pointer]),usage);
    }
    return {version: 1, snapshot: input.snapshot, identity: createHash('sha256').update(JSON.stringify({snapshot: input.snapshot, target: input.target, name: input.name, edits})).digest('hex'), edits, changes, usages: [...usages.values()], from: input.target, to: {...input.target, pointer: transition(source.id, oldPointer)}, transitions:[...moves].sort((a,b)=>b.from.length-a.from.length), ...(property?{kind:'property-rename',preservedNameConstraints:[...warnings]}:{}), ...(schemaDefinition?{kind:'schema-definition-rename'}:{}), checkedRoots: input.contexts.map((c: any) => c.root), externalConsumers: 'Only the supplied configured-root graph is known; consumers outside this project are not rewritten.'};
}

export const planPropertyRename = (input:any) => planRename({...input,property:true});
export const planResponseRename = (input:any) => planRename({...input,response:true});
export const planSchemaDefinitionRename = (input:any) => planRename({...input,schemaDefinition:true});
