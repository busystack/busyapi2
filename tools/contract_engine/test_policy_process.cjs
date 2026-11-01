const {test}=require('node:test');
const assert=require('node:assert/strict');
const {once}=require('node:events');
const fs=require('node:fs');
const {tmpdir}=require('node:os');
const path=require('node:path');
const {spawn}=require('node:child_process');
const {createInterface}=require('node:readline');
const transport=process.env.BUSYAPI_TEST_POLICY_TRANSPORT??require.resolve('./dist/policy_process_worker.cjs');
const {PolicyProcessWorker}=require(transport);
const launcher=process.env.BUSYAPI_TEST_POLICY_LAUNCHER;
assert(launcher&&path.isAbsolute(launcher),'Provision the exact native startup gate and select it explicitly');
const folder=fs.mkdtempSync(path.join(tmpdir(),'busyapi-policy-process-'));
const helper=path.join(folder,'bounded controlled entry.cjs');
fs.writeFileSync(helper,`
let input=Buffer.alloc(0);
process.stdin.on('data',data=>input=Buffer.concat([input,data]));
process.stdin.on('end',async()=>{
 const request=JSON.parse(input.subarray(4));
 const mode=request.params.mode;
 const frame={protocol:1,id:request.id,snapshot:request.params.snapshot,ok:true,
  result:{pid:process.pid,environment:Object.keys(process.env),value:'actual awaited result'}};
 const output=(value)=>{const payload=Buffer.from(JSON.stringify(value)),header=Buffer.alloc(4);header.writeUInt32BE(payload.length);return Buffer.concat([header,payload]);};
 if(mode==='stderr')process.stderr.write('controlled non-sensitive output'.repeat(4000));
 if(mode==='wrong-id')frame.id='a-different-request';
 if(mode==='wrong-snapshot')frame.snapshot='a-different-snapshot';
 if(mode==='partial'){process.stdout.write(Buffer.from([0,0,2]));return;}
 if(mode==='utf8'){process.stdout.write(Buffer.from([0,0,0,2,255,255]));return;}
 if(mode==='oversized'){process.stdout.write(Buffer.alloc(65536*1025));return;}
 if(mode==='empty')return;
 await new Promise(resolve=>setTimeout(resolve,5));
 process.stdout.write(output(frame));
 if(mode==='extra')process.stdout.write(output(frame));
 if(mode==='hang'){setInterval(()=>{},1000);return;}
 if(mode==='crash'){process.exitCode=7;return;}
 await new Promise(resolve=>setTimeout(resolve,40));
});
`);
process.on('exit',()=>fs.rmSync(folder,{recursive:true,force:true}));
function make(deadline=2000,assets={launcher,node:process.execPath,helper}){return new PolicyProcessWorker(assets,deadline);}
function request(mode){return {id:'owned-request',method:'govern',params:{snapshot:'frozen-source',mode}};}
function stopped(pid){assert.throws(()=>process.kill(pid,0),error=>error.code==='ESRCH','A response or cancellation left its process alive');}
function bounded(promise,deadline=5000){return new Promise((resolve,reject)=>{
 const timer=setTimeout(()=>reject(Error('Controlled process test exceeded its diagnostic deadline')),deadline);
 promise.then(value=>{clearTimeout(timer);resolve(value);},error=>{clearTimeout(timer);reject(error);});
});}
test('a response waits for actual exit and complete output; only captured identity crosses IPC',async()=>{
 const worker=make(),message=once(worker,'message');worker.postMessage(request('valid'));
 const [bytes]=await message,frame=JSON.parse(new TextDecoder().decode(bytes));
 assert.equal(frame.id,'owned-request');assert.equal(frame.snapshot,'frozen-source');assert.equal(frame.result.value,'actual awaited result');
 assert.deepEqual(frame.result.environment,['LD_LIBRARY_PATH']);stopped(frame.result.pid);
 assert.equal(await worker.terminate(),0);
});
for(const [mode,code]of [['crash','policy.process.exit'],['empty','policy.process.protocol'],
 ['wrong-id','policy.process.protocol'],['wrong-snapshot','policy.process.protocol'],
 ['partial','policy.process.protocol'],['utf8','policy.process.protocol'],
 ['extra','policy.process.protocol'],['stderr','policy.process.logs'],['oversized','policy.process.frame'],['hang','policy.process.timeout']])
test(`failed ${mode} execution cannot become empty success or leave a child`,async()=>{
 const worker=make(mode==='hang'?250:2000),errors=once(worker,'error');let messages=0;
 worker.on('message',()=>messages++);worker.postMessage(request(mode));
 const pid=worker.child.pid,[error]=await errors;
 assert.equal(error.code,code);assert.equal(error.message,'Required governance execution did not complete');assert.equal(messages,0);
 stopped(pid);await worker.terminate();
});
test('cancellation after a complete frame rejects that frame and awaits real exit',async()=>{
 const worker=make(),events=[];
 worker.on('message',()=>events.push('message'));worker.on('error',()=>events.push('error'));
 worker.postMessage(request('hang'));
 const pid=worker.child.pid;
 await bounded(Promise.race([once(worker.child.stdout,'data'),once(worker,'error').then(([error])=>{throw error;})]));
 const first=worker.terminate();assert.equal(worker.terminate(),first);await first;
 assert.deepEqual(events,[]);stopped(pid);
});
test('repeated captured cancellation never waits on output after premature closure',async()=>{
 for(let index=0;index<20;index++){
  const worker=make(),events=[];worker.on('message',()=>events.push('message'));worker.on('error',()=>events.push('error'));
  worker.postMessage(request('hang'));const child=worker.child,pid=child.pid;
  try{
   await bounded(Promise.race([once(child.stdout,'data'),once(worker,'error').then(([error])=>{throw error;}),
    once(child,'close').then(()=>{throw Error('Controlled child closed before its captured readiness frame');})]));
  }finally{await worker.terminate();}
  assert.deepEqual(events,[]);stopped(pid);
 }
});
test('immediate cancellation and cancellation before submission are owned terminal states',async()=>{
 for(const submitted of [false,true]){
  const worker=make(),events=[];worker.on('message',()=>events.push('message'));worker.on('error',()=>events.push('error'));
  if(submitted)worker.postMessage(request('hang'));
  const pid=worker.child?.pid;await worker.terminate();
  assert.throws(()=>worker.postMessage(request('valid')));assert.deepEqual(events,[]);if(pid)stopped(pid);
 }
});
test('missing assets fail explicitly without a normal-Node fallback',async()=>{
 const worker=make(2000,{launcher:path.join(folder,'missing launcher'),node:process.execPath,helper}),errors=once(worker,'error');
 worker.postMessage(request('valid'));const [error]=await errors;assert.equal(error.code,'policy.process.start');
 await worker.terminate();
});
test('malformed submission never launches code or returns data',async()=>{
 const worker=make(),errors=once(worker,'error');
 worker.postMessage({id:'owned',method:'not-governance',params:{}});
 const [error]=await errors;assert.equal(error.code,'policy.process.input');assert.equal(worker.child,undefined);
 await worker.terminate();
});
test('native startup kills the child when its owner dies, even before orderly cancellation',async()=>{
 const parentEntry=path.join(folder,'controlled owner.cjs');
 fs.writeFileSync(parentEntry,`
 const {PolicyProcessWorker}=require(${JSON.stringify(require.resolve(transport))});
 const worker=new PolicyProcessWorker(${JSON.stringify({launcher,node:process.execPath,helper})});
 worker.on('error',()=>process.exit(3));worker.postMessage(${JSON.stringify(request('hang'))});
 worker.child.stdout.once('data',()=>process.stdout.write(JSON.stringify({pid:worker.child.pid})+'\\n'));
 process.stdin.once('data',()=>process.exit(0));
 `);
 const parent=spawn(process.execPath,[parentEntry],{env:{},stdio:['pipe','pipe','pipe']}),reader=createInterface({input:parent.stdout});
 let pid;
 try{
  const [line]=await bounded(once(reader,'line'));pid=JSON.parse(line).pid;
  const exited=once(parent,'close');parent.stdin.end('terminate controlled owner');await exited;
  let terminated=false;
  for(let attempt=0;attempt<100;attempt++){
   try{process.kill(pid,0);
    // An orphan may be awaiting the host reaper. A zombie has no threads,
    // executable code, sockets or live file handles; never accept a live state.
    if(fs.readFileSync('/proc/'+pid+'/stat','utf8').split(') ')[1].startsWith('Z')){terminated=true;break;}
   }catch(error){if(error.code==='ESRCH'||error.code==='ENOENT'){terminated=true;break;}throw error;}
   await new Promise(resolve=>setTimeout(resolve,10));
  }
  assert.equal(terminated,true,'A live child survived the native owner');
 }finally{reader.close();if(parent.exitCode===null)parent.kill('SIGKILL');if(pid){try{process.kill(pid,'SIGKILL');}catch(error){if(error.code!=='ESRCH')throw error;}}}
});
test('the real restricted entry retains shared graph findings and never authorizes code',async()=>{
 const entry=process.env.BUSYAPI_TEST_POLICY_ENTRY;
 assert(entry&&path.isAbsolute(entry),'Build and select the actual restricted policy entry');
 const {govern}=require(process.env.BUSYAPI_TEST_POLICY_GOVERNANCE??'./dist/governance.cjs');
 for(const version of ['3.1.2','3.2.1']){
  const root='file:///approved/root.json',fragment='file:///approved/models.json',rules='file:///approved/.spectral.yaml';
  const marker=path.join(folder,'must-not-run-'+version);
  const input={root,snapshot:'restricted-shared-graph-'+version,resources:[
   {id:root,generation:1,text:JSON.stringify({openapi:version,info:{title:'Restricted governance',version:'1'},paths:{'/p':{get:{responses:{200:{description:'Read',content:{'application/json':{schema:{$ref:'models.json#/$defs/Model'},example:{$ref:'literal payload'}}}}}}}}})},
   {id:fragment,generation:3,text:'{"$defs":{"Model":{"type":"object","properties":{"next":{"$ref":"#/$defs/Model"}}}}}'},
  ],policy:{source:rules,entries:[rules],resources:[
   {id:rules,text:'extends: busyapi:recommended\nfunctions: [danger]\nrules:\n  danger:\n    given: $\n    then: {function: danger}\n'},
   {id:'file:///approved/functions/danger.js',text:'require("fs").writeFileSync('+JSON.stringify(marker)+',"MUST NOT EXECUTE");'},
  ]}};
  const expected=await govern(input),worker=make(10000,{launcher,node:process.execPath,helper:entry}),answer=once(worker,'message');
  worker.postMessage({id:'actual-restricted',method:'govern',params:input});
  const received=[];worker.child.stdout.on('data',chunk=>received.push(chunk));
  const [bytes]=await bounded(answer,12000).catch(error=>{
   const bytes=Buffer.concat(received);let headers;
   try{const frame=JSON.parse(bytes.subarray(4));headers={protocol:frame.protocol,id:frame.id,snapshot:frame.snapshot,ok:frame.ok,errorCode:frame.error?.code};}catch{}
   throw Object.assign(Error('Controlled native entry transport failed: '+JSON.stringify({code:error.code,bytes:bytes.length,announced:bytes.length>=4?bytes.readUInt32BE(0):null,headers})),{cause:error});
  }),frame=JSON.parse(new TextDecoder().decode(bytes));
  assert.equal(frame.ok,true,JSON.stringify(frame));assert.deepEqual(frame.result,expected);
  assert.equal(frame.result.complete,false);assert(frame.result.findings.some(finding=>finding.code==='policy.code.approval-required'));
  assert(frame.result.findings.some(finding=>finding.code==='policy.rule.operation-summary'));
  assert.equal(fs.existsSync(marker),false);await worker.terminate();
 }
});
