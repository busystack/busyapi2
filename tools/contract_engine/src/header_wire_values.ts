import {SourceError} from './document';
import type {HeaderShape} from './header_serialization';
import {headerValueParts} from './header_values';

const decimal=/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/;
export type HeaderWireValues={texts:string[];complete:boolean};

/** OAS simple-style inversion is bounded, not an independent schema validator.
 * Primitive alternatives retain exact JSON text. A complete original-schema
 * proof can establish a valid interpretation; exhaustion cannot establish an
 * invalid value. Null uses the literal JSON token, matching native parameter
 * conversion; no alternate null spelling or nested collection is inferred. */
export function headerWireValues(shape:HeaderShape,values:readonly string[],options:{cookie:boolean;multiline:boolean;explode:boolean}):HeaderWireValues {
    let complete=true,work=0;
    const visit=()=>{if(++work>32768)throw new SourceError('limit.runtime.header','Header wire inversion exceeds its bounded work budget',[0,0],'unsupported');};
    const variants=function*(shape:HeaderShape):Generator<HeaderShape>{
        visit();
        if(shape.type==='union'){for(const item of shape.variants??[])yield* variants(item);}
        else if(shape.type==='any'){for(const type of ['string','number','boolean','null','array','object'])yield {type};}
        else yield shape;
    };
    const scalar=function*(text:string,shape:HeaderShape|undefined):Generator<string>{
        for(const option of variants(shape??{type:'any'})){
            visit();
            if(option.type==='string'||option.type==='never')yield JSON.stringify(text);
            else if(['integer','number'].includes(option.type)){if(decimal.test(text.trim()))yield text.trim();}
            else if(option.type==='boolean'){if(text.trim()==='true'||text.trim()==='false')yield text.trim();}
            else if(option.type==='null'){if(text.trim()==='null')yield 'null';}
            else complete=false;
        }
    };
    const combinations=function*(fields:readonly string[],schemas:readonly (HeaderShape|undefined)[]):Generator<string[]> {
        const choices=fields.map((field,index)=>[...new Set(scalar(field,schemas[index]))]);
        if(choices.some(values=>!values.length))return;
        const indices=fields.map(()=>0);
        while(true){
            visit();yield choices.map((values,index)=>values[indices[index]]);
            let at=indices.length-1;
            while(at>=0&&++indices[at]>=choices[at].length){indices[at]=0;at--;}
            if(at<0)return;
        }
    };
    const interpretations=function*():Generator<string>{
        for(const option of variants(shape)){
            visit();
            if(option.type==='never'){yield JSON.stringify(values);continue;}
            if(option.type!=='array'&&option.type!=='object'){
                if(values.length!==1){complete=false;continue;}
                yield* scalar(values[0],option);continue;
            }
            if(options.cookie&&(!options.multiline||option.type==='array'||!options.explode)){complete=false;continue;}
            let parts:string[];
            try{parts=options.cookie?[...values]:headerValueParts(values.join(','));}
            catch(error){if(!(error instanceof SourceError))throw error;continue;}
            if(option.type==='array'){
                if(parts.length===1&&parts[0]==='')yield '[]';
                for(const items of combinations(parts,parts.map((_,index)=>option.prefixItems?.[index]??option.items)))yield '['+items.join(',')+']';
                continue;
            }
            const names:string[]=[],fields:string[]=[];
            if(options.explode){
                for(const part of parts){const equals=part.indexOf('=');if(equals<0){names.length=0;break;}names.push(part.slice(0,equals));fields.push(part.slice(equals+1));}
                if(names.length!==parts.length)continue;
            }else{
                if(parts.length%2!==0)continue;
                for(let at=0;at<parts.length;at+=2){names.push(parts[at]);fields.push(parts[at+1]);}
            }
            if(new Set(names).size!==names.length){complete=false;continue;}
            const schemas=names.map(name=>option.properties&&Object.hasOwn(option.properties,name)?option.properties[name]:option.additionalProperties);
            for(const items of combinations(fields,schemas))yield '{'+names.map((name,index)=>JSON.stringify(name)+':'+items[index]).join(',')+'}';
        }
    };
    const texts=new Set<string>();let bytes=0;
    try{
        for(const text of interpretations()){
            if(texts.has(text))continue;
            if(texts.size>=256||bytes+Buffer.byteLength(text,'utf8')>8*1024*1024){complete=false;break;}
            texts.add(text);bytes+=Buffer.byteLength(text,'utf8');
        }
    }catch(error){
        if(!(error instanceof SourceError)||!error.code.startsWith('limit.'))throw error;
        complete=false;
    }
    if(!texts.size)throw new SourceError(complete?'runtime.response.header.serialization':'runtime.response.header.unchecked',
        complete?'The received header has no declared primitive or collection representation':'The header needs an unsupported or unbounded wire interpretation',[0,0],complete?undefined:'unsupported');
    return {texts:[...texts],complete};
}
