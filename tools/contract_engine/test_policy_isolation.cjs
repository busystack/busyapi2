// Real process/kernel tests. Not a substitute for trust, dependency collection,
// complete governance integration or a strict-confined deployment smoke.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const {mkdtempSync,mkdirSync,copyFileSync,writeFileSync,readFileSync,symlinkSync,rmSync}=require('node:fs');
const {tmpdir}=require('node:os');
const path=require('node:path');
const addon=process.env.BUSYAPI_TEST_POLICY_ISOLATION;
const launcher=process.env.BUSYAPI_TEST_POLICY_LAUNCHER;
const attempts=process.env.BUSYAPI_TEST_POLICY_ATTEMPTS;
assert(addon&&path.isAbsolute(addon),'Build the exact native profile and set BUSYAPI_TEST_POLICY_ISOLATION to its absolute file');
assert(launcher&&path.isAbsolute(launcher),'Build the exact startup gate and set BUSYAPI_TEST_POLICY_LAUNCHER to its absolute file');
assert(attempts&&path.isAbsolute(attempts),'Build the test-only syscall attempts and set BUSYAPI_TEST_POLICY_ATTEMPTS');
assert.equal(process.versions.node,'24.15.0','Use the pinned production Node');
function child(body,{restrict=true,files,timeout=10000}={}){
 const folder=mkdtempSync(path.join(tmpdir(),'busyapi-policy-kernel-'));
 const bootstrap=path.join(folder,'bootstrap');mkdirSync(bootstrap);
 const entry=path.join(bootstrap,'entry.mjs');
 const allowed=path.join(bootstrap,'approved.cjs'),denied=path.join(folder,'unapproved'),link=path.join(bootstrap,'link');
 copyFileSync(addon,path.join(bootstrap,'policy-isolation.node'));copyFileSync(attempts,path.join(bootstrap,'attempts.node'));
 writeFileSync(allowed,'module.exports = async () => "approved ✓";\n',{mode:0o400});
 writeFileSync(denied,'controlled, non-sensitive unapproved bytes\n');
 symlinkSync(allowed,link);
 const before=readFileSync(allowed,'utf8');
 const prelude=`
 import fs from 'node:fs';import net from 'node:net';import dgram from 'node:dgram';
 import {spawnSync} from 'node:child_process';import {Worker} from 'node:worker_threads';
 import assert from 'node:assert/strict';import {createRequire} from 'node:module';
 assert.deepEqual(Object.keys(process.env),['LD_LIBRARY_PATH']);
 assert.equal(process.env.LD_LIBRARY_PATH,${JSON.stringify(path.resolve(path.dirname(process.execPath),'../../lib'))});
 delete process.env.LD_LIBRARY_PATH;
 const require=createRequire(import.meta.url),isolation=require('./policy-isolation.node'),attempts=require('./attempts.node');
 const procPins=fs.readdirSync('/proc/self/fd').map(Number).filter(fd=>{try{return fd>2&&fs.readlinkSync('/proc/self/fd/'+fd)==='/proc/'+process.pid+'/fd';}catch{return false;}});
 assert.equal(procPins.length,1,'One launcher-owned proc inode pin must survive exec');
 const procPin=procPins[0];
 assert.equal(fs.fstatSync(procPin).isDirectory(),true);
 assert.throws(()=>fs.readSync(procPin,Buffer.alloc(1),0,1,null),{code:'EBADF'},'The pin is O_PATH, not readable directory data');
 const folder=${JSON.stringify(folder)},allowed=${JSON.stringify(allowed)},denied=${JSON.stringify(denied)},link=${JSON.stringify(link)};
 // Warm actual existing libuv threads. Both sync and async denials must hold.
 const approvedText=await fs.promises.readFile(allowed,'utf8'),approvedFunction=require(allowed);
 // Pre-existing pool threads inherit Landlock even BEFORE the final TSYNC seal.
 assert.throws(()=>fs.readFileSync(denied),{code:'EACCES'});
 await assert.rejects(fs.promises.readFile(denied),{code:'EACCES'});
 assert.throws(()=>fs.writeFileSync(allowed,'no'),{code:'EACCES'});
 await assert.rejects(fs.promises.writeFile(allowed,'no'),{code:'EACCES'});
 assert.equal(attempts.attempt('io-uring'),1,'Startup must deny rings before libuv initializes');
 ${restrict?`assert.equal(isolation.restrict(${files??'[]'},process.ppid),true);`:''}
 `;
 try{
  writeFileSync(entry,prelude+body);
  const result=spawnSync(launcher,[process.execPath,'--disable-proto=throw',entry],
   {env:{BUSYAPI_ISOLATION_TEST_MUST_NOT_INHERIT:'no'},cwd:folder,encoding:'utf8',timeout,killSignal:'SIGKILL',maxBuffer:65536});
  assert.equal(readFileSync(allowed,'utf8'),before,'Approved file was modified');
  assert.equal(readFileSync(denied,'utf8'),'controlled, non-sensitive unapproved bytes\n','Unapproved file was modified');
  return result;
 }finally{rmSync(folder,{recursive:true,force:true});}
}
function success(result){assert.ifError(result.error);assert.equal(result.signal,null,result.stderr);assert.equal(result.status,0,result.stderr);}
test('the exact O_PATH proc inode pin is consumed before captured code executes',()=>{
 success(child(`assert.throws(()=>fs.fstatSync(procPin),{code:'EBADF'});`));
});
test('a missing proc inspection pin cannot install an apparently successful seal',()=>{
 success(child(`fs.closeSync(procPin);assert.throws(()=>isolation.restrict([],process.ppid),{code:'policy.isolation.inherited-descriptor'});`,{restrict:false}));
});
test('native capability report is truthful without installing policy',()=>{
 const result=child(`const state=isolation.capabilities();assert(state.landlockAbi>=3);const version=state.libseccomp.split('.').map(Number);
 assert(version[0]>2||version[0]===2&&(version[1]>5||version[1]===5&&version[2]>=5));assert.equal(state.profile,2);
 assert.equal(fs.readFileSync(allowed,'utf8'),approvedText);`,{restrict:false});success(result);
});
test('the actual pinned Node still executes approved async CommonJS and timers',()=>{
 success(child(`assert.equal(await approvedFunction(),'approved ✓');await new Promise(resolve=>setTimeout(resolve,5));
 assert(approvedText.includes('approved ✓'));
 assert.deepEqual(Object.keys(process.env),[]);assert.throws(()=>isolation.restrict([],process.ppid),{code:'policy.isolation.already-installed'});`));
});
test('existing libuv threads and main thread cannot read unapproved files',()=>{
 success(child(`for(const target of [denied,allowed,process.execPath,'/proc/self/environ']){
 assert.throws(()=>fs.readFileSync(target),{code:'EPERM'});
 await assert.rejects(fs.promises.readFile(target),{code:'EPERM'});}
 assert.throws(()=>fs.readdirSync(folder),{code:'EPERM'});`));
});
test('approved content is read only, including async writes and metadata operations',()=>{
 success(child(`assert.throws(()=>fs.writeFileSync(allowed,'no'),{code:'EPERM'});
 await assert.rejects(fs.promises.writeFile(allowed,'no'),{code:'EPERM'});
 for(const invoke of [()=>fs.chmodSync(allowed,0o600),()=>fs.chownSync(allowed,process.getuid(),process.getgid()),
  ()=>fs.utimesSync(allowed,1,1),()=>fs.renameSync(allowed,allowed+'.moved'),
  ()=>fs.linkSync(allowed,allowed+'.hard'),()=>fs.symlinkSync(allowed,allowed+'.symbolic'),()=>fs.unlinkSync(allowed)])
  assert.throws(invoke,{code:'EPERM'});
 assert.throws(()=>fs.truncateSync(allowed,0),{code:'EPERM'});
 assert.throws(()=>process.chdir('/'),{code:'EPERM'});`));
});
test('socket creation is denied for IPv4, IPv6, UNIX and UDP, not merely redirected',()=>{
 success(child(`for(const options of [{host:'127.0.0.1',port:9},{host:'::1',port:9},{path:folder+'/never-created.sock'}])
  await new Promise(resolve=>{const socket=net.connect(options);socket.once('connect',()=>assert.fail('Unexpected connection'));
   socket.once('error',error=>{assert.equal(error.code,'EPERM');resolve();});});
 for(const family of ['udp4','udp6'])await new Promise(resolve=>{const socket=dgram.createSocket(family);
  socket.once('error',error=>{assert.equal(error.code,'EPERM');resolve();});socket.bind(0);
 });`));
});
test('child processes and new worker threads cannot escape the restricted process',()=>{
 success(child(`const result=spawnSync(process.execPath,['--eval','process.exit(0)'],{env:{}});assert.equal(result.error.code,'EPERM');
 assert.throws(()=>new Worker('0',{eval:true}),error=>['EPERM','ERR_WORKER_INIT_FAILED'].includes(error.code));`));
});
test('native syscall attempts prove denial beyond JavaScript API checks',()=>{
 success(child(`for(const name of ['exec','fork','memfd','io-uring','ptrace','process-memory','ioctl','kill','parent-signal','filter','executable-file','openat2','file-handle','pidfd','splice','sendfile'])
  assert.equal(attempts.attempt(name),1,name+' did not return kernel EPERM');`));
});
test('anonymous allocation cannot bypass the kernel data-memory bound',()=>{
 success(child(`assert.equal(attempts.attempt('excessive-memory'),12,'Expected kernel ENOMEM without touching gigabytes of physical memory');
 assert.equal(Buffer.alloc(4096).length,4096);`));
});
test('an inherited open file capability fails closed before project code',()=>{
 success(child(`const fd=fs.openSync(allowed,'r');
 assert.throws(()=>isolation.restrict([],process.ppid),{code:'policy.isolation.inherited-descriptor'});
 fs.closeSync(fd);assert.equal(fs.readFileSync(allowed,'utf8'),approvedText);`,{restrict:false}));
});
test('a non-cooperative restricted child is actually terminated at its wall deadline',()=>{
 const result=child('fs.writeSync(1,"restricted-ready\\n");while(true){}',{timeout:250});
 assert.equal(result.stdout,'restricted-ready\n','The real restriction must install before measuring termination');
 assert.equal(result.error.code,'ETIMEDOUT');assert.equal(result.status,null);assert.equal(result.signal,'SIGKILL');
});
test('the allowlist accepts no symlink, directory or embedded NUL capability',()=>{
 for(const files of ['[link]','[folder]','[allowed+"\\0ignored"]'])
  success(child(`assert.throws(()=>isolation.restrict(${files},process.ppid),error=>error.code.startsWith('policy.isolation.'));
   assert.equal(fs.readFileSync(allowed,'utf8'),approvedText);`,{restrict:false}));
});
