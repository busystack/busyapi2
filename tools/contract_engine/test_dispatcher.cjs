const assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const {test}=require('node:test');
const {WorkerDispatcher}=require('./dist/worker_dispatcher.cjs');
class Worker extends EventEmitter {
 sent=[];stopped=false;
 postMessage(value){this.sent.push(value);}
 terminate(){this.stopped=true;return this.gate??Promise.resolve(0);}
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));
function harness(kind){
 const workers=[],outputs=[],failures=[];
 const dispatcher=new WorkerDispatcher(request=>{const w=new Worker();w.kind=kind?.(request)??'standard';w.disposable=w.kind==='isolated';workers.push(w);return w;},p=>outputs.push(p),(id,code,message)=>failures.push({id,code,message}),1024,kind);
 const submit=(id,method='inspect',params={})=>dispatcher.submit({id,method,params:{snapshot:id,...params}});
 return {dispatcher,workers,outputs,failures,submit};
}
const policyKind=request=>request.method==='govern'&&request.params.isolated?'isolated':'standard';
test('isolated governance changes worker kind only after retirement and preserves the foreground cache',async()=>{
 const h=harness(policyKind);
 h.submit('source','analyse');h.workers[0].emit('message',new Uint8Array([1,2]));
 h.submit('schema','evaluateSchemas');h.workers[1].emit('message',new Uint8Array([1,2]));
 let finish;h.workers[1].gate=new Promise(resolve=>finish=resolve);
 h.submit('isolated','govern',{isolated:true});
 assert.equal(h.workers.length,2);assert.equal(h.workers[1].stopped,false);
 await flush();assert.equal(h.workers[1].stopped,true);assert.equal(h.workers[0].stopped,false);
 assert.equal(h.workers.length,2,'A retiring standard worker still owns its slot');
 h.submit('typing','analyse');assert.equal(h.workers[0].sent.at(-1).id,'typing');
 finish(0);await flush();assert.equal(h.workers.length,3);assert.equal(h.workers[2].kind,'isolated');
 assert.equal(h.workers[2].sent[0].id,'isolated');assert.equal(h.workers[0].stopped,false);
 h.workers[0].emit('message',new Uint8Array([1,2]));h.workers[2].emit('message',new Uint8Array([1,2]));
 await flush();assert.equal(h.workers[2].stopped,true,'A disposable process is never cached for another request');
 h.submit('next-schema','evaluateSchemas');assert.equal(h.workers[3].kind,'standard');
 assert.equal(h.workers[3].sent[0].id,'next-schema');assert.equal(h.workers[2].sent.length,1);
 await h.dispatcher.close();
});
test('cancelled kind transitions cannot start an isolated process later',async()=>{
 const h=harness(policyKind);
 h.submit('source','analyse');h.workers[0].emit('message',new Uint8Array([1,2]));
 h.submit('schema','evaluateSchemas');h.workers[1].emit('message',new Uint8Array([1,2]));
 let finish;h.workers[1].gate=new Promise(resolve=>finish=resolve);
 h.submit('isolated','govern',{isolated:true});await flush();await h.dispatcher.stop('isolated');
 finish(0);await flush();assert.equal(h.workers.length,2);assert(h.failures.some(f=>f.id==='isolated'&&f.code==='cancelled'));
 await h.dispatcher.close();
});
test('a disposable reply does not release ownership until termination completes',async()=>{
 const h=harness(policyKind);h.submit('source','analyse');h.workers[0].emit('message',new Uint8Array([1,2]));
 h.submit('one','govern',{isolated:true});let finish;h.workers[1].gate=new Promise(resolve=>finish=resolve);
 h.submit('two','govern',{isolated:true});h.workers[1].emit('message',new Uint8Array([1,2]));await flush();
 assert.equal(h.outputs.length,2);assert.equal(h.workers.length,2);assert(!h.workers.some(w=>w.sent.some(q=>q.id==='two')));
 finish(0);await flush();assert.equal(h.workers[2].sent[0].id,'two');await h.dispatcher.close();
});
test('the owned process adapter supplies a bounded static failure instead of raw exception text',async()=>{
 const h=harness(policyKind);h.submit('policy','govern',{isolated:true});
 h.workers[0].failureFor=()=>({code:'policy.process.timeout',message:'Required governance execution did not complete'});
 h.workers[0].emit('error',Error('private contract data'));await flush();
 assert.equal(h.outputs.length,0);assert.equal(h.failures[0].code,'policy.process.timeout');assert(!h.failures[0].message.includes('private'));
 await h.dispatcher.close();
});
test('two active jobs and two queued jobs complete only on actual replies; source feedback has priority',async()=>{
 const h=harness();h.submit('a');h.submit('b');h.submit('full','evaluateSchemas');h.submit('source','analyse');h.submit('overflow');
 assert.equal(h.workers.length,2);assert.deepEqual(h.failures.map(f=>[f.id,f.code]),[['overflow','queue.full']]);assert.equal(h.outputs.length,0);
 h.workers[0].emit('message',new Uint8Array([1,2]));assert.equal(h.outputs.length,1);assert.equal(h.workers[0].sent.at(-1).id,'source');
 h.workers[1].emit('message',new Uint8Array([3,4]));assert.equal(h.workers[1].sent.at(-1).id,'full');assert.equal(h.workers.length,2);
 h.workers[0].emit('message',new Uint8Array([5,6]));h.workers[1].emit('message',new Uint8Array([7,8]));
 assert.equal(h.outputs.length,4);await h.dispatcher.close();assert(h.workers.every(w=>w.stopped));
});
test('queued and running cancellation retain ownership until termination and never execute cancelled queued work',async()=>{
 const h=harness();h.submit('a');h.submit('b');h.submit('queued');h.submit('kept');
 await h.dispatcher.stop('queued');assert.equal(h.failures[0].id,'queued');assert.equal(h.failures[0].code,'cancelled');
 let finish;h.workers[0].gate=new Promise(resolve=>finish=resolve);let acknowledged=false;
 const stopped=h.dispatcher.stop('a').then(()=>acknowledged=true);const again=h.dispatcher.stop('a');
 assert.doesNotThrow(()=>h.workers[0].emit('error',new Error('late failure during owned termination')));
 await flush();assert.equal(acknowledged,false);assert.equal(h.workers.length,2);assert(!h.workers.some(w=>w.sent.some(q=>q.id==='kept')));
 finish(0);await Promise.all([stopped,again]);assert.equal(acknowledged,true);assert.equal(h.failures.filter(f=>f.id==='a').length,1);
 assert.equal(h.workers.length,3);assert.equal(h.workers[2].sent[0].id,'kept');assert(!h.workers.some(w=>w.sent.some(q=>q.id==='queued')));
 h.workers[1].emit('message',new Uint8Array([1,2]));h.workers[2].emit('message',new Uint8Array([1,2]));await h.dispatcher.close();
});
test('an idle worker failure is retired before its slot is reused',async()=>{
 const h=harness();h.submit('a');h.submit('b');h.workers[0].emit('message',new Uint8Array([1,2]));
 let finish;h.workers[0].gate=new Promise(resolve=>finish=resolve);
 assert.doesNotThrow(()=>h.workers[0].emit('error',new Error('idle worker failed')));h.submit('waiting');
 assert.equal(h.workers.length,2);finish(0);await flush();assert.equal(h.workers.length,3);assert.equal(h.workers[2].sent[0].id,'waiting');
 await h.dispatcher.close();
});
for(const event of ['error','exit','message'])test(`failed worker ${event} cannot become empty success or release its slot prematurely`,async()=>{
 const h=harness();h.submit('bad');h.submit('other');h.submit('waiting');
 let finish;h.workers[0].gate=new Promise(resolve=>finish=resolve);
 h.workers[0].emit(event,event==='message'?{}:new Error('private contract data must not enter findings'));
 let cancellationFinished=false;const stop=h.dispatcher.stop('bad').then(()=>cancellationFinished=true);
 await flush();assert.equal(cancellationFinished,false);
 assert.equal(h.outputs.length,0);assert.equal(h.failures[0].id,'bad');assert.equal(h.failures[0].message.includes('private'),false);
 assert.equal(h.workers.length,2);finish(0);await stop;await flush();assert.equal(h.workers.length,3);assert.equal(h.workers[2].sent[0].id,'waiting');
 await h.dispatcher.close();
});
test('shutdown waits for already retiring workers and rejects queued/new work',async()=>{
 const h=harness();h.submit('bad');h.submit('other');h.submit('queued');
 let finish;h.workers[0].gate=new Promise(resolve=>finish=resolve);h.workers[0].emit('message',{});
 let closed=false;const closing=h.dispatcher.close().then(()=>closed=true);await flush();assert.equal(closed,false);
 h.submit('new');assert(h.failures.some(f=>f.id==='queued'&&f.code==='cancelled'));assert(h.failures.some(f=>f.id==='new'&&f.code==='worker.closed'));
 finish(0);await closing;assert.equal(closed,true);assert(!h.workers.some(w=>w.sent.some(q=>q.id==='queued')));
});
test('termination failure fails closed rather than acknowledging incomplete cancellation',async()=>{
 const h=harness();h.submit('a');h.submit('b');h.submit('queued');
 h.workers[0].gate=Promise.reject(new Error('termination denied'));
 await assert.rejects(h.dispatcher.stop('a'),/termination denied/);
 h.submit('new');assert(h.failures.some(f=>f.id==='queued'&&f.code==='worker.stop'));assert(h.failures.some(f=>f.id==='new'&&f.code==='worker.closed'));
 assert(!h.failures.some(f=>f.id==='a'&&f.code==='cancelled'));await assert.rejects(h.dispatcher.close(),/could not be terminated/);
});
test('cancelling full semantic work preserves the foreground parser owner and its idle cache',async()=>{
 const h=harness();h.submit('source','analyse');h.workers[0].emit('message',new Uint8Array([1,2]));
 h.submit('schema','evaluateSchemas');
 assert.equal(h.workers.length,2,'full evaluation must not consume the only idle foreground worker');
 assert.equal(h.workers[0].sent.length,1);assert.equal(h.workers[1].sent.at(-1).id,'schema');
 let finish;h.workers[1].gate=new Promise(resolve=>finish=resolve);
 const cancelled=h.dispatcher.stop('schema');await flush();
 h.submit('next-source','analyse');
 assert.equal(h.workers[0].sent.at(-1).id,'next-source');assert.equal(h.workers[0].stopped,false);
 assert.equal(h.workers.length,2);finish(0);await cancelled;
 h.workers[0].emit('message',new Uint8Array([1,2]));await h.dispatcher.close();
});
for(const method of ['evaluateSchemas','inspectPolicyCode','resolvePolicyCode','reviewPolicyCode','referenceDocument','referenceDisplay','deriveBundle','describeResourcePackage','planExtract','planInline','planMoveDefinition','sourceFolds'])test(`queued governance and ${method} share the background slot without starving Source`,async()=>{
 const h=harness();h.submit('source','analyse');h.workers[0].emit('message',new Uint8Array([1,2]));
 h.submit('policy','govern');h.submit('schema',method);h.submit('typing','analyse');
 assert.equal(h.workers.length,2);assert.equal(h.workers[0].sent.at(-1).id,'typing');
 assert.equal(h.workers[1].sent.at(-1).id,'policy');
 h.workers[0].emit('message',new Uint8Array([1,2]));
 assert.equal(h.workers[0].sent.length,2,'waiting full work must not borrow the sole foreground owner');
 h.workers[1].emit('message',new Uint8Array([1,2]));assert.equal(h.workers[1].sent.at(-1).id,'schema');
 h.workers[1].emit('message',new Uint8Array([1,2]));await h.dispatcher.close();
});
