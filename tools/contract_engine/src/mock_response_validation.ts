import {SourceError} from './document';
import {record} from './engine_worker_client';
import {mediaTypes} from './media_types';
import {runtimeMediaKind,runtimeFormMedia} from './runtime_media';
import {permitsMemberName,responseStatusNamePolicy} from './member_names';
import {isNativeFamily} from './specification';
import type {ReferenceGraph} from './reference_graph';
import {nativeMedia,selectNativeMedia,sourceLocation,type NativeMockCheck,type NativeRuntimeInstance,type SourceLocation} from './mock_projection';

type Evaluate=(instances:NativeRuntimeInstance[])=>Promise<NativeMockCheck>;
export const mockResponseProducer=Object.freeze({name:'busyapi-native-response',version:'3'});

/** The response's actual bytes, status and header fields are checked under the
 * same captured operation as request preparation. Prism owns generation and
 * negotiation, never a second interpretation of the captured Schema Objects. */
export async function validateMockResponse(graph:ReferenceGraph,plan:unknown,method:string,status:number,headers:unknown,bytes:Buffer,evaluate:Evaluate):Promise<NativeMockCheck> {
    if(!record(plan)||!record(plan.operation)||typeof plan.family!=='string'||!isNativeFamily(plan.family)||!Array.isArray(plan.responses)||plan.responses.length>2048||!record(headers))
        throw new SourceError('mock.validation.protocol','The native response projection is malformed');
    const operation=sourceLocation(plan.operation.source);
    if(!operation)throw new SourceError('mock.validation.protocol','The native operation projection omitted its source');
    const responses=plan.responses.map(value=>{
        if(!record(value)||typeof value.status!=='string')throw new SourceError('mock.validation.protocol','A native response declaration is malformed');
        return value;
    });
    const declaration=responses.find(value=>value.status===String(status))??responses.find(value=>value.status===`${Math.floor(status/100)}XX`)??responses.find(value=>value.status==='default');
    const findings:Record<string,unknown>[]=[],instances:NativeRuntimeInstance[]=[],sources=new Map<string,SourceLocation>();
    let complete=true;
    const issue=(code:string,message:string,subject:string,location:string,source:SourceLocation,severity:'error'|'warning'='error')=>{
        if(severity==='warning')complete=false;
        findings.push({code,message,subject,location,pointer:'',source,severity,...(severity==='warning'?{kind:'unsupported'}:{})});
    };
    if(!permitsMemberName(responseStatusNamePolicy(plan.family),String(status))){
        issue('runtime.response.status.invalid','The upstream response status is outside the HTTP status-code range','response-status',String(status),operation);
        return {complete:true,valid:false,findings};
    }
    if(!declaration){
        issue('runtime.response.status','The actual HTTP status is not declared by the captured operation','response-status',String(status),operation);
        return {complete:true,valid:false,findings};
    }
    const source=sourceLocation(declaration.source);
    if(!source||!Array.isArray(declaration.headers)||declaration.headers.length>2048)
        throw new SourceError('mock.validation.protocol','The native response omitted its source or headers');
    const received=new Map<string,string[]>();
    for(const [name,value]of Object.entries(headers)){
        if(value===undefined)continue;
        const values=typeof value==='string'?[value]:Array.isArray(value)&&value.every(item=>typeof item==='string')?value:undefined;
        if(!values)throw new SourceError('mock.validation.protocol','A received mock header has no string representation');
        received.set(name.toLowerCase(),[...(received.get(name.toLowerCase())??[]),...values]);
    }
    const add=(instance:NativeRuntimeInstance,source:SourceLocation)=>{
        if(instances.length>=2048){issue('runtime.response.limit','Response validation exceeds 2048 captured instances',instance.subject,instance.location,source,'warning');return;}
        instances.push(instance);sources.set(JSON.stringify([instance.subject,instance.location]),source);
    };
    for(const header of declaration.headers){
        if(!record(header)||typeof header.name!=='string'||typeof header.required!=='boolean')
            throw new SourceError('mock.validation.protocol','A native response header is malformed');
        const source=sourceLocation(header.definition)??sourceLocation(header.source);
        if(!source)throw new SourceError('mock.validation.protocol','A native response header omitted its source');
        const values=received.get(header.name.toLowerCase());
        if(!values?.length){if(header.required)issue('runtime.response.header.required','A required response header is absent','response-header',header.name,source);continue;}
        const occurrence=sourceLocation(header.source);
        if(!occurrence)throw new SourceError('mock.validation.protocol','A native response header omitted its captured occurrence');
        add({subject:'response-header',location:header.name,text:'',header:{resource:occurrence.resource,pointer:occurrence.pointer,name:header.name,values}},source);
    }
    const permitted=method!=='HEAD'&&status>=200&&![204,205,304].includes(status);
    if(!permitted&&bytes.length)issue('runtime.response.body.forbidden','This method and status do not permit response content','response-body','body',source);
    if(permitted&&declaration.bodyAllowed===false){
        const types=received.get('content-type');
        if(types)try{
            if(types.length!==1||mediaTypes(types[0],false).length!==1)throw new SourceError('runtime.response.media-type','A response requires one concrete Content-Type');
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            issue('runtime.response.media-type',error.message,'response-body','content-type',source,error.kind==='unsupported'?'warning':'error');
        }
        const owner=sourceLocation(declaration.definition)??source;
        add({subject:'response-body',location:'body',text:bytes.toString('base64'),mediaBase64:true,media:{resource:owner.resource,pointer:owner.pointer}},source);
    }else if(permitted){
        const content=nativeMedia(declaration.content),types=received.get('content-type');
        if(types&&types.length!==1)issue('runtime.response.media-type','A response requires one concrete Content-Type','response-body','content-type',source);
        else if(!types?.length){if(content.length)issue('runtime.response.media-type','The response has no Content-Type for its declared content','response-body','content-type',source);}
        else try{
            const actual=types[0],parsed=mediaTypes(actual,false);
            if(parsed.length!==1)throw new SourceError('runtime.response.media-type','A response requires one concrete Content-Type');
            const media=selectNativeMedia(content,actual);
            if(content.length&&!media)issue('runtime.response.media-type','The actual response Content-Type does not match its captured declaration','response-body','content-type',source);
            else if(media?.schema||media?.itemSchema||media?.mediaOwner||runtimeFormMedia(actual)&&media?.formOwner||runtimeMediaKind(actual)!=='opaque'){
                const form=runtimeFormMedia(actual)?media?.formOwner:undefined;
                add({subject:'response-body',location:actual,text:bytes.toString('base64'),mediaType:actual,mediaBase64:true,schema:media?.schema,itemSchema:media?.itemSchema,...(form?{form}:media?.mediaOwner?{media:media.mediaOwner}:{})},source);
            }
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            issue(error.kind==='unsupported'?'runtime.response.body.unchecked':'runtime.response.media-type',error.message,'response-body','content-type',source,error.kind==='unsupported'||error.code.startsWith('limit.')?'warning':'error');
        }
    }
    if(instances.length){
        const result=await evaluate(instances);
        complete=complete&&result.complete;
        findings.push(...result.findings.map(finding=>({...finding,
            ...(finding.source===undefined&&finding.schema===undefined?{source:sources.get(JSON.stringify([finding.subject,finding.location]))}: {})})));
        return {complete,valid:complete&&result.valid&&!findings.some(finding=>finding.severity==='error'),findings};
    }
    return {complete,valid:complete&&!findings.some(finding=>finding.severity==='error'),findings};
}
