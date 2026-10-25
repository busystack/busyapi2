const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const {createGraph}=require('./dist/model.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {EngineWorkerClient}=require('./dist/engine_worker_client.cjs');
const {MockSchemaSamples}=require('./dist/mock_schema_samples.cjs');

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} abort between authored and cached derived candidates remains cancellation`,{timeout:15000},async t=>{
 const legacy=version==='2.0',schema={type:'object',additionalProperties:false};
 const document={[legacy?'swagger':'openapi']:version,info:{title:'Captured derived cache',version:'1'},
  ...(legacy?{produces:['application/json']}:{}),paths:{'/items':{get:{responses:{200:{description:'Generated',
   ...(legacy?{schema}:{content:{'application/json':{schema}}})}}}}}};
 const root='file:///derived-sample-lifetime/api.'+format;
 const text=format==='json'?JSON.stringify(document):YAML.stringify(document);
 const identity=createHash('sha256').update(text).digest('hex');
 const capture={root,snapshot:identity,resources:[{id:root,text,identity,generation:1}]};
 const context=createGraph(capture);
 const plan=requestOperation({...capture,resource:root,pointer:'/paths/~1items/get'},context);
 const client=new EngineWorkerClient();t.after(()=>client.close());let calls=0;
 const samples=new MockSchemaSamples(context.graph,async(instances,signal)=>{
  calls++;
  const result=await client.request('evaluateSchemas',{...capture,runtimeInstances:instances},signal);
  return {complete:result.complete,valid:result.runtimeEvaluations.every(value=>value.complete&&value.valid),
   findings:result.runtimeFindings,evaluations:result.runtimeEvaluations};
 },capture.snapshot);
 const before=new AbortController();before.abort();
 await assert.rejects(samples.response(plan,'200','application/json',true,before.signal),error=>error.code==='cancelled');
 assert.equal(calls,0);
 assert.equal(await samples.response(plan,'200','application/json',true,new AbortController().signal),'{}');
 assert.equal(calls,1);
 const controller=new AbortController();
 const pending=samples.response(plan,'200','application/json',true,controller.signal);
 controller.abort();
 await assert.rejects(pending,error=>error.code==='cancelled');
 assert.equal(calls,1,'Cancellation must not dispatch another proof or return cached success');
 assert.equal(await samples.response(plan,'200','application/json',true,new AbortController().signal),'{}');
 assert.equal(calls,1,'The earlier completed proof remains owned by its immutable capture');
});
