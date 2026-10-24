import { createGraph, propose, Resource } from './engine';
import { escape, segments, SourceDocument, SourceError } from './document';

function integer(raw: string) {
    const [mantissa, exponent = '0'] = raw.toLowerCase().split('e');
    const [whole, fraction = ''] = mantissa.replace(/^-/, '').split('.');
    const digits = whole + fraction;
    if (!/[1-9]/.test(digits)) return true;
    const zeros = digits.length - digits.replace(/0+$/, '').length;
    return BigInt(exponent) + BigInt(zeros - fraction.length) >= 0n;
}

/** Inference is a reviewed suggestion over JSON-compatible authored data. It
 * never modifies the sample, infers credentials, or claims sample universality.
 * No reference resolver walks example data, including its literal $ref keys. */
export function suggestSchema(input: any) {
    const { docs, graph } = createGraph(input), doc = docs.get(input.resource);
    if (!doc) throw new SourceError('suggest.resource', 'Choose an approved example resource');
    const parts = segments(input.pointer), name = parts.pop(), parentPointer = parts.length ? '/' + parts.map(escape).join('/') : '';
    const parent = graph.scopes.get(doc.id + '#' + parentPointer);
    if (!(parent?.kind === 'example' && name === 'value' || ['media','parameter','header'].includes(parent?.kind ?? '') && name === 'example'))
        throw new SourceError('suggest.context', 'Choose an authored example value, not serialized text or an external URL');
    if (typeof doc.node(parentPointer).value?.$ref === 'string') throw new SourceError('suggest.context', 'A Reference Object sibling is not an authored Example Object');
    doc.assertSafe(input.pointer);
    const node = doc.node(input.pointer), raw = doc.dataJson(input.pointer);
    if (raw.length > 1024 * 1024) throw new SourceError('limit.suggest', 'The example exceeds the 1 MiB suggestion budget');
    const sample = new SourceDocument(raw, 'file:///busyapi-derived-example.json');
    let count = 0;
    const assumptions = new Set(['sample-only','optional-properties','no-enums','no-string-formats','no-numeric-bounds']);
    const infer = (pointer: string, depth: number): any => {
        if (++count > 10000 || depth > 32) throw new SourceError('limit.suggest', 'The example exceeds the bounded suggestion complexity');
        const n = sample.node(pointer);
        switch (n.kind) {
            case 'null': return {type:'null'};
            case 'boolean': return {type:'boolean'};
            case 'string': return {type:'string'};
            case 'number': return {type: integer(raw.slice(...n.range)) ? 'integer' : 'number'};
            case 'object': return {type:'object',properties:Object.fromEntries([...n.children].map(([key, child])=>[key,infer(child.pointer,depth+1)]))};
            case 'array': {
                if (!n.children.size) { assumptions.add('empty-array'); return {type:'array'}; }
                const variants = new Map<string,any>();
                for (const child of n.children.values()) {
                    const schema=infer(child.pointer,depth+1);
                    if (variants.size <= 32) variants.set(JSON.stringify(schema),schema);
                }
                if (variants.size > 32) {assumptions.add('heterogeneous-array'); return {type:'array',items:{}};}
                const schemas=[...variants.values()];
                return {type:'array',items:schemas.length===1?schemas[0]:{anyOf:schemas}};
            }
            default: throw new SourceError('suggest.data', 'The example is not a strict JSON-compatible value');
        }
    };
    const schema = infer('',0), encoded = JSON.stringify(schema);
    if (encoded.length > 512 * 1024) throw new SourceError('limit.suggest','The inferred schema exceeds the bounded suggestion size');
    const resource=(input.resources as Resource[]).find(r=>r.id===doc.id)!;
    return {version:1,snapshot:input.snapshot,root:input.root,resource:doc.id,generation:resource.generation,pointer:input.pointer,range:node.range,schema,assumptions:[...assumptions]};
}

export function planSchemaSuggestion(input: any) {
    const suggestion = suggestSchema(input), {docs,graph}=createGraph(input);
    const target=input.target, doc=docs.get(target?.resource);
    const destination=doc?.nodes.get(target?.pointer), scope=doc && graph.scopes.get(doc.id+'#'+target.pointer);
    const resource=(input.resources as Resource[]).find(r=>r.id===target?.resource);
    if (!doc || !destination || resource?.generation!==target.generation || !['media','parameter','header'].includes(scope?.kind ?? ''))
        throw new SourceError('suggest.destination','Choose a current schema-bearing object in this root');
    if (destination.children.has('schema') || destination.children.has('content') || destination.value?.$ref)
        throw new SourceError('suggest.collision','The destination already authors a schema, content, or reference; no content was replaced');
    const schema=input.nullable===true?{anyOf:[suggestion.schema,{type:'null'}]}:suggestion.schema;
    const result=propose({...input,target,actions:[{kind:'create',pointer:target.pointer+'/schema',value:schema}]});
    let after=resource.text;
    for(const edit of [...result.edits].reverse())after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
    const derived=createGraph({...input,resources:input.resources.map((r:Resource)=>r.id===resource.id?{...r,text:after}:r)});
    if (derived.docs.get(suggestion.resource)?.dataJson(suggestion.pointer)!==docs.get(suggestion.resource)?.dataJson(suggestion.pointer))
        throw new SourceError('suggest.proof','The derived schema would change the original sample');
    return {version:1,snapshot:input.snapshot,edits:result.edits,changes:result.edits.length?[{resource:resource.id,before:resource.text,after}]:[],usages:[],from:target,to:target,checkedRoots:[input.root],kind:'schema-suggestion',schema,assumptions:suggestion.assumptions};
}
