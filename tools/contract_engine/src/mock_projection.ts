import type {TextSerialization} from './runtime_media';
import {SourceError,type Range} from './document';
import {record} from './engine_worker_client';
import {mediaTypeChoice,mediaTypes} from './media_types';
import type {RuntimeFormTarget} from './runtime_form';
import type {RuntimeMediaTarget} from './runtime_media_owner';
import type {SwaggerHeaderTarget} from './swagger_wire';
import type {RuntimeHeaderTarget} from './runtime_headers';

export type SchemaLocation={resource:string;pointer:string};
export type SourceLocation=SchemaLocation&{range:Range};
export type NativeMockCheck={complete:boolean;valid:boolean;findings:Record<string,unknown>[]};
export type NativeRuntimeEvaluation={subject:string;location:string;complete:boolean;valid:boolean;chosen?:number};
export type NativeRuntimeCheck=NativeMockCheck&{evaluations:NativeRuntimeEvaluation[]};
export type NativeMedia={mediaType:string;schema?:SchemaLocation;itemSchema?:SchemaLocation;mediaOwner?:RuntimeMediaTarget;formOwner?:RuntimeFormTarget};
export type NativeRuntimeInstance={subject:string;location:string;text:string;schema?:SchemaLocation;itemSchema?:SchemaLocation;media?:RuntimeMediaTarget;mediaType?:string;mediaBase64?:boolean;unicodeSerialization?:boolean;textSerialization?:TextSerialization;form?:RuntimeFormTarget;alternatives?:string[];swaggerHeader?:SwaggerHeaderTarget;header?:RuntimeHeaderTarget};

export const schemaLocation=(value:unknown):SchemaLocation|undefined=>record(value)&&typeof value.resource==='string'&&typeof value.pointer==='string'
    ?{resource:value.resource,pointer:value.pointer}:undefined;
export function sourceLocation(value:unknown):SourceLocation|undefined {
    const source=schemaLocation(value);
    if(!source||!record(value)||!Array.isArray(value.range)||value.range.length!==2)return;
    const [start,end]=value.range;
    if(typeof start!=='number'||typeof end!=='number'||!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||end<start)return;
    return {...source,range:[start,end]};
}

/** Decode the canonical projection at the adapter boundary. No transformed
 * third-party schema becomes an evaluator input. */
export function nativeMedia(value:unknown,occurrence?:string):NativeMedia[] {
    if(!Array.isArray(value)||value.length>2048)throw new SourceError('mock.validation.protocol','The native content projection is malformed');
    return value.map((media:unknown)=>{
        if(!record(media)||typeof media.mediaType!=='string')throw new SourceError('mock.validation.protocol','The native media projection is malformed');
        const schema=schemaLocation(media.schema),itemSchema=schemaLocation(media.itemSchema);
        if(media.schema!==undefined&&!schema||media.itemSchema!==undefined&&!itemSchema)
            throw new SourceError('mock.validation.protocol','The native media projection omitted a schema identity');
        const formOwner=schemaLocation(media.definition??media.source);
        return {mediaType:media.mediaType,schema:record(media.schema)&&media.schema.unconstrained===true?undefined:schema,itemSchema,
            ...(formOwner?{mediaOwner:formOwner,formOwner:{...formOwner,...(media.swaggerForm!==undefined&&occurrence!==undefined?{occurrence}:{})}}:{})};
    });
}

export function selectNativeMedia<T extends Pick<NativeMedia,'mediaType'>>(content:readonly T[],actual:string):T|undefined {
    const matches=content.filter(media=>{
        try{mediaTypeChoice(media.mediaType,actual);return true;}
        catch(error){if(error instanceof SourceError&&error.code==='request.form.content-type')return false;throw error;}
    }).map(media=>{
        const types=mediaTypes(media.mediaType);
        if(types.length!==1)throw new SourceError('mock.content-type','A content map key must contain one media type or range');
        const type=types[0];return {media,rank:(type.type==='*'?0:2)+(type.subtype==='*'?0:1),parameters:type.parameters.size};
    }).sort((a,b)=>b.rank-a.rank||b.parameters-a.parameters);
    if(matches.length>1&&matches[0].rank===matches[1].rank&&matches[0].parameters===matches[1].parameters)
        throw new SourceError('mock.content-type.ambiguous','Equally specific content declarations need an explicit interpretation',[0,0],'unsupported');
    return matches[0]?.media;
}

/** Recover the original native media declaration after the consumer selects
 * a response and representation. Third-party schema samples are not examples
 * authored on this declaration. */
export function capturedMockResponseMedia(plan:unknown,status:string,actual:string):Record<string,any>|undefined {
    if(!record(plan)||!record(plan.operation)||!Array.isArray(plan.responses))
        throw new SourceError('mock.validation.protocol','The captured response sample projection is malformed');
    const declaration=plan.responses.filter(record).find(value=>value.status===status);
    if(!declaration)return;
    const media=selectNativeMedia(nativeMedia(declaration.content),actual);
    if(!media)return;
    const raw=Array.isArray(declaration.content)?declaration.content.find(value=>record(value)&&value.mediaType===media.mediaType):undefined;
    if(!record(raw)||!Array.isArray(raw.examples)||raw.examples.some(value=>!record(value)))
        throw new SourceError('mock.validation.protocol','The captured media examples are malformed');
    return raw;
}
