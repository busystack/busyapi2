import {createHash} from 'node:crypto';
import {createGraph, propose, Resource} from './engine';
import {removableField} from './authoring';
import {escape, segments, SourceError} from './document';
import {resolveUri} from './reference_graph';
import {modernFamily} from './specification';

const within = (pointer: string, owner: string) => pointer === owner || pointer.startsWith(owner + '/');

/** Removing an authored object is a reviewed source change, not cascading
 * deletion of its consumers. Only known required membership is repaired.
 * Every surviving connection is proved against all supplied root contexts. */
export function planDelete(input: any) {
    const resources = input.resources as Resource[];
    if (!Array.isArray(resources) || !Array.isArray(input.contexts) || !input.contexts.length || input.contexts.length > 128)
        throw new SourceError('refactor.context', 'Choose the configured roots whose consumers are being reviewed');
    const target = input.target, resource = resources.find(r => r.id === target?.resource);
    if (!resource || resource.generation !== target.generation || !target.pointer)
        throw new SourceError('edit.stale', 'The captured object changed or has no removable owner');
    const graphs = input.contexts.map((context: any) => {
        if (!Array.isArray(context.resources) || !context.resources.includes(context.root) || context.resources.some((id: string) => !resources.some(r => r.id === id)))
            throw new SourceError('refactor.context', 'A root context contains an unavailable resource');
        return {context, ...createGraph({root: context.root, resources: resources.filter(r => context.resources.includes(r.id))})};
    });
    for (const {docs, graph} of graphs) {
        if ([...docs.values()].some(doc => doc.issues.length)) throw new SourceError('refactor.syntax', 'Repair ambiguous source syntax before reviewing deletion');
        if (graph.issues.length) throw new SourceError('refactor.graph', 'Resolve unavailable or ambiguous semantic connections before reviewing deletion');
    }
    const parts = segments(target.pointer), name = parts.pop()!, parentPointer = parts.length ? '/' + parts.map(escape).join('/') : '';
    const owner = graphs.find(g => g.graph.scopes.has(resource.id + '#' + target.pointer) || g.graph.scopes.has(resource.id + '#' + parentPointer));
    const doc = owner?.docs.get(resource.id), node = doc?.nodes.get(target.pointer);
    if (!doc || !node || node.shared) throw new SourceError('refactor.definition', 'Choose an authored object with unambiguous physical ownership');
    doc.assertSafe(target.pointer);
    if (target.range && JSON.stringify(target.range) !== JSON.stringify(node.range) || target.expected !== undefined && target.expected !== resource.text.slice(...node.range))
        throw new SourceError('edit.stale', 'The captured object occurrence changed');
    const parent = doc.node(parentPointer), scope = owner.graph.scopes.get(resource.id + '#' + parentPointer);
    // A referenced fragment can have an arbitrary container, not an invented
    // Components map. Its established child context still identifies the
    // physical definition; surviving consumers below will block its removal.
    const fragmentDefinition = parent.kind === 'object' && owner.graph.scopes.has(resource.id + '#' + target.pointer) && (!scope || scope.kind === 'root' && typeof doc.root.value?.openapi !== 'string');
    if (!fragmentDefinition && (!scope || !removableField(scope.kind, scope.family, parent.value, name, parts.at(-1)))) throw new SourceError('refactor.delete.required', 'This is not an optional field or authored collection member');
    const isProperty = scope?.kind === 'schema-map' && parts.at(-1) === 'properties';
    const actions: any[] = [{kind: 'remove', pointer: target.pointer}];
    const preservedRelationships: string[] = [];
    if (isProperty) {
        const schemaPointer = parentPointer.slice(0, -'/properties'.length), schema = doc.node(schemaPointer);
        const required = schema.children.get('required');
        if (required?.kind === 'array') {
            const members = [...required.children.values()];
            if (!modernFamily(scope.family) && members.length && members.every(child => child.value === name))
                actions.push({kind: 'remove', pointer: required.pointer});
            else for (const child of members.reverse()) if (child.value === name) actions.push({kind: 'remove', pointer: child.pointer});
        }
        // These constraints may intentionally mention undeclared properties.
        // Never delete them, composed branches or payload keys by spelling.
        for (const keyword of ['dependentRequired','dependentSchemas','propertyNames','patternProperties','allOf','anyOf','oneOf','if','then','else','not','discriminator'])
            if (schema.children.has(keyword)) preservedRelationships.push(schemaPointer + '/' + keyword);
    }
    const transitions: any[] = [{resource: resource.id, from: target.pointer, to: parentPointer, mode: 'removal'}];
    const shift = (id: string, pointer: string) => {
        if (id !== resource.id || parent.kind !== 'array' || !pointer.startsWith(parentPointer + '/')) return pointer;
        const tokens = segments(pointer), index = tokens[parts.length];
        if (!/^(0|[1-9][0-9]*)$/.test(index) || Number(index) <= Number(name)) return pointer;
        tokens[parts.length] = String(Number(index) - 1);
        return '/' + tokens.map(escape).join('/');
    };
    if (parent.kind === 'array') for (const [index, child] of parent.children) if (Number(index) > Number(name))
        transitions.push({resource: resource.id, from: child.pointer, to: shift(resource.id, child.pointer)});
    const usages = new Map<string, any>(), blockers = new Map<string, any>();
    const repairs = new Map<string, Map<string, any>>();
    for (const {context, graph} of graphs) for (const ref of graph.references) {
        const removed = ref.resource === resource.id && within(ref.pointer, target.pointer);
        const direct = ref.targetResource === resource.id && within(ref.targetPointer!, target.pointer);
        const dynamic = ref.dynamic?.candidates.some(t => t.resource === resource.id && within(t.pointer, target.pointer));
        const enclosing = ref.targetResource === resource.id && within(target.pointer, ref.targetPointer!);
        let replacement = ref.value;
        const implicit = ref.connection === 'operationId' ||
            (ref.connection === 'security' || ref.connection === 'discriminator') &&
            graph.docs.get(graph.root)?.dataNode('/components/' + (ref.connection === 'security' ? 'securitySchemes' : 'schemas') + '/' + escape(ref.value)) !== undefined;
        if (!removed && !direct && !dynamic && !implicit) {
            const uri = resolveUri(ref.value, ref.base), fragment = decodeURIComponent(uri.hash.slice(1));
            if (fragment.startsWith('/')) {
                uri.hash = '';
                const identity = graph.identities.get(uri.href);
                if (identity?.length !== 1) throw new SourceError('refactor.identity', 'A surviving reference has an ambiguous resource identity');
                const base = shift(identity[0].resource, identity[0].pointer), to = shift(ref.targetResource!, ref.targetPointer!);
                if (!within(to, base)) throw new SourceError('refactor.identity', 'The surviving target escapes its schema resource');
                const suffix = to.slice(base.length);
                if (suffix !== fragment) replacement = ref.value.slice(0, ref.value.indexOf('#')) + '#' + encodeURI(suffix).replaceAll('#','%23').replaceAll('?','%3F');
            }
        }
        if (!direct && !dynamic && !enclosing && !removed && replacement === ref.value) continue;
        const pointer = ref.pointer + '/' + escape(ref.keyword), key = JSON.stringify([ref.resource, pointer]);
        const previous = usages.get(key);
        const usage = {...previous, resource: ref.resource, pointer, connection: ref.connection ?? ref.keyword,
            target: {resource: ref.targetResource, pointer: ref.targetPointer}, roots: [...new Set([...(previous?.roots ?? []), context.root])],
            effect: removed ? 'removed-with-object' : dynamic ? 'dynamic-scope-candidate' : direct ? 'would-be-unresolved' : replacement !== ref.value ? 'required-index-repair' : 'definition-content-changes'};
        usages.set(key, usage);
        if (!removed && (direct || dynamic)) blockers.set(key, usage);
        if (replacement !== ref.value) {
            const values = repairs.get(ref.resource) ?? new Map<string, any>(), action = {kind: 'set', pointer, value: replacement};
            if (values.has(pointer) && JSON.stringify(values.get(pointer)) !== JSON.stringify(action)) throw new SourceError('refactor.context.ambiguous', 'Root contexts require different repairs of one physical consumer');
            values.set(pointer, action); repairs.set(ref.resource, values);
        }
    }
    if (!repairs.has(resource.id)) repairs.set(resource.id, new Map());
    const outputs = new Map<string, string>(), edits: any[] = [];
    for (const [id, values] of repairs) {
        const original = resources.find(r => r.id === id)!;
        // Repair at original locations before deleting an array member shifts
        // those locations. Propose still yields one captured edit per buffer.
        const result = propose({...input, target: {resource: id, generation: original.generation, pointer: ''}, actions: [...values.values(), ...(id === resource.id ? actions : [])]});
        edits.push(...result.edits);
        let text = original.text;
        for (const edit of [...result.edits].sort((a, b) => b.start - a.start)) text = text.slice(0, edit.start) + edit.replacement + text.slice(edit.end);
        outputs.set(id, text);
    }
    if (!blockers.size) for (const {context, graph} of graphs) {
        const after = createGraph({root: context.root, resources: resources.filter(r => context.resources.includes(r.id)).map(r => outputs.has(r.id) ? {...r, text: outputs.get(r.id)!} : r)}).graph;
        if (after.issues.length) throw new SourceError('refactor.proof', 'Deletion would leave an unresolved or ambiguous semantic connection');
        for (const ref of graph.references) {
            if (ref.resource === resource.id && within(ref.pointer, target.pointer)) continue;
            const pointer = shift(ref.resource, ref.pointer), keyword = ref.keyword;
            const next = after.references.find(r => r.resource === ref.resource && r.pointer === pointer && r.keyword === keyword);
            if (!next || next.resolution !== ref.resolution || next.targetResource !== ref.targetResource || next.targetPointer !== shift(ref.targetResource!, ref.targetPointer!) || next.base !== ref.base ||
                JSON.stringify(next.dynamic?.candidates.map(t => [t.resource, t.pointer]).sort()) !== JSON.stringify(ref.dynamic?.candidates.map(t => [t.resource, shift(t.resource, t.pointer)]).sort()))
                throw new SourceError('refactor.proof', 'A surviving semantic consumer would change target or dynamic context');
        }
    }
    return {version: 1, snapshot: input.snapshot, kind: 'object-delete',
        identity: createHash('sha256').update(JSON.stringify({snapshot: input.snapshot, target, edits})).digest('hex'),
        edits, changes: [...outputs].map(([id, text]) => ({resource: id, before: resources.find(r => r.id === id)!.text, after: text})),
        from: target, to: {...target, pointer: parentPointer}, transitions,
        usages: [...usages.values()], blockers: [...blockers.values()], preservedRelationships,
        checkedRoots: input.contexts.map((c: any) => c.root), externalConsumers: 'Only supplied configured roots are known. Consumers outside this project cannot be proved or rewritten.'};
}
