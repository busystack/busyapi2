import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {govern} from './governance';
import {SourceError} from './document';
import {loadPolicyCode,ExecutedPolicyCode} from './policy_code_loader';

// Dedicated one-request process entry. All trusted modules initialize before
// restrictions. There is no import of project code here: that authority still
// requires the reviewed immutable closure and explicit trust integration.
const maxFrame=64*1024*1024;
const requireNative=createRequire(__filename);
// Initialize the already-owned stdio handles before the default-deny profile.
// Node otherwise lazily configures its IPC stream after restrictions install.
const output=process.stdout;
void process.stderr;
// An unresolved Promise alone does not keep a standalone Node process alive.
// This one owned request remains live until a flushed reply or parent timeout.
const keepAlive=setInterval(()=>{},1000);
let bytes=Buffer.alloc(0),submitted=false;
const reply=(request:any,result:any)=>{
    const payload=Buffer.from(JSON.stringify({protocol:1,id:request.id,snapshot:request.params?.snapshot,...result}));
    if(payload.length>maxFrame)process.exit(2);
    const header=Buffer.alloc(4);header.writeUInt32BE(payload.length);
    output.write(Buffer.concat([header,payload]),error=>{clearInterval(keepAlive);process.exit(error?2:0);});
};
process.stdin.on('data',(data:Buffer)=>{
    if(submitted||bytes.length+data.length>maxFrame+4)process.exit(3);
    bytes=Buffer.concat([bytes,data]);
    if(bytes.length>=4&&(bytes.readUInt32BE(0)<2||bytes.readUInt32BE(0)>maxFrame))process.exit(3);
});
process.stdin.once('end',async()=>{
    if(submitted)return;submitted=true;
    let request:any,phase='input',executed:ExecutedPolicyCode|undefined;
    try {
        if(process.versions.node!=='24.15.0'||bytes.length<6||bytes.readUInt32BE(0)!==bytes.length-4)throw Error();
        request=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes.subarray(4)));bytes=Buffer.alloc(0);
        if(request?.protocol!==1||typeof request.id!=='string'||request.method!=='govern'||typeof request.params?.snapshot!=='string')throw Error();
        phase='assets';
        const isolation=requireNative(join(__dirname,'policy-isolation.node'));
        // These threads inherit the launcher's pre-exec Landlock restrictions.
        // The final seccomp TSYNC seal must cover this actual existing pool.
        await readFile(__filename);
        // Node's authentic CommonJS/require(ESM) path lazily caches its fixed
        // installed working directory. Warm it while still in trusted startup;
        // project code gets no getcwd/chdir or ambient filesystem capability.
        process.cwd();
        phase='isolation';
        if(isolation.restrict([],process.ppid)!==true)throw Error();
        delete process.env.LD_LIBRARY_PATH;
        if(request.params.policy?.execution) {
            phase='code';executed=await loadPolicyCode(request.params);
        }
        phase='governance';
        const result=await govern(request.params,undefined,executed);
        reply(request,{ok:true,result});
    } catch(error:any) {
        const code=phase==='isolation'&&typeof error?.code==='string'&&/^policy\.isolation\.[a-z-]+$/.test(error.code)?error.code:
            ['code','governance'].includes(phase)&&error instanceof SourceError?error.code:
            'policy.execution.'+phase;
        if(!request||typeof request.id!=='string')process.exit(3);
        reply(request,{ok:false,error:{code,message:'Required governance execution did not complete'}});
    } finally {
        executed?.close();
    }
});
