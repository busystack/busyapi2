const assert=require('node:assert/strict');
const {test}=require('node:test');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const {evaluateSchemas,schemaProducer}=require('./dist/schema_evaluation.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {planMigration}=require('./dist/migration.cjs');
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const escape=s=>s.replaceAll('~','~0').replaceAll('/','~1');
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const render=(value,format)=>format==='yaml'?'# Keep source 雪😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)+'\r\n';
function resource(id,bytes,aliases=[]){return {version:1,id,generation:0,identity:hash(bytes),state:'available',aliases,byteLength:bytes.length,base64:bytes.toString('base64')};}
function fixture(version,format,mediaType='application/json',schema={type:'object',required:['n'],properties:{n:{enum:[9007199254740992]}}}){
 const root='file:///approved/api.'+format,payload='file:///approved/data/payload.bin';
 const media={schema,examples:{Local:{externalValue:'./data/payload.bin'}}};
 const value={openapi:version,info:{title:'Unchanged',version:'business'},paths:{'/example':{post:{requestBody:{content:{[mediaType]:media}},responses:{200:{description:'Reply',content:{[mediaType]:media}}}}}},'x-payload':{$ref:'not-a-reference.json',externalValue:'not-a-resource.bin'}};
 const source=render(value,format),input={root,snapshot:'external-'+version+format,resources:[{id:root,text:source,generation:2,identity:hash(Buffer.from(source))}]};
 return {root,payload,value,input,source,mediaType,pointer:'/paths/~1example/post/requestBody/content/'+escape(mediaType)};
}
function assertValid(result){assert.equal(result.complete,true,JSON.stringify(result.findings));assert(result.serializedEvaluations.length>0);assert(result.serializedEvaluations.every(value=>value.complete&&value.valid),JSON.stringify(result.findings));}
for(const version of versions)for(const format of ['yaml','json']){
 for(const representation of ['json','latin1','mime'])test(`${version} ${format} captures and evaluates external ${representation} bytes`,async()=>{
  const type=representation==='json'?'application/json':representation==='latin1'?'text/plain; charset=iso-8859-1':'multipart/form-data; boundary=Example';
  const schema=representation==='mime'?{type:'object',required:['label'],properties:{label:{type:'string',enum:['café']}}}:representation==='json'?{type:'object',required:['n'],properties:{n:{type:'integer',minimum:9007199254740992}}}:{type:'string',enum:['café']};
  const f=fixture(version,format,type,schema);
  const bytes=representation==='json'?Buffer.from('{"n":9007199254740993.00,"false":false,"zero":0,"null":null,"empty":"","$ref":"payload-only","swagger":"invalid","unicode":"雪😀"}'):
   representation==='latin1'?Buffer.from([99,97,102,233]):Buffer.from('--Example\r\nContent-Disposition: form-data; name="label"\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\ncafé\r\n--Example--\r\n','latin1');
  const input={...f.input,exampleResources:[resource(f.payload,bytes)]};
  const structural=analyse(input);assert.equal(structural.status,'complete',JSON.stringify(structural.findings));
  assert.equal(structural.externalExamples.length,2);assert(structural.externalExamples.every(value=>value.targetResource===f.payload));
  assert(!structural.references.some(value=>value.value==='payload-only'||value.value==='not-a-reference.json'));
  const result=await evaluateSchemas(input);assertValid(result);assert.equal(result.serializedEvaluations.length,2);
  assert(result.serializedEvaluations.every(value=>value.external.identity===hash(bytes)&&value.external.byteLength===bytes.length));
  if(representation!=='mime'){
   const plan=requestOperation({...input,resource:f.root,pointer:'/paths/~1example/post'});
   const selected=plan.requestBody.content.find(value=>value.mediaType===type).examples[0];
   assert.equal(selected.wireBase64,bytes.toString('base64'));assert.equal(selected.text,representation==='json'?bytes.toString('utf8'):'café');
  }
  assert.equal(input.resources[0].text,f.source);assert.deepEqual(Buffer.from(input.exampleResources[0].base64,'base64'),bytes);
 });
 test(`${version} ${format} available invalid payload reports schema incompatibility`,async()=>{
  const f=fixture(version,format,'application/json',{type:'integer',minimum:1});
  const result=await evaluateSchemas({...f.input,exampleResources:[resource(f.payload,Buffer.from('0'))]});
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert(result.serializedEvaluations.every(value=>value.complete&&!value.valid));
  assert(result.findings.some(value=>value.code==='example.serialization.incompatible'));assert(!result.findings.some(value=>JSON.stringify(value).includes('external-value.unavailable')));
 });
 for(const reason of ['missing','denied'])test(`${version} ${format} ${reason} stays precisely incomplete`,async()=>{
  const f=fixture(version,format),code='example.external-value.'+reason;
  const packet={version:1,id:f.payload,generation:0,identity:hash(Buffer.from(reason)),state:'unavailable',aliases:[],problem:{code,message:'Controlled '+reason,condition:'unavailable'}};
  const result=await evaluateSchemas({...f.input,exampleResources:[packet]});
  assert.equal(result.complete,false);assert(result.findings.some(value=>value.detailCode===code));
  assert(result.findings.filter(value=>value.detailCode===code).every(value=>value.pointer.endsWith('/externalValue')));
  assert.equal(f.input.resources[0].text,f.source);
 });
 test(`${version} ${format} unchanged inline controls need no acquired payload`,async()=>{
  const f=fixture(version,format,'application/json',{type:'boolean'});
  for(const media of [f.value.paths['/example'].post.requestBody.content['application/json'],f.value.paths['/example'].post.responses[200].content['application/json']])media.examples={Inline:{value:false}};
  const input={...f.input,resources:[{...f.input.resources[0],text:render(f.value,format)}]};
  assert.equal(analyse(input).externalExamples.length,0);const result=await evaluateSchemas(input);assert.equal(result.complete,true);assert(result.evaluations.some(value=>value.valid));
 });
}
for(const format of ['yaml','json'])test(`${format} referenced Example uses its defining directory and captured aliases`,async()=>{
 const f=fixture('3.2.1',format,'text/plain',{type:'string',enum:['']});
 const id='file:///approved/definitions/examples.'+format,uri='https://contracts.invalid/definitions/examples.'+format;
 f.value.$self='https://contracts.invalid/root/api.'+format;
 for(const media of [f.value.paths['/example'].post.requestBody.content['text/plain'],f.value.paths['/example'].post.responses[200].content['text/plain']])media.examples={Local:{$ref:'../definitions/examples.'+format+'#/Example'}};
 const input={...f.input,resources:[{...f.input.resources[0],text:render(f.value,format)},{id,text:render({Example:{externalValue:'../payload.empty'}},format),generation:0,aliases:[uri]}],exampleResources:[resource('file:///approved/payload.empty',Buffer.alloc(0),['https://contracts.invalid/payload.empty'])]};
 const requests=analyse(input).externalExamples;assert(requests.length);assert(requests.every(value=>value.resource===id&&value.targetResource==='https://contracts.invalid/payload.empty'));
 assertValid(await evaluateSchemas(input));
});
test('payload fragments remain representation-specific and no source-looking payload is traversed',async()=>{
 const f=fixture('3.1.2','json');f.value.paths['/example'].post.requestBody.content['application/json'].examples.Local.externalValue+='#/n';
 const input={...f.input,resources:[{...f.input.resources[0],text:render(f.value,'json')}],exampleResources:[resource(f.payload,Buffer.from('{"n":9007199254740993.00}'))]};
 assert(analyse(input).externalExamples.some(value=>value.problem?.code==='example.external-value.fragment.unsupported'));
 assert.equal((await evaluateSchemas(input)).complete,false);
});
test('a malformed captured byte identity is a protocol failure, never validation success',async()=>{
 const f=fixture('3.1.2','json'),packet=resource(f.payload,Buffer.from('false'));packet.identity='0'.repeat(64);
 await assert.rejects(()=>evaluateSchemas({...f.input,exampleResources:[packet]}),error=>error.code==='example.resource.protocol');
});
test('available source bytes remove false migration incompleteness without bypassing target validation',async()=>{
 const f=fixture('3.0.4','json','text/plain',{type:'string',enum:['café']});
 const input={...f.input,exampleResources:[resource(f.payload,Buffer.from('café'))],targetVersion:'3.1.2',destination:'file:///approved/output/'};
 const plan=await planMigration(input);assert.equal(plan.complete,true,JSON.stringify(plan.problems));assert.equal(plan.status,'faithfully-convertible');
 const absent=await planMigration({...input,exampleResources:[]});assert.equal(absent.complete,false);assert(absent.problems.some(value=>value.code==='migration.validation.incomplete'));
 assert.equal(f.input.resources[0].text,f.source);
});
test('external byte semantics invalidate old evaluator proofs',()=>{assert.equal(schemaProducer.version,'1.18.0+45');assert(schemaProducer.configuration.includes('external-example-bytes-v1'));});

test('Swagger payload keys do not become external Example Object acquisitions',async()=>{
 const root='file:///approved/swagger.json',value={swagger:'2.0',info:{title:'Payload',version:'business'},paths:{'/':{get:{responses:{200:{description:'Reply',schema:{type:'object'},examples:{'application/json':{externalValue:'data-only.bin',$ref:'not-a-reference.json'}}}}}}}};
 const input={root,snapshot:'swagger-payload',resources:[{id:root,text:JSON.stringify(value),generation:0}]};
 const analysis=analyse(input);assert.deepEqual(analysis.externalExamples,[]);assert(!analysis.references.some(value=>value.value==='not-a-reference.json'));
 const result=await evaluateSchemas(input);assert.equal(result.complete,true,JSON.stringify(result.findings));
});
test('available unsupported media reports its decoder limitation, not missing acquisition',async()=>{
 const f=fixture('3.1.2','json','application/xml',{type:'object'});
 const result=await evaluateSchemas({...f.input,exampleResources:[resource(f.payload,Buffer.from('<document/>'))]});
 assert.equal(result.complete,false);assert(!result.findings.some(value=>JSON.stringify(value).includes('external-value.unavailable')));
 assert(result.findings.some(value=>value.code==='example.serialization.incomplete'));
});

for(const [type,bytes,complete]of [
 ['application/json',Buffer.from([0xc0,0xaf]),true],
 ['text/plain; charset=utf-16',Buffer.from([0xff,0xfe,0x41,0]),false],
])test(type+' distinguishes invalid bytes from an unsupported codec',async()=>{
 const f=fixture('3.1.2','json',type,{type:'string'});
 const result=await evaluateSchemas({...f.input,exampleResources:[resource(f.payload,bytes)]});
 assert.equal(result.complete,complete,JSON.stringify(result.findings));
 assert(result.serializedEvaluations.every(value=>!value.valid));
 assert(result.findings.some(value=>value.code===(complete?'example.serialization.incompatible':'example.serialization.incomplete')));
 assert(!result.findings.some(value=>value.detailCode==='example.external-value.unavailable'));
});
test('two acquired resources cannot claim the same URI alias',async()=>{
 const f=fixture('3.1.2','json'),a=resource(f.payload,Buffer.from('0'));
 const b=resource('file:///approved/other.bin',Buffer.from('1'),[f.payload]);
 await assert.rejects(()=>evaluateSchemas({...f.input,exampleResources:[a,b]}),error=>error.code==='example.resource.protocol');
});

test('a media range does not invent a concrete external payload format',async()=>{
 const f=fixture('3.2.1','json','*/*',{type:'object'});
 const result=await evaluateSchemas({...f.input,exampleResources:[resource(f.payload,Buffer.from('{}'))]});
 assert.equal(result.complete,false);
 assert(result.findings.some(value=>value.detailCode==='example.external-value.media-context'&&value.condition==='unsupported'&&value.incomplete===true));
});
