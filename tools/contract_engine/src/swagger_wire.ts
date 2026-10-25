import {SourceError} from './document';
import {record} from './engine_worker_client';

type Primitive='string'|'number'|'integer'|'boolean';
type Collection='csv'|'ssv'|'tsv'|'pipes'|'multi';
export type SwaggerWireShape={type:Primitive}|{type:'array';collectionFormat:Collection;items:SwaggerWireShape};
export type SwaggerHeaderTarget={resource:string;pointer:string;name:string;values:string[]};
const separators:Readonly<Record<Exclude<Collection,'multi'>,string>>={csv:',',ssv:' ',tsv:'\t',pipes:'|'};
const maximumAlternatives=256;
const incomplete=(message:string):never=>{throw new SourceError('runtime.swagger.collection.unchecked',message,[0,0],'unsupported');};
const malformed=(message:string):never=>{throw new SourceError('runtime.swagger.collection.serialization',message);};

/** Read the existing execution projection, not another schema interpretation.
 * Swagger Parameter/Header/Items retain their own recursive collectionFormat
 * (2.0 §§6.4.9, 6.4.10, 6.4.15). Constraints stay in the captured evaluator. */
export function swaggerWireShape(value:unknown,depth=0):SwaggerWireShape {
    if(depth>128)incomplete('Swagger Items nesting exceeds 128');
    if(!record(value))throw new SourceError('mock.validation.protocol','The native Swagger wire shape is malformed');
    if(value.type==='string'||value.type==='number'||value.type==='integer'||value.type==='boolean')return {type:value.type};
    if(value.type!=='array')throw new SourceError('mock.validation.protocol','The native Swagger wire type is unavailable');
    const format=value.collectionFormat===undefined?'csv':value.collectionFormat;
    if(format!=='csv'&&format!=='ssv'&&format!=='tsv'&&format!=='pipes'&&format!=='multi'||depth>0&&format==='multi')
        throw new SourceError('mock.validation.protocol','The native Swagger collection format is unavailable');
    return {type:'array',collectionFormat:format,items:swaggerWireShape(value.items,depth+1)};
}

function combinations(fields:readonly string[][]):string[] {
    let rows:string[][]=[[]];
    for(const field of fields){
        if(rows.length*field.length>maximumAlternatives)incomplete('Swagger collection inversion exceeds 256 possible values');
        rows=rows.flatMap(row=>field.map(value=>[...row,value]));
    }
    return rows.map(row=>'['+row.join(',')+']');
}
function partitions(parts:readonly string[],separator:string):string[][] {
    if(parts.length>9)incomplete('Nested Swagger collection inversion exceeds 256 possible boundaries');
    let rows:string[][]=[[]];
    for(const part of parts)rows=rows.flatMap(row=>row.length?[[...row,part],[...row.slice(0,-1),row.at(-1)+separator+part]]:[[part]]);
    return rows;
}

/** Invert only the transport representation. Exact decimal leaves never pass
 * through Number/JSON.parse. Multiple possible groupings require native schema
 * proof; exhausting bounded alternatives is incomplete rather than invalid. */
export function swaggerWireValues(values:readonly string[],shape:SwaggerWireShape,options:{decode?:(text:string)=>string;plus?:boolean;commas?:(text:string)=>string[]}={}):string[] {
    let work=0;
    const unique=(values:string[])=>{
        const result=[...new Set(values)];
        if(result.length>maximumAlternatives)incomplete('Swagger collection inversion exceeds 256 possible values');
        return result;
    };
    const scalar=(text:string,type:Primitive):string[]=>{
        if(options.decode)text=options.decode(text);
        if(type==='string')return [JSON.stringify(text)];
        if(type==='boolean')return text.trim()==='true'||text.trim()==='false'?[text.trim()]:[];
        return /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/.test(text.trim())?[text.trim()]:[];
    };
    const collection=(text:string,shape:SwaggerWireShape,depth:number):string[]=>{
        if(depth>128||++work>16384)incomplete('Swagger collection inversion exceeds its bounded nesting or work limit');
        if(shape.type!=='array')return scalar(text,shape.type);
        if(shape.collectionFormat==='multi')throw new SourceError('mock.validation.protocol','Nested multi collections are invalid');
        const separator=separators[shape.collectionFormat],forms:string[][]=[separator===','&&options.commas?options.commas(text):text.split(separator)];
        if(options.decode){
            const escaped=separator.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),encoded=encodeURIComponent(separator);
            forms.push(text.split(new RegExp(escaped+'|'+encoded+(separator===' '&&options.plus?'|\\+':''),'iu')));
        }
        const candidates:string[]=[];
        if(text==='')candidates.push('[]');
        for(const parts of forms)for(const fields of shape.items.type==='array'?partitions(parts,separator):[parts]){
            candidates.push(...combinations(fields.map(field=>collection(field,shape.items,depth+1))));
            if(candidates.length>maximumAlternatives*2)incomplete('Swagger collection inversion exceeds its bounded alternatives');
        }
        return unique(candidates);
    };
    let result:string[];
    if(shape.type==='array'&&shape.collectionFormat==='multi')result=combinations(values.map(value=>collection(value,shape.items,1)));
    else {
        if(values.length!==1)malformed('This Swagger scalar or delimited collection occurs more than once');
        result=collection(values[0],shape,0);
    }
    if(!result.length)malformed('The Swagger wire value does not match its declared primitive representation');
    return unique(result);
}
