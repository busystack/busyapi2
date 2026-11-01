import type {IHttpOperation,IMediaTypeContent} from '@stoplight/types';
import type {Logger} from 'pino';
import type {MockNativeValidation} from './mock_native_validation';
import {record} from './engine_worker_client';
import {SourceError} from './document';
import {transformOas2Operation} from '@stoplight/http-spec/oas2/operation';
import {OPERATION_CONFIG} from '@stoplight/http-spec/oas';

const {createInvalidInputResponse}:typeof import('@stoplight/prism-http/dist/mocker')=require('@stoplight/prism-http/dist/mocker');
const {default:negotiator}:typeof import('@stoplight/prism-http/dist/mocker/negotiator/NegotiatorHelpers')=require('@stoplight/prism-http/dist/mocker/negotiator/NegotiatorHelpers');
type Configuration=Parameters<typeof negotiator.negotiateOptionsForValidRequest>[1];
type Diagnostic=Parameters<typeof createInvalidInputResponse>[0][number];
type GeneratorData=Exclude<NonNullable<IMediaTypeContent['schema']>['const'],undefined>;

function generatorData(value:unknown,depth=0):value is GeneratorData {
    if(depth>128)return false;
    return value===null||['string','boolean','number'].includes(typeof value)||
        Array.isArray(value)&&value.every(child=>generatorData(child,depth+1))||
        record(value)&&Object.values(value).every(child=>generatorData(child,depth+1));
}

/** An unspecified Swagger representation permits JSON. Supply this concrete
 * generator default only where http-spec otherwise drops a declared schema;
 * existing examples and bodyless responses keep their original projection. */
export function defaultSwaggerResponseMedia(document:Record<string,unknown>,operation:IHttpOperation):IHttpOperation {
    if(!operation.responses.some(response=>!response.contents?.length))return operation;
    const paths=document.paths,path=record(paths)?paths[operation.path]:undefined;
    const source=record(path)?path[operation.method]:undefined;
    if(!record(paths)||!record(path)||!record(source))
        throw new SourceError('mock.validation.protocol','The captured Swagger operation has no derived media owner');
    const projected={...document,paths:{...paths,[operation.path]:{...path,[operation.method]:{...source,produces:['application/json']}}}};
    const fallback=transformOas2Operation({document:projected,name:operation.path,method:operation.method,config:OPERATION_CONFIG});
    return {...operation,responses:operation.responses.map(response=>{
        if(response.contents?.length)return response;
        const replacement=fallback.responses.find(candidate=>candidate.code===response.code);
        return replacement?.contents?.some(content=>content.schema!==undefined)?replacement:response;
    })};
}

/** The pinned negotiator selects the response before native sample selection.
 * A request-owned view supplies the captured example or proved value to Prism; neither
 * the authored schema nor the native validator receives this derived view. */
export class MockGenerationAdapter {
    private readonly values=new WeakMap<IMediaTypeContent,string>();

    constructor(private readonly native:Pick<MockNativeValidation,'authoredResponse'|'generatedResponse'|'generationFailure'>) {}

    async prepare(operation:IHttpOperation,configuration:Configuration,diagnostics:readonly Diagnostic[],logger:Logger,signal:AbortSignal):Promise<{operation:IHttpOperation;configuration:Configuration}> {
        const unchanged={operation,configuration};
        const [first,...rest]=diagnostics;
        const result=first
            ?createInvalidInputResponse([first,...rest],operation.responses,configuration)(logger)
            :negotiator.negotiateOptionsForValidRequest(operation,configuration)(logger);
        if(result._tag==='Left')return unchanged;
        const selected=result.right;
        const response=operation.responses.find(value=>value.code===selected.code)
            ??operation.responses.find(value=>value.code===selected.code[0]+'XX')
            ??operation.responses.find(value=>value.code==='default');
        const content=response?.contents?.find(value=>value.mediaType===selected.mediaType);
        if(!response||!content)return unchanged;
        const essence=content.mediaType.split(';')[0].trim().toLowerCase();
        if(essence!=='application/json'&&!essence.endsWith('+json'))return unchanged;
        const dynamic=configuration.dynamic&&selected.bodyExample===undefined;
        // Invalid-input negotiation can suppress the requested example key.
        // Preserve its actual choice before skipping synthesized schema defaults.
        const keys=content.examples?.map(example=>example.key)??[];
        if(selected.bodyExample!==undefined)keys.unshift(selected.bodyExample.key);
        const authored=dynamic?undefined:this.native.authoredResponse(operation.path,operation.method,response.code,content.mediaType,
            keys,signal);
        const raw=authored??await this.native.generatedResponse(operation.path,operation.method,response.code,content.mediaType,dynamic,signal);
        if(raw===undefined)return unchanged;
        const value:unknown=JSON.parse(raw);
        if(!generatorData(value))throw this.native.generationFailure(operation.path,operation.method,'mock.sample.projection','The captured sample cannot cross the bounded generator data boundary');
        if(!/^\d{3}$/.test(selected.code))throw this.native.generationFailure(operation.path,operation.method,'mock.sample.status','The pinned negotiator did not select one concrete response status');
        const key=configuration.exampleKey||'busyapi:captured-schema-sample';
        const generated:IMediaTypeContent={...content,
            examples:[{id:content.id+':native-sample',key,value}]};
        this.values.set(generated,raw);
        return {
            operation:{...operation,responses:operation.responses.map(candidate=>candidate===response
                ?{...response,contents:response.contents?.map(candidate=>candidate===content?generated:candidate)}:candidate)},
            // Concretize the already selected status/body. Dynamic generation
            // remains enabled for headers; the proved body bypasses faker's
            // lossy object cloning, including literal __proto__ members.
            configuration:{...configuration,code:Number(selected.code),exampleKey:key},
        };
    }

    rawBody(content:IMediaTypeContent|undefined):string|undefined {
        return content&&this.values.get(content);
    }
}
