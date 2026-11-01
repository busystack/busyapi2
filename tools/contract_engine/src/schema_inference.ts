import {SourceDocument,SourceError,escape} from './document';
import {modernFamily} from './specification';
import type {GraphScope,ReferenceGraph} from './reference_graph';

type InferredSchema={type?:string;enum?:null[];nullable?:boolean;properties?:Record<string,InferredSchema>;items?:InferredSchema;anyOf?:InferredSchema[]};

function integer(raw: string) {
    const [mantissa, exponent = '0'] = raw.toLowerCase().split('e');
    const [whole, fraction = ''] = mantissa.replace(/^-/, '').split('.');
    const digits = whole + fraction;
    if (!/[1-9]/.test(digits)) return true;
    const zeros = digits.length - digits.replace(/0+$/, '').length;
    return BigInt(exponent) + BigInt(zeros - fraction.length) >= 0n;
}

/** Bounded, sample-only inference emits the destination family's Schema Object. */
export function inferSampleSchema(sample:SourceDocument,raw:string,family:string) {
    let count = 0;
    const assumptions = new Set(['sample-only','optional-properties','no-enums','no-string-formats','no-numeric-bounds']);
    const modern=modernFamily(family);
    const infer = (pointer: string, depth: number): InferredSchema => {
        if (++count > 10000 || depth > 32) throw new SourceError('limit.suggest', 'The example exceeds the bounded suggestion complexity');
        const n = sample.node(pointer);
        switch (n.kind) {
            case 'null':
                if (modern||family==='2.0') return {type:'null'};
                assumptions.delete('no-enums'); assumptions.add('null-only-enum');
                return {type:'string',nullable:true,enum:[null]};
            case 'boolean': return {type:'boolean'};
            case 'string': return {type:'string'};
            case 'number': return {type: integer(raw.slice(...n.range)) ? 'integer' : 'number'};
            case 'object': return {type:'object',properties:Object.fromEntries([...n.children].map(([key, child])=>[key,infer(child.pointer,depth+1)]))};
            case 'array': {
                if (!n.children.size) { assumptions.add('empty-array'); return modern ? {type:'array'} : {type:'array',items:{}}; }
                const variants = new Map<string,InferredSchema>();
                for (const child of n.children.values()) {
                    const schema=infer(child.pointer,depth+1);
                    if (variants.size <= 32) variants.set(JSON.stringify(schema),schema);
                }
                if (variants.size > 32) {assumptions.add('heterogeneous-array'); return {type:'array',items:{}};}
                const schemas=[...variants.values()];
                if(family==='2.0'&&schemas.length>1){assumptions.add('heterogeneous-array');return {type:'array',items:{}};}
                return {type:'array',items:schemas.length===1?schemas[0]:{anyOf:schemas}};
            }
            default: throw new SourceError('suggest.data', 'The example is not a strict JSON-compatible value');
        }
    };
    const schema = infer('',0), encoded = JSON.stringify(schema);
    if (encoded.length > 512 * 1024) throw new SourceError('limit.suggest','The inferred schema exceeds the bounded suggestion size');
    return {schema,assumptions:[...assumptions]};
}

/** Native authoring consumes captured source pointers and policy, including
 * Swagger's MIME-keyed response examples; presentation does not choose a family. */
export function schemaInferenceSources(graph:ReferenceGraph,scope:GraphScope) {
    const node=graph.docs.get(scope.resource)?.dataNode(scope.pointer);
    if(!node||typeof node.value?.$ref==='string')return;
    const samples:{pointer:string;name?:string}[]=[];
    if(['media','parameter','header'].includes(scope.kind)&&node.children.has('example'))
        samples.push({pointer:scope.pointer+'/example'});
    if(scope.family==='2.0'&&scope.kind==='response'){
        const examples=node.children.get('examples');
        if(examples?.kind==='object')for(const name of examples.children.keys())
            samples.push({pointer:scope.pointer+'/examples/'+escape(name),name});
    }
    if(samples.length)return {nullable:true,samples};
}
