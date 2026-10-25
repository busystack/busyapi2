import {SourceError} from './document';
import {record} from './engine_worker_client';
import {headerShapes,type HeaderShape} from './header_serialization';
import {isNativeFamily} from './specification';
import {runtimeMediaKind} from './runtime_media';
import {nativeMedia,schemaLocation,type NativeRuntimeInstance} from './mock_projection';

const decimal=/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/;
const unsupported=(message:string):never=>{throw new SourceError('runtime.response.header.unchecked',message,[0,0],'unsupported');};
const malformed=(message:string):never=>{throw new SourceError('runtime.response.header.serialization',message);};

export function nativeHeaderParts(text:string):string[] {
    const result:string[]=[];
    let quoted=false,escaped=false,start=0;
    for(let index=0;index<text.length;index++){
        const character=text[index];
        if(escaped){escaped=false;continue;}
        if(quoted&&character==='\\'){escaped=true;continue;}
        if(character==='"')quoted=!quoted;
        if(!quoted&&character===','){result.push(text.slice(start,index).trim());start=index+1;}
    }
    if(quoted||escaped)malformed('A header quoted value is unfinished');
    result.push(text.slice(start).trim());return result;
}

/** Reconstruct header data for the canonical evaluator. Decimal tokens never
 * become JavaScript numbers. This transport codec does not evaluate schemas.
 * Header Objects use simple style; Swagger Header/Items use collectionFormat.
 * OAS 3.2 §4.21.3 keeps each Set-Cookie line separate, including its commas. */
export function decodeRuntimeHeader(shapeFor:ReturnType<typeof headerShapes>,declaration:unknown,values:readonly string[]):NativeRuntimeInstance|undefined {
    if(!record(declaration)||typeof declaration.name!=='string'||typeof declaration.family!=='string'||!isNativeFamily(declaration.family))
        throw new SourceError('mock.validation.protocol','The native header projection is malformed');
    const name=declaration.name,family=declaration.family,cookie=name.toLowerCase()==='set-cookie';
    const content=nativeMedia(declaration.content);
    if(content.length){
        if(content.length!==1)unsupported('A header has more than one content representation');
        if(values.length!==1&&(!cookie||family!=='3.2'))unsupported('A content-based header has multiple wire values');
        const media=content[0];
        if(!media.schema&&!media.itemSchema&&runtimeMediaKind(media.mediaType)==='opaque')return;
        return {subject:'response-header',location:name,text:values.join('\n'),mediaType:media.mediaType,schema:media.schema,itemSchema:media.itemSchema,
            ...(['application/x-www-form-urlencoded','multipart/form-data'].includes(media.mediaType.split(';')[0].trim().toLowerCase())&&media.formOwner?{form:media.formOwner}:{})};
    }
    const schema=schemaLocation(declaration.schema);
    if(!schema||record(declaration.schema)&&declaration.schema.unconstrained===true)return;
    const shape=shapeFor({...schema,kind:'schema'});
    if(!shape||family!=='2.0'&&declaration.style!=='simple')unsupported('The declared header has no unambiguous simple representation');
    if(cookie&&family!=='3.2'&&(values.length>1||shape.type==='array'||shape.type==='object'))
        unsupported('This Set-Cookie representation requires the OpenAPI 3.2 multiline rules');
    const scalar=(text:string,shape:HeaderShape|undefined):string=>{
        if(shape?.type==='string')return JSON.stringify(text);
        if(shape?.type==='integer'||shape?.type==='number')return decimal.test(text.trim())?text.trim():malformed('A numeric header value is not a JSON decimal');
        if(shape?.type==='boolean')return text.trim()==='true'||text.trim()==='false'?text.trim():malformed('A boolean header value must be true or false');
        return unsupported('A nested or unknown header value has no unambiguous scalar representation');
    };
    let text:string;
    if(shape.type!=='array'&&shape.type!=='object'){
        if(values.length!==1)unsupported('A scalar header occurs more than once');
        text=scalar(values[0],shape);
    }else{
        const collection=declaration.collectionFormat;
        const delimiters:Readonly<Record<string,string>>={ssv:' ',tsv:'\t',pipes:'|'};
        const delimiter=typeof collection==='string'&&Object.hasOwn(delimiters,collection)?delimiters[collection]:undefined;
        const parts=family==='2.0'&&delimiter!==undefined?values.join(',').split(delimiter):cookie?[...values]:nativeHeaderParts(values.join(','));
        if(shape.type==='array'){
            if(cookie)unsupported('Set-Cookie values are separate cookie fields rather than comma-separated array items');
            if(parts.length===1&&parts[0]==='')unsupported('An empty array and one empty item share this wire representation');
            text='['+parts.map(part=>scalar(part,shape.items)).join(',')+']';
        }else{
            const fields=new Map<string,string>();
            const add=(key:string,value:string)=>{
                if(fields.has(key))unsupported('A header object repeats a member');
                fields.set(key,scalar(value,shape.properties&&Object.hasOwn(shape.properties,key)?shape.properties[key]:shape.additionalProperties));
            };
            if(declaration.explode===true){
                for(const part of parts){const equals=part.indexOf('=');if(equals<0)malformed('A header object member has no equals delimiter');add(part.slice(0,equals),part.slice(equals+1));}
            }else{
                if(cookie)unsupported('A Set-Cookie object requires exploded key/value fields');
                if(parts.length%2!==0)malformed('A header object has an unmatched name/value');
                for(let index=0;index<parts.length;index+=2)add(parts[index],parts[index+1]);
            }
            text='{'+[...fields].map(([key,value])=>JSON.stringify(key)+':'+value).join(',')+'}';
        }
    }
    return {subject:'response-header',location:name,text,schema};
}
