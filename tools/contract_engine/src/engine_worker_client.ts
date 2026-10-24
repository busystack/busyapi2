import {join} from 'node:path';
import {Worker} from 'node:worker_threads';
import {SourceError,type Range} from './document';
import {WorkerDispatcher} from './worker_dispatcher';

const maximumFrame=64*1024*1024;
export const record=(value:unknown):value is Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const range=(value:unknown):value is Range=>Array.isArray(value)&&value.length===2&&value.every(Number.isSafeInteger)&&value[0]>=0&&value[1]>=value[0];

export function engineFailure(value:unknown):SourceError|undefined {
    if(!record(value)||typeof value.code!=='string'||typeof value.message!=='string'||value.kind!==undefined&&value.kind!=='unsupported'||value.range!==undefined&&!range(value.range))return;
    let source:SourceError['source'];
    if(value.source!==undefined){
        if(!record(value.source)||typeof value.source.resource!=='string'||typeof value.source.pointer!=='string'||!range(value.source.range))return;
        source={resource:value.source.resource,pointer:value.source.pointer,range:value.source.range};
    }
    return new SourceError(value.code,value.message,range(value.range)?value.range:undefined,value.kind==='unsupported'?'unsupported':undefined,source);
}
type Pending={resolve:(value:Record<string,unknown>)=>void;reject:(error:Error)=>void;timer:ReturnType<typeof setTimeout>;detach:()=>void;stopped?:SourceError};

/** An adapter client of the packaged engine, using its existing bounded worker
 * dispatcher. No schema evaluator, URI loader or semantic cache lives here. */
export class EngineWorkerClient {
    private serial=0n;
    private closed=false;
    private readonly pending=new Map<string,Pending>();
    private readonly dispatcher=new WorkerDispatcher(
        ()=>new Worker(join(__dirname,'engine.cjs'),{resourceLimits:{maxOldGenerationSizeMb:512,stackSizeMb:8}}),
        payload=>this.reply(payload),
        (id,code,message)=>this.finish(id,undefined,this.pending.get(id)?.stopped??new SourceError(code,message)),maximumFrame);

    request(method:'deriveBundle'|'evaluateSchemas',params:Record<string,unknown>,signal?:AbortSignal):Promise<Record<string,unknown>> {
        if(this.closed)return Promise.reject(new SourceError('worker.closed','The native validation owner is closed'));
        if(signal?.aborted)return Promise.reject(new SourceError('cancelled','The native validation request was cancelled'));
        if(Buffer.byteLength(JSON.stringify(params))>maximumFrame)return Promise.reject(new SourceError('limit.request','The native validation input exceeds 64 MiB'));
        const id='mock-native-'+(++this.serial).toString();
        return new Promise((resolve,reject)=>{
            const stop=(error:SourceError)=>{
                const pending=this.pending.get(id);if(!pending||pending.stopped)return;
                pending.stopped=error;
                void this.dispatcher.stop(id).catch(()=>this.finish(id,undefined,new SourceError('worker.termination','The native validation worker did not terminate')));
            };
            const abort=()=>stop(new SourceError('cancelled','The native validation request was cancelled'));
            const timer=setTimeout(()=>stop(new SourceError('worker.deadline','Native validation exceeded its 30 second deadline')),30000);
            this.pending.set(id,{resolve,reject,timer,detach:()=>signal?.removeEventListener('abort',abort)});
            signal?.addEventListener('abort',abort,{once:true});
            this.dispatcher.submit({id,method,params});
        });
    }

    private reply(payload:Uint8Array):void {
        let value:unknown;
        try {value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(payload));}
        catch {this.failProtocol();return;}
        if(!record(value)||value.protocol!==1||typeof value.id!=='string'||!this.pending.has(value.id)){this.failProtocol();return;}
        if(value.ok===true&&record(value.result))this.finish(value.id,value.result);
        else if(value.ok===false){
            const error=engineFailure(value.error);
            if(error)this.finish(value.id,undefined,error);else this.failProtocol();
        }
        else this.failProtocol();
    }

    private finish(id:string,result?:Record<string,unknown>,error?:Error):void {
        const pending=this.pending.get(id);if(!pending)return;
        this.pending.delete(id);clearTimeout(pending.timer);pending.detach();
        if(error)pending.reject(error);
        else if(result)pending.resolve(result);
        else pending.reject(new SourceError('worker.protocol','Native validation omitted its result'));
    }

    private failProtocol():void {
        for(const id of this.pending.keys())this.finish(id,undefined,new SourceError('worker.protocol','Native validation returned an invalid response'));
        void this.close().catch(error=>queueMicrotask(()=>{throw error;}));
    }

    async close():Promise<void> {
        this.closed=true;
        await this.dispatcher.close();
    }
}
