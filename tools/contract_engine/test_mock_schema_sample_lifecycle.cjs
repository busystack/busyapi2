const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {createGraph}=require('./dist/model.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {EngineWorkerClient}=require('./dist/engine_worker_client.cjs');
const {MockSchemaSamples}=require('./dist/mock_schema_samples.cjs');

function captured(version='3.0.4',generation=1){
 const root='file:///sample-lifetime/api.json',legacy=version==='2.0';
 const schema={type:'integer',minimum:'BIG',enum:['LOW','BIG']};
 const document={[legacy?'swagger':'openapi']:version,info:{title:'Samples',version:'1'},
  ...(legacy?{produces:['application/json']}:{}),
  paths:{'/data':{get:{responses:{200:{description:'Generated',
   ...(legacy?{schema}:{content:{'application/json':{schema}}})}}}}}};
 const text=JSON.stringify(document).replaceAll('"BIG"','9007199254740993.00').replaceAll('"LOW"','9007199254740992.00');
 const identity=createHash('sha256').update(text).digest('hex');
 const capture={root,snapshot:identity,resources:[{id:root,text,identity,generation}]};
 const context=createGraph(capture);
 const plan=requestOperation({...capture,resource:root,pointer:'/paths/~1data/get'},context);
 return {capture,context,plan};
}

function evaluator(client,capture){
 return async(instances,signal)=>{
  const result=await client.request('evaluateSchemas',{...capture,runtimeInstances:instances},signal);
  return {complete:result.complete,valid:result.runtimeEvaluations.every(value=>value.complete&&value.valid),
   findings:result.runtimeFindings,evaluations:result.runtimeEvaluations};
 };
}

test('cancelled and late-aborted sample proofs never enter the captured cache',{timeout:20000},async t=>{
 const client=new EngineWorkerClient();t.after(()=>client.close());
 const {capture,context,plan}=captured(),evaluate=evaluator(client,capture);
 for(const late of [false,true]){
  const entered=Promise.withResolvers(),controller=new AbortController();let calls=0;
  const samples=new MockSchemaSamples(context.graph,async(instances,signal)=>{
   calls++;entered.resolve();
   if(calls===1&&!late)return new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(Object.assign(new Error('Cancelled owned proof'),{code:'cancelled'})),{once:true}));
   const result=await evaluate(instances,signal);
   if(calls===1&&late)controller.abort();
   return result;
  },capture.snapshot);
  const pending=samples.response(plan,'200','application/json',false,controller.signal);
  await entered.promise;if(!late)controller.abort();
  await assert.rejects(pending,error=>error.code==='cancelled');
  assert.equal(await samples.response(plan,'200','application/json',false,new AbortController().signal),'9007199254740993.00');
  assert.equal(await samples.response(plan,'200','application/json',false,new AbortController().signal),'9007199254740993.00');
  assert.equal(calls,2,'Only a completed original-schema proof may be cached');
 }
});

for(const mutation of ['incomplete','missing','duplicate','foreign','missing-choice','out-of-range-choice','noninteger-choice'])test(`${mutation} sample proof cannot produce a successful selection`,{timeout:15000},async t=>{
 const client=new EngineWorkerClient();t.after(()=>client.close());
 const {capture,context,plan}=captured(),evaluate=evaluator(client,capture);let calls=0;
 const samples=new MockSchemaSamples(context.graph,async(instances,signal)=>{
  calls++;const result=await evaluate(instances,signal);
  if(calls!==1)return result;
  if(mutation==='incomplete')return {...result,complete:false,evaluations:[]};
  if(mutation==='missing')return {...result,evaluations:result.evaluations.slice(1)};
  if(mutation==='duplicate')return {...result,evaluations:[result.evaluations[0],result.evaluations[0]]};
  if(mutation==='foreign')return {...result,evaluations:result.evaluations.map(value=>({...value,subject:'request-body'}))};
  return {...result,evaluations:result.evaluations.map(value=>({...value,chosen:mutation==='missing-choice'?undefined:mutation==='out-of-range-choice'?1000:.5}))};
 },capture.snapshot);
 await assert.rejects(samples.response(plan,'200','application/json',false,new AbortController().signal),
  error=>error.code===(mutation==='incomplete'?'mock.sample.unchecked':'mock.validation.protocol'));
 assert.equal(await samples.response(plan,'200','application/json',false,new AbortController().signal),'9007199254740993.00');
 assert.equal(calls,2,'A failed proof must not populate the sample cache');
});

test('one evaluator switches captured family, identity and source revisions without stale samples',{timeout:30000},async t=>{
 const client=new EngineWorkerClient();t.after(()=>client.close());let generation=0;
 for(const version of ['3.0.4','2.0','3.1.2','3.2.1','3.0.4','3.2.1']){
  const {capture,context,plan}=captured(version,++generation);
  const samples=new MockSchemaSamples(context.graph,evaluator(client,capture),capture.snapshot);
  assert.equal(await samples.response(plan,'200','application/json',false,new AbortController().signal),'9007199254740993.00');
  assert.equal(await samples.response(plan,'200','application/json',true,new AbortController().signal),'9007199254740993.00');
 }
});
