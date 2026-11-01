import {EventEmitter} from 'node:events';
import {spawn,ChildProcessWithoutNullStreams} from 'node:child_process';
import {dirname,isAbsolute,resolve} from 'node:path';
import type {DispatchRequest,DispatchWorker} from './worker_dispatcher';

const maxFrame=64*1024*1024;

/** One owned governance child, never a Node Worker used as an isolation claim.
 * The fixed trusted entry MUST install both native stages before loading any
 * project code. This class only owns transport/lifetime; it grants no trust.
 * No child result is delivered until actual exit AND all output have completed.
 */
export class PolicyProcessWorker extends EventEmitter implements DispatchWorker {
    readonly disposable=true;
    private child?:ChildProcessWithoutNullStreams;
    private closed=false;
    private submitted=false;
    private stopping=false;
    private delivered=false;
    private code=-1;
    private finished:Promise<number>;
    private finish!:(code:number)=>void;
    private termination?:Promise<number>;
    private timer?:ReturnType<typeof setTimeout>;
    private failure?:string;
    private bytes:Buffer[]=[];
    private length=0;
    private expected?:number;
    private logs=0;
    private readonly assets:{launcher:string;node:string;helper:string};
    constructor(assets:{launcher:string;node:string;helper:string},private deadline=15000) {
        super();
        if(Object.values(assets).some(value=>typeof value!=='string'||!isAbsolute(value))||!Number.isSafeInteger(deadline)||deadline<1||deadline>20000)
            throw Error('Choose fixed installed governance assets and a bounded deadline');
        this.assets=Object.freeze({...assets});
        this.finished=new Promise(resolve=>{this.finish=resolve;});
    }
    postMessage(request:DispatchRequest):void {
        if(this.submitted||this.stopping)throw Error('A governance child owns only one captured job');
        this.submitted=true;
        let payload:Buffer;
        try {
            if(request.method!=='govern'||typeof request.id!=='string'||typeof request.params?.snapshot!=='string')throw Error();
            payload=Buffer.from(JSON.stringify({protocol:1,...request}));
            if(payload.length<2||payload.length>maxFrame)throw Error();
        } catch {this.finishWithoutChild('policy.process.input');return;}
        const id=request.id,snapshot=request.params.snapshot;
        try {
            this.child=spawn(this.assets.launcher,[this.assets.node,'--disable-proto=throw',
                '--max-old-space-size=512','--stack-size=4096',this.assets.helper],{
                cwd:dirname(this.assets.helper),env:{LD_LIBRARY_PATH:resolve(dirname(this.assets.node),'../../lib')},
                stdio:['pipe','pipe','pipe'],windowsHide:true,
            });
        } catch {this.finishWithoutChild('policy.process.start');return;}
        const child=this.child;
        this.timer=setTimeout(()=>this.fail('policy.process.timeout'),this.deadline);
        child.once('error',()=>this.fail('policy.process.start'));
        child.stdin.on('error',()=>this.fail('policy.process.input'));
        child.stdout.on('error',()=>this.fail('policy.process.output'));
        child.stderr.on('error',()=>this.fail('policy.process.output'));
        child.stderr.on('data',(chunk:Buffer)=>{
            // Never retain or forward code logs: they can contain contracts,
            // credentials and private paths. Excess output is execution failure.
            this.logs+=chunk.length;if(this.logs>65536)this.fail('policy.process.logs');
        });
        child.stdout.on('data',(chunk:Buffer)=>{
            if(this.stopping||this.failure)return;
            this.length+=chunk.length;
            if(this.length>maxFrame+4) {this.fail('policy.process.frame');return;}
            this.bytes.push(chunk);
            if(this.expected===undefined&&this.length>=4) {
                this.expected=(this.bytes[0].length>=4?this.bytes[0]:Buffer.concat(this.bytes,4)).readUInt32BE(0);
                if(this.expected<2||this.expected>maxFrame) {this.fail('policy.process.frame');return;}
            }
            if(this.expected!==undefined&&this.length>this.expected+4)this.fail('policy.process.protocol');
        });
        child.once('close',(code)=>{
            this.closed=true;this.code=code??-1;clearTimeout(this.timer);
            const bytes=Buffer.concat(this.bytes,this.length);this.bytes=[];this.length=0;
            this.finish(this.code);
            if(this.stopping)return;
            if(this.failure||this.code!==0) {this.deliverFailure(this.failure??'policy.process.exit');return;}
            try {
                if(bytes.length<6||bytes.readUInt32BE(0)!==bytes.length-4)throw Error();
                const payload=bytes.subarray(4),frame=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(payload));
                if(frame?.protocol!==1||frame.id!==id||frame.snapshot!==snapshot||typeof frame.ok!=='boolean')throw Error();
                this.delivered=true;this.emit('message',new Uint8Array(payload));
            } catch {this.deliverFailure('policy.process.protocol');}
        });
        const header=Buffer.alloc(4);header.writeUInt32BE(payload.length);
        child.stdin.end(Buffer.concat([header,payload]));
    }
    private finishWithoutChild(code:string) {
        this.closed=true;this.finish(-1);
        // Match asynchronous Worker failure semantics. The dispatcher installs
        // listeners before postMessage; never turn a start failure into data.
        queueMicrotask(()=>{if(!this.stopping)this.deliverFailure(code);});
    }
    private deliverFailure(code:string) {
        if(this.delivered||this.stopping)return;
        this.delivered=true;
        this.emit('error',Object.assign(Error('Required governance execution did not complete'),{code}));
    }
    failureFor(error:unknown) {
        const code=typeof (error as any)?.code==='string'&&/^policy\.process\.[a-z-]+$/.test((error as any).code)?(error as any).code:'policy.process.failed';
        return {code,message:'Required governance execution did not complete'};
    }
    private fail(code:string) {
        if(this.closed||this.stopping)return;
        this.failure??=code;
        this.bytes=[];this.length=0;
        // Do not report completion on kill submission. The close event owns
        // failure delivery after the real process and its streams have stopped.
        this.child?.kill('SIGKILL');
    }
    terminate():Promise<number> {
        if(this.termination)return this.termination;
        this.stopping=true;clearTimeout(this.timer);
        if(!this.submitted)this.finishWithoutChild('policy.process.cancelled');
        if(!this.closed)this.child?.kill('SIGKILL');
        this.termination=new Promise((resolve,reject)=>{
            const timer=setTimeout(()=>reject(Error('Cannot complete governance process termination')),2000);
            this.finished.then(code=>{clearTimeout(timer);resolve(code);},error=>{clearTimeout(timer);reject(error);});
        });
        return this.termination;
    }
}
