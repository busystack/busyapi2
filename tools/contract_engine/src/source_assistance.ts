import { analyse, createGraph, Resource } from './engine';
import { fieldsFor } from './authoring';
import { escape, segments, SourceDocument, SourceError } from './document';
import { GraphReference, supportedSchemaDialect } from './reference_graph';
import { referenceValue } from './reference_choices';
import {isNativeFamily} from './specification';
const standard = (family: string, kind: string) => `https://spec.openapis.org/oas/v${family === '2.0' ? '2.0' : family === '3.0' ? '3.0.4' : family === '3.1' ? '3.1.2' : '3.2.1'}.html#${({ root: 'openapi', media: 'media-type', security: 'security-scheme' } as any)[kind] ?? kind}-object`;
function located(input: any, doc: SourceDocument, pointer: string, extra: any = {}) {
    const resource = (input.resources as Resource[]).find(r => r.id === doc.id)!;
    return { root: input.root, resource: doc.id, pointer, generation: resource.generation, identity: resource.identity, ...doc.dataLocation(pointer), ...extra };
}
const inRange = (caret: number, range?: number[]) => range && caret >= range[0] && caret <= range[1];
function refLocation(doc: SourceDocument, ref: GraphReference) {
    const node = doc.dataNode(ref.pointer + '/' + escape(ref.keyword));
    return ref.connection === 'security' ? node?.keyRange ?? node?.range : node?.range;
}
/** Read-only intelligence over the same immutable graph and full source. Each
 * insertion is already a captured, expected-text transaction, never a second
 * mutable editor buffer. Deliberately do not infer contexts inside data. */
export function assistSource(input: any) {
    const { docs, graph } = createGraph(input), doc = docs.get(input.resource);
    if (!doc || !Number.isInteger(input.caret) || input.caret < 0 || input.caret > doc.text.length)
        throw new SourceError('assist.location', 'The source position is outside this snapshot');
    const family = graph.scope(doc.id, '').family;
    if (!isNativeFamily(family))
        throw new SourceError('version.unsupported', 'Source assistance requires a supported containing OpenAPI feature family');
    const caret = input.caret, resource = (input.resources as Resource[]).find(r => r.id === doc.id)!;
    const all = [...doc.nodes.values()];
    if (input.action === 'folds') {
        const from=input.from??0,to=input.to??doc.text.length,folded=input.folded??[];
        if(!Number.isInteger(from)||!Number.isInteger(to)||from<0||to<from||to>doc.text.length||
           !Array.isArray(folded)||folded.length>20000||folded.some(p=>typeof p!=='string'||p.length>16384))
            throw new SourceError('assist.folds.range','Choose bounded source folding coordinates');
        const requested=new Set<string>(folded),owners=folded.map(p=>doc.nodes.get(p)).filter(Boolean).sort((a,b)=>a.range[0]-b.range[0]||b.range[1]-a.range[1]);
        const outer:typeof owners=[];
        for(const owner of owners)if(!outer.length||owner.range[0]>=outer.at(-1)!.range[1])outer.push(owner);
        const hidden=(node:any)=>{
            let low=0,high=outer.length;
            while(low<high){const middle=(low+high)>>>1;if(outer[middle].range[1]<=node.range[0])low=middle+1;else high=middle;}
            return low<outer.length&&outer[low].range[0]<=node.range[0]&&outer[low].pointer!==node.pointer;
        };
        const folds=[];
        for(const n of all){
            const header=doc.format==='json'||n.flow?n.range[0]:n.keyRange?.[0]??n.range[0];
            if(!requested.has(n.pointer)&&(header<from||header>to||hidden(n)))continue;
            if(!['object','array'].includes(n.kind)&&!n.style?.startsWith('BLOCK_')||!doc.syntaxSafe(n.pointer))continue;
            if(!['\r','\n'].some(line=>{const at=doc.text.indexOf(line,header);return at>=0&&at<n.range[1];}))continue;
            folds.push({pointer:n.pointer,start:n.range[0],end:n.range[1],header,flow:n.flow,kind:n.kind});
            if(folds.length>20000)throw new SourceError('limit.folds','Request folds for a smaller source viewport');
        }
        return {version:1,snapshot:input.snapshot,root:input.root,resource:doc.id,generation:resource.generation,caret,pointer:'',kind:'source',completions:[],folds,from,to,complete:!doc.issues.length};
    }
    const nodes = all.filter(n => inRange(caret, n.range)).sort((a, b) => (a.range[1] - a.range[0]) - (b.range[1] - b.range[0]));
    let node = nodes[0] ?? doc.root;
    const keyNode = all.filter(n => inRange(caret, n.keyRange)).sort((a, b) => a.keyRange![0] - b.keyRange![0])[0];
    if (keyNode)
        node = keyNode;
    if (doc.format === 'yaml' && !keyNode) {
        const prefix = doc.text.slice(doc.lineStart(caret), caret);
        if (/^ *$/.test(prefix)) {
            const candidates = all.filter(n => n.kind === 'object' && !n.flow && n.range[0] < caret && n.end <= caret && doc.indent(n.range[0]) === prefix.length && /^\s*$/.test(doc.text.slice(n.end, caret)) && graph.scopes.has(doc.id + '#' + n.pointer));
            candidates.sort((a, b) => b.range[0] - a.range[0]);
            if (candidates[0])
                node = candidates[0];
        }
    }
    const pointer = node.pointer, parts = segments(pointer), name = parts.at(-1) ?? '';
    const parentPointer = parts.length > 1 ? '/' + parts.slice(0, -1).map(escape).join('/') : '';
    const scope = graph.scope(doc.id, pointer), parentScope = graph.scope(doc.id, parentPointer);
    const exact = graph.scopes.get(doc.id + '#' + pointer), parent = doc.nodes.get(parentPointer);
    const parentContext = graph.scopes.get(doc.id + '#' + parentPointer);
    const field = parent && parentContext && fieldsFor(parentScope.kind, family, parent.value, segments(parentPointer).at(-1)).find(f => f.name === name);
    const schemaDialectKnown = scope.kind !== 'schema' || supportedSchemaDialect(scope);
    const customKeyword = !field && parentContext?.kind === 'schema';
    const reference = graph.references.find(r => r.resource === doc.id && inRange(caret, refLocation(doc, r)));
    const definition = reference?.resolution === 'resolved' ? located(input, docs.get(reference.targetResource!)!, reference.targetPointer!, { dynamic: reference.dynamic }) : undefined;
    const result: any = { version: 1, snapshot: input.snapshot, root: input.root, resource: doc.id, generation: resource.generation, caret, pointer, kind: scope.kind,
        help: { name: field?.name ?? name, kind: customKeyword ? 'custom-keyword' : field ? parentScope.kind : exact?.kind ?? 'data', type: schemaDialectKnown ? field?.type ?? exact?.kind ?? node.kind : 'unknown', authored: true, ...(field ? {required: field.required === true, blockedBy: field.blockedBy, prohibited: field.prohibited === true} : {}), dialect: scope.dialect, dialectKnown: schemaDialectKnown, ...(schemaDialectKnown && (field || exact) ? { standard: standard(family, field ? parentScope.kind : scope.kind) } : {}), ...(field?.effectiveDefault !== undefined ? { effectiveDefault: field.effectiveDefault } : {}) },
        definition, resolution: reference?.resolution, dynamic: reference?.dynamic, candidates: reference?.candidateTargets?.map(target=>located(input,docs.get(target.resource)!,target.pointer,{kind:target.kind})), completions: [] };
    if (input.action === 'definition' || input.action === 'help')
        return result;
    if (input.action === 'usages') {
        if (!definition && !exact && !field) {
            result.usages = [];
            return result;
        }
        const target = definition ?? located(input, doc, scope.pointer);
        result.target = target;
        result.usages = graph.references.filter(r => r.resolution === 'resolved' && r.targetResource === target.resource && r.targetPointer === target.pointer).map(r => located(input, docs.get(r.resource)!, r.pointer + '/' + escape(r.keyword), { range: refLocation(docs.get(r.resource)!, r), connection: r.connection ?? r.keyword, value: r.value, dynamic: r.dynamic }));
        return result;
    }
    if (doc.issues.length && (!input.action || input.action === 'completion')) {
        const partial = incompleteKeyCompletions(doc, graph, family, caret, resource.generation);
        if (partial.length) {result.completions=partial;return result;}
    }
    if (!schemaDialectKnown || field?.prohibited || field?.blockedBy?.length) return result;
    // Scalar values use only the legal field's explicit options. Arbitrary
    // example strings are never mistaken for keys or reference applicators.
    if (!keyNode && field && node.kind !== 'object' && node.kind !== 'array') {
        let values = field.options ?? (field.type === 'boolean' ? [true, false] : []);
        if (parentScope.kind === 'schema' && name === 'type')
            values = ['object', 'array', 'string', 'number', 'integer', 'boolean', ...(family === '3.0' ? [] : ['null'])];
        if (['$ref','$dynamicRef'].includes(name) && graph.references.some(r => r.resource === doc.id && r.pointer === parentPointer && r.keyword === name)) {
            const expectedKind = parentScope.kind;
            const compatible = (kind: string) => expectedKind === 'schema' ? kind === 'schema' : kind === expectedKind;
            const suggestions: any[] = [];
            for (const target of graph.scopes.values()) {
                if (!compatible(target.kind) || name==='$ref'&&!/^(?:\/components\/[^/]+|\/(?:definitions|parameters|responses|securityDefinitions))\/[^/]+$/.test(target.pointer))
                    continue;
                const value=referenceValue(graph,parentScope,target,name);
                if(value===undefined)continue;
                suggestions.push({ value, label: segments(target.pointer).at(-1), target: located(input, docs.get(target.resource)!, target.pointer) });
            }
            for (const suggestion of suggestions)
                addValue(suggestion.value, suggestion.label, suggestion.target);
        }
        else
            for (const value of values)
                addValue(value, typeof value === 'string' ? value : JSON.stringify(value));
        return result;
    }
    function addValue(value: any, label: string, target?: any) {
        if (node.shared || !doc.syntaxSafe(pointer))
            return;
        const replacement = doc.emit(value, node, node.flow), expected = doc.text.slice(...node.range);
        if (replacement === expected)
            return;
        result.completions.push({ label, type: field?.type, standard: result.help.standard, target, edits: [{ buffer: doc.id, generation: resource.generation, start: node.range[0], end: node.range[1], expected, replacement }], selection: [node.range[0] + replacement.length, node.range[0] + replacement.length] });
    }
    // Key completion is confined to a mapping in a known authored object. The
    // engine produces separators/indentation through its existing CST writer.
    let container = keyNode ? parent : node, containerPointer = keyNode ? parentPointer : pointer;
    if (container?.kind !== 'object' || container.shared || !doc.syntaxSafe(containerPointer))
        return result;
    const context = graph.scopes.get(doc.id + '#' + containerPointer);
    if (!context || context.kind.endsWith('-map') || context.kind.endsWith('-array'))
        return result;
    if (!keyNode && doc.format === 'yaml' && !container.flow && !/^\s*$/.test(doc.text.slice(Math.max(container.range[0] + 1, doc.text.lastIndexOf('\n', caret - 1) + 1), caret)))
        return result;
    const descriptions = fieldsFor(context.kind, family, container.value, segments(containerPointer).at(-1));
    let prefix = '';
    if (keyNode) {
        const raw=doc.text.slice(keyNode.keyRange![0],caret);
        try {prefix=raw.startsWith('"')?JSON.parse(raw.endsWith('"')&&raw.length>1?raw:raw+'"'):raw.startsWith("'")?raw.slice(1).replace(/'$/, '').replaceAll("''", "'"):raw;}
        catch {return result;}
    }
    for (const candidate of descriptions) {
        if (Object.hasOwn(container.value, candidate.name) || !candidate.name.startsWith(prefix) || candidate.prohibited || candidate.blockedBy?.length)
            continue;
        if (keyNode) {
            const range=keyNode.keyRange!, expected=doc.text.slice(...range);
            const replacement=expected.startsWith("'")?"'"+candidate.name.replaceAll("'","''")+"'":expected.startsWith('"')||doc.format==='json'?JSON.stringify(candidate.name):doc.emit(candidate.name);
            result.completions.push({label:candidate.name,type:candidate.type,standard:standard(family,context.kind),edits:[{buffer:doc.id,generation:resource.generation,start:range[0],end:range[1],expected,replacement}],selection:[range[0]+replacement.length,range[0]+replacement.length]});
            continue;
        }
        const choices = candidate.options ?? (candidate.type === 'boolean' ? [true, false] : [candidate.type === 'string' ? '' : candidate.type === 'array' ? [] : candidate.type === 'object' || candidate.type === 'schema' ? {} : candidate.type === 'number' || candidate.type === 'integer' ? 0 : null]);
        for (const value of choices) {
            const insert = keyInsertion(doc, container, caret, candidate.name, value);
            if (!insert)
                continue;
            const replacement = insert;
            result.completions.push({ label: candidate.name + (candidate.options || candidate.type === 'boolean' ? ' = ' + JSON.stringify(value) : ''), type: candidate.type, standard: standard(family, context.kind), edits: [{ buffer: doc.id, generation: resource.generation, start: caret, end: caret, expected: '', replacement }], selection: [caret + replacement.length, caret + replacement.length] });
        }
    }
    return result;
}

export const sourceFolds=(input:any)=>assistSource({...input,action:'folds'});

// A half-typed key may have no value node in the tolerant CST. Repair only an
// identified mapping hole, then prove that mapping's syntax and field context
// before offering its captured edit. The hypothetical parse is immutable;
// neither invalid siblings nor canonical source are normalized or replaced.
function incompleteKeyCompletions(doc:SourceDocument, graph:any, family:string, caret:number, generation:number) {
    const before=doc.text.slice(0,caret), line=doc.text.slice(doc.lineStart(caret),caret);
    let start=caret,end=caret,prefix='';
    if(doc.format==='yaml') {
        const match=/^( *)([$A-Za-z][\w$-]*)$/.exec(line);
        if(!match)return [];
        if(!/^\s*$/.test(doc.text.slice(caret,doc.text.indexOf('\n',caret)<0?doc.text.length:doc.text.indexOf('\n',caret))))return [];
        prefix=match[2];start=caret-prefix.length;
    }else{
        const match=/(?:\{|,)\s*"([$A-Za-z][\w$-]*)$/.exec(before);
        if(!match)return [];
        prefix=match[1];start=caret-prefix.length-1;
        if(doc.text[caret]==='"')end++;
        const next=doc.text.slice(end).match(/^\s*(.)/s)?.[1];
        if(next!=='}'&&next!==','&&next!=='"')return [];
    }
    const containers=[...doc.nodes.values()].filter(n=>n.kind==='object'&&n.range[0]<start&&(n.range[1]>=start||doc.format==='yaml'&&/^\s*$/.test(doc.text.slice(n.end,doc.lineStart(start))))).sort((a,b)=>b.range[0]-a.range[0]);
    const container=containers[0];if(!container||container.shared)return [];
    const context=graph.scopes.get(doc.id+'#'+container.pointer);
    if(!context||context.kind.endsWith('-map')||context.kind.endsWith('-array'))return [];
    if(doc.format==='yaml'&&(container.flow||doc.indent(container.children.values().next().value?.keyRange?.[0]??container.range[0])!==line.length-prefix.length))return [];
    if(context.kind==='schema'&&!supportedSchemaDialect(context))return [];
    const completions:any[]=[];
    for(const field of fieldsFor(context.kind,family,container.value,segments(container.pointer).at(-1))) {
        if(!field.name.startsWith(prefix)||Object.hasOwn(container.value,field.name)||field.prohibited||field.blockedBy?.length)continue;
        const values=field.options??(field.type==='boolean'?[true,false]:[field.type==='string'?'':field.type==='array'?[]:['object','schema'].includes(field.type)?{}:['number','integer'].includes(field.type)?0:null]);
        for(const value of values) {
            const replacement=(doc.format==='json'?JSON.stringify(field.name):field.name)+': '+JSON.stringify(value)+(doc.format==='json'&&/^\s*"/.test(doc.text.slice(end))?',':'');
            const text=doc.text.slice(0,start)+replacement+doc.text.slice(end);
            let repaired:SourceDocument;try{repaired=new SourceDocument(text,doc.id,true);}catch{continue;}
            const pointer=container.pointer+'/'+escape(field.name);
            if(!repaired.syntaxSafe(container.pointer)||!repaired.nodes.has(pointer))continue;
            completions.push({label:field.name+(field.options||field.type==='boolean'?' = '+JSON.stringify(value):''),type:field.type,standard:standard(family,context.kind),edits:[{buffer:doc.id,generation,start,end,expected:doc.text.slice(start,end),replacement}],selection:[start+replacement.length,start+replacement.length]});
        }
    }
    return completions;
}
function keyInsertion(doc: SourceDocument, container: any, caret: number, key: string, value: any): string | undefined {
    const entries = [...container.children.values()] as any[];
    if (entries.some(n => caret >= (n.keyRange?.[0] ?? n.range[0]) && caret <= n.range[1]))
        return;
    if (container.flow || doc.format === 'json') {
        const previous = entries.filter(n => n.range[1] < caret).at(-1), next = entries.find(n => (n.keyRange?.[0] ?? n.range[0]) > caret);
        const from = previous?.range[1] ?? container.range[0] + 1, to = next?.keyRange?.[0] ?? next?.range[0] ?? container.range[1] - 1;
        if (caret < from || caret > to)
            return;
        const before = doc.text.slice(from, caret), after = doc.text.slice(caret, to);
        if (!/^[\s,]*$/.test(before + after) || (before + after).replace(/\s/g, '').length > (previous && next ? 1 : 0))
            return;
        return (previous && !before.includes(',') ? ', ' : '') + JSON.stringify(key) + ': ' + JSON.stringify(value) + (next && !after.includes(',') ? ', ' : '');
    }
    const start = doc.lineStart(caret), end = doc.text.indexOf('\n', caret), lineEnd = end < 0 ? doc.text.length : end;
    const before = doc.text.slice(start, caret), after = doc.text.slice(caret, lineEnd);
    if (!/^ *$/.test(before) || !/^\s*$/.test(after))
        return;
    const indent = doc.indent(entries[0]?.keyRange?.[0] ?? container.range[0]);
    if (before.length !== indent)
        return;
    return doc.emit(key) + ': ' + JSON.stringify(value);
}
export function semanticSearch(input: any) {
    if (typeof input.query !== 'string' || input.query.length > 4096)
        throw new SourceError('limit.search.query', 'Choose a bounded semantic query');
    const category = input.category ?? 'all';
    if (!['all','operations','components','definitions','usages'].includes(category))
        throw new SourceError('search.category', 'Choose an established semantic search category');
    const { docs, graph } = createGraph(input), query = input.query.toLocaleLowerCase('en-US'), matches: any[] = [];
    const projection = analyse(input);
    const bounded = (value: string) => value.length <= 240 ? value : value.slice(0, /[\uD800-\uDBFF]/.test(value[239]) ? 239 : 240) + '…';
    const add = (location: any, label: string, search: string[], kind: string, occurrence?: string, extra: any = {}) => {
        if (![label, location.pointer, location.resource, ...search].some(v => v.toLocaleLowerCase('en-US').includes(query))) return;
        if (matches.length >= 20000) throw new SourceError('limit.search.matches', 'Refine the semantic query');
        matches.push({...location, ...extra, label: bounded(label), kind, ...(occurrence ? {occurrence} : {}), semanticId: JSON.stringify([input.root, location.resource, location.pointer, occurrence ?? location.pointer, kind])});
    };
    if (category === 'all' || category === 'operations') for (const op of projection.operations) {
        const label = [op.customMethod ? op.method : op.method.toUpperCase(), op.path, op.value?.operationId, op.value?.summary].filter(Boolean).join(' · ');
        add(located(input, docs.get(op.resource)!, op.pointer), label, (Array.isArray(op.value?.tags) ? op.value.tags : []).filter((t: any) => typeof t === 'string'), 'operation', op.occurrence, {role: op.role});
    }
    const targets = new Set(graph.references.filter(r => r.resolution === 'resolved').map(r => r.targetResource + '#' + r.targetPointer));
    for (const scope of graph.scopes.values()) {
        const component = /^(?:\/components\/([^/]+)|\/(definitions|parameters|responses|securityDefinitions))\/([^/]+)$/.exec(scope.pointer);
        const definition = targets.has(scope.resource + '#' + scope.pointer);
        if ((!component || !['all','components'].includes(category)) && (!definition || !['all','definitions'].includes(category)))
            continue;
        const label = segments(scope.pointer).at(-1) ?? scope.base;
        add(located(input, docs.get(scope.resource)!, scope.pointer), label, [], component ? 'component' : 'definition', undefined, {objectKind: scope.kind, base: scope.base});
    }
    if (category === 'usages') for (const ref of graph.references) {
        const targetLabel = ref.targetPointer ? segments(ref.targetPointer).at(-1) ?? '' : '';
        add(located(input, docs.get(ref.resource)!, ref.pointer + '/' + escape(ref.keyword), {range: refLocation(docs.get(ref.resource)!, ref)}), `${ref.connection ?? ref.keyword} · ${targetLabel || ref.pointer}`, [targetLabel], 'usage', undefined, {resolution: ref.resolution, dynamic: ref.dynamic, ...(ref.resolution === 'resolved' ? {target: located(input,docs.get(ref.targetResource!)!,ref.targetPointer!)} : {})});
    }
    return { version: 1, snapshot: input.snapshot, root: input.root, complete: ![...docs.values()].some(d=>d.issues.length) && !graph.issues.length && graph.references.every(r=>r.resolution === 'resolved'), matches };
}
