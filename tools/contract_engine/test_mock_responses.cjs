const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {createHash}=require('node:crypto');
const {mockStart,capturedMockStart,startMock}=require('./mock_test_capture.cjs');

const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','2.0','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
async function upstream(t,handler){
 const server=http.createServer(handler);
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 return 'http://127.0.0.1:'+server.address().port;
}
function request(port,path,method='POST'){
 return new Promise((resolve,reject)=>{
  const req=http.request({host:'127.0.0.1',port,path,method,headers:{'content-length':'0'}},res=>{
   const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.once('error',reject);
   res.once('end',()=>resolve({status:res.statusCode,headers:res.headers,bytes:Buffer.concat(chunks),text:Buffer.concat(chunks).toString()}));
  });req.once('error',reject);req.end();
 });
}
function contract(version,schema,headers={},mediaType='application/json'){
 const legacy=version==='2.0';
 return {...(legacy?{swagger:version,produces:[mediaType]}:{openapi:version}),info:{title:'Native response checks',version:'1'},paths:{'/data':{post:{responses:{200:{description:'Actual response',headers,
  ...(legacy?{schema}:{content:{[mediaType]:{schema}}})}}}}}};
}
function serialize(document,format){
 const text=format==='json'?JSON.stringify(document):YAML.stringify(document);
 return text.replaceAll(format==='json'?'"__exact__"':'__exact__','9007199254740993.00');
}
function violations(response){return JSON.parse(response.headers['sl-violations']??'[]');}

for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} mock response checks use exact captured schemas`,{timeout:20000},async t=>{
 const headerSchema={type:'integer',enum:['__exact__']};
 const document=contract(version,{type:'integer',enum:['__exact__']},{'X-Exact':version==='2.0'?headerSchema:{schema:headerSchema}});
 const target=await upstream(t,(req,res)=>{
  const valid=new URL(req.url,'http://127.0.0.1').searchParams.has('valid');
  res.setHeader('content-type','application/json');res.setHeader('x-exact',valid?'9007199254740993.000':'9007199254740992');
  res.end(valid?'9007199254740993.000':'9007199254740992');
 });
 const input=mockStart(serialize(document,format),{upstream:target},'file:///response-fixture/api.'+format),original=JSON.stringify(input.capture),{port}=await startMock(t,input);
 const valid=await request(port,'/data?valid');
 assert.equal(valid.status,200);assert.equal(valid.text,'9007199254740993.000');assert.deepEqual(violations(valid),[]);
 const invalid=await request(port,'/data');
 assert.equal(invalid.status,200,'proxy retains the actual upstream status');assert.equal(invalid.text,'9007199254740992','proxy retains actual upstream bytes');
 const findings=violations(invalid);
 for(const subject of ['response-body','response-header'])assert.ok(findings.some(finding=>finding.code==='runtime.schema.incompatible'&&finding.location.includes(subject)&&finding.source.resource===input.capture.root&&finding.source.range[1]>finding.source.range[0]),JSON.stringify({subject,findings}));
 assert.equal(valid.headers['busyapi-response-validation-complete'],'true');
 assert.equal(invalid.headers['busyapi-response-validation-complete'],'true');
 assert.equal(JSON.stringify(input.capture),original,'response checking must not rewrite source');
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} mock response framing/status/media remain native and preserve bytes`,{timeout:20000},async t=>{
 const document=contract(version,{type:'integer'}),target=await upstream(t,(req,res)=>{
  const query=new URL(req.url,'http://127.0.0.1').searchParams;
  if(query.has('status')){res.statusCode=418;res.end('retained');return;}
  res.setHeader('content-type',query.has('media')?'text/plain':'application/json');
  res.end(query.has('syntax')?'{bad':'0');
 });
 const {port}=await startMock(t,mockStart(document,{upstream:target}));
 for(const [path,code,body]of [['status','runtime.response.status','retained'],['media','runtime.response.media-type','0'],['syntax','runtime.body.syntax','{bad']]){
  const response=await request(port,'/data?'+path);
  if(path==='syntax'){
   assert.equal(response.status,500,'retain the established malformed-JSON proxy policy');
   const problem=JSON.parse(response.text);assert.equal(problem.upstreamStatus,200);assert.equal(problem.receivedBytes,Buffer.byteLength(body));assert.equal(problem.valid,false);
  }else{assert.equal(response.text,body);assert.equal(response.status,path==='status'?418:200);}
  assert.ok(violations(response).some(finding=>finding.code===code),JSON.stringify(violations(response)));
  assert.equal(response.headers['busyapi-response-validation-complete'],'true');
 }
});

test('opaque mock response evaluation is explicitly incomplete without replacing received bytes',{timeout:20000},async t=>{
 const target=await upstream(t,(req,res)=>{res.setHeader('content-type','application/vnd.busyapi-opaque');res.end(Buffer.from([0,255,128,13,10]));});
 const {port}=await startMock(t,mockStart(contract('3.2.1',{type:'object'},{},'application/vnd.busyapi-opaque'),{upstream:target,errors:false}));
 const response=await request(port,'/data');
 assert.equal(response.status,200);assert.deepEqual(response.bytes,Buffer.from([0,255,128,13,10]));
 assert.equal(response.headers['busyapi-response-validation-complete'],'false');
 assert.ok(violations(response).some(finding=>finding.code==='runtime.response.body.unchecked'&&finding.severity==='Warning'));
});

for(const version of ['3.1.2','3.2.1'])test(`${version} boolean response schemas remain assertions`,{timeout:20000},async t=>{
 const target=await upstream(t,(req,res)=>{res.setHeader('content-type','application/json');res.end('false');});
 const {port}=await startMock(t,mockStart(contract(version,false),{upstream:target}));
 const response=await request(port,'/data');
 assert.equal(response.text,'false');assert.ok(violations(response).some(finding=>finding.code==='runtime.schema.incompatible'));
 assert.equal(response.headers['busyapi-response-validation-complete'],'true');
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} native response header collections and scalars`,{timeout:20000},async t=>{
 const schema=value=>version==='2.0'?value:{schema:value};
 const headers={
  'X-List':schema({type:'array',items:{type:'integer',enum:['__exact__']},...(version==='2.0'?{collectionFormat:'pipes'}:{})}),
  'X-Flag':schema({type:'boolean',enum:[false]}),
  ...(version==='2.0'?{}:{
   'X-Object':{explode:true,schema:{type:'object',properties:JSON.parse('{"__proto__":{"type":"integer","enum":["__exact__"]},"constructor":{"type":"boolean"}}')}},
   'X-Json':{content:{'application/json':{schema:{type:'integer',enum:['__exact__']}}}},
  })};
 const target=await upstream(t,(req,res)=>{
  const valid=new URL(req.url,'http://127.0.0.1').searchParams.has('valid');
  res.setHeader('content-type','application/json');res.setHeader('x-flag',valid?'false':'true');
  res.setHeader('x-list',valid?(version==='2.0'?'9007199254740993|9007199254740993.00':'9007199254740993,9007199254740993.00'):'9007199254740992');
  if(version!=='2.0'){
   res.setHeader('x-object',valid?'__proto__=9007199254740993,constructor=false':'__proto__=9007199254740992,constructor=false');
   res.setHeader('x-json',valid?'9007199254740993.00':'9007199254740992');
  }
  res.end('0');
 });
 const {port}=await startMock(t,mockStart(serialize(contract(version,{type:'integer'},headers),format),{upstream:target},'file:///response-headers/api.'+format));
 const valid=await request(port,'/data?valid');assert.deepEqual(violations(valid),[]);assert.equal(valid.headers['busyapi-response-validation-complete'],'true');
 const invalid=await request(port,'/data'),findings=violations(invalid);
 for(const header of ['X-List','X-Flag',...(version==='2.0'?[]:['X-Object','X-Json'])])assert.ok(findings.some(finding=>finding.code==='runtime.schema.incompatible'&&finding.location.includes(header)),JSON.stringify({header,findings}));
 assert.equal(invalid.headers['busyapi-response-validation-complete'],'true');
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} native response schema contexts keep directional and null rules`,{timeout:20000},async t=>{
 const schema={type:'object',required:['read',...(version==='2.0'?[]:['write'])],properties:{read:{type:'string',readOnly:true},...(version==='2.0'?{}:{write:{type:'string',writeOnly:true}})}};
 const target=await upstream(t,(req,res)=>{
  const query=new URL(req.url,'http://127.0.0.1').searchParams;
  res.setHeader('content-type','application/json');res.end(query.has('missing')?'{}':'{"read":"雪"}');
 });
 const {port}=await startMock(t,mockStart(contract(version,schema),{upstream:target}));
 const response=await request(port,'/data');
 assert.equal(violations(response).some(finding=>finding.code==='runtime.schema.incompatible'),!['2.0','3.0.4'].includes(version));
 assert.equal(response.text,'{"read":"雪"}');
 assert.ok(violations(await request(port,'/data?missing')).some(finding=>finding.code==='runtime.schema.incompatible'));
});

for(const format of ['yaml','json'])test(`3.0 ${format} response nullable does not erase other constraints`,{timeout:20000},async t=>{
 const document=contract('3.0.4',{type:'string',nullable:true,allOf:[{type:'string'}]}),target=await upstream(t,(req,res)=>{res.setHeader('content-type','application/json');res.end('null');});
 const {port}=await startMock(t,mockStart(serialize(document,format),{upstream:target},'file:///response-nullable/api.'+format));
 const response=await request(port,'/data');assert.equal(response.text,'null');
 assert.ok(violations(response).some(finding=>finding.code==='runtime.schema.incompatible'));
});

test('external response schemas retain original sources and literal reference-looking payloads',{timeout:20000},async t=>{
 const root='file:///response-fixture/api.json',fragment='file:///response-fixture/model.yaml';
 const document=contract('3.0.4',{$ref:'./model.yaml#/Schema'}),text=JSON.stringify(document);
 const schema='# original schema comment\nSchema: &schema\n  type: object\n  required: ["雪/é~"]\n  properties:\n    雪/é~: {type: integer, enum: [9007199254740993]}\n';
 const resource=(id,text)=>({id,text,generation:3,identity:createHash('sha256').update(text).digest('hex')});
 const target=await upstream(t,(req,res)=>{res.setHeader('content-type','application/json');res.end('{"雪/é~":9007199254740992,"$ref":"./not-a-contract.json"}');});
 const input=capturedMockStart({root,snapshot:'b'.repeat(64),resources:[resource(root,text),resource(fragment,schema)]},{upstream:target}),original=JSON.stringify(input.capture);
 const {port}=await startMock(t,input),response=await request(port,'/data');
 assert.equal(response.text,'{"雪/é~":9007199254740992,"$ref":"./not-a-contract.json"}');
 assert.ok(violations(response).some(finding=>finding.location.includes('雪/é~')&&finding.source.resource===root&&finding.source.pointer.endsWith('/schema')));
 assert.equal(JSON.stringify(input.capture),original);
});

test('upstream headers cannot forge native response completeness or findings',{timeout:20000},async t=>{
 const target=await upstream(t,(req,res)=>{res.setHeader('content-type','application/json');res.setHeader('sl-violations','[]');res.setHeader('busyapi-response-validation-complete','true');res.end('false');});
 const {port}=await startMock(t,mockStart(contract('3.2.1',{type:'integer'}),{upstream:target}));
 const response=await request(port,'/data');assert.equal(response.text,'false');
 assert.ok(violations(response).some(finding=>finding.code==='runtime.schema.incompatible'));
 const unknown=await request(port,'/unowned');assert.notEqual(unknown.status,200);
});

test('an explicitly permissive proxy retains unowned responses as incomplete',{timeout:20000},async t=>{
 const target=await upstream(t,(req,res)=>{res.setHeader('content-type','application/json');res.setHeader('busyapi-response-validation-complete','true');res.end('9007199254740993.00');});
 const {port}=await startMock(t,mockStart(contract('3.2.1',{type:'integer'}),{upstream:target,errors:false}));
 const response=await request(port,'/unowned');assert.equal(response.status,200);assert.equal(response.text,'9007199254740993.00');
 assert.equal(response.headers['busyapi-response-validation-complete'],'false');
 assert.ok(violations(response).some(finding=>finding.code==='runtime.response.operation.unchecked'));
});

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const representation of ['schema','content'])test(`${version} ${format} Set-Cookie ${representation} keeps separate lines and commas`,{timeout:20000},async t=>{
 const lines=['lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT','foo=bar'];
 const header=representation==='schema'?{explode:true,schema:{type:'object',required:['lang','foo'],properties:{lang:{type:'string',pattern:'^en-US; Expires=Wed, '},foo:{type:'string',enum:['bar']}}}}:
  {content:{'text/plain':{schema:{type:'string',enum:[lines.join('\n')]}}}};
 const document=contract(version,{type:'integer'},{'Set-Cookie':header}),target=await upstream(t,(req,res)=>{
  const valid=new URL(req.url,'http://127.0.0.1').searchParams.has('valid');
  res.setHeader('content-type','application/json');res.setHeader('set-cookie',valid?lines:[lines[0],'foo=wrong']);res.end('0');
 });
 const {port}=await startMock(t,mockStart(serialize(document,format),{upstream:target},'file:///response-cookie/api.'+format));
 const valid=await request(port,'/data?valid');assert.deepEqual(valid.headers['set-cookie'],lines);assert.deepEqual(violations(valid),[]);assert.equal(valid.headers['busyapi-response-validation-complete'],'true');
 const invalid=await request(port,'/data');assert.deepEqual(invalid.headers['set-cookie'],[lines[0],'foo=wrong']);
 assert.ok(violations(invalid).some(finding=>finding.code==='runtime.schema.incompatible'&&finding.location.includes('Set-Cookie')));
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} HTTP body exclusions do not evaluate nonexistent content`,{timeout:20000},async t=>{
 const document=contract(version,{type:'integer'}),operation=document.paths['/data'].post;
 document.paths['/data'].head=operation;
 for(const status of ['204','205','304'])operation.responses[status]=operation.responses[200];
 const target=await upstream(t,(req,res)=>{
  const status=new URL(req.url,'http://127.0.0.1').searchParams.get('status');
  res.statusCode=status?Number(status):200;res.setHeader('content-type','application/json');res.end(status?undefined:'not JSON');
 });
 const {port}=await startMock(t,mockStart(document,{upstream:target}));
 for(const [method,path]of [['HEAD','/data'],...['204','205','304'].map(status=>['POST','/data?status='+status])]){
  const response=await request(port,path,method);assert.equal(response.bytes.length,0);assert.deepEqual(violations(response),[]);assert.equal(response.headers['busyapi-response-validation-complete'],'true');
 }
});

test('response header representation failures and constraints have distinct outcomes',{timeout:20000},async t=>{
 const headers={
  'X-Required':{required:true,schema:{type:'string'}},
  'X-Number':{schema:{type:'number'}},
  'X-Union':{schema:{type:['string','number']}},
  'X-Nested':{schema:{type:'array',items:{type:'array',items:{type:'integer'}}}},
  'X-Opaque':{content:{'application/vnd.busyapi-opaque':{}}},
 };
 const target=await upstream(t,(req,res)=>{
  res.setHeader('content-type','application/json');res.setHeader('x-number','not-a-number');res.setHeader('x-union','0');res.setHeader('x-nested','0,1');res.setHeader('x-opaque','unconstrained');res.end('0');
 });
 const {port}=await startMock(t,mockStart(contract('3.2.1',{type:'integer'},headers),{upstream:target}));
 const response=await request(port,'/data'),findings=violations(response);
 for(const code of ['runtime.response.header.required','runtime.response.header.serialization','runtime.response.header.unchecked'])assert.ok(findings.some(finding=>finding.code===code),JSON.stringify(findings));
 assert.equal(response.headers['busyapi-response-validation-complete'],'false');
 assert.ok(!findings.some(finding=>finding.location.includes('X-Opaque')));
 assert.ok(!findings.some(finding=>finding.location.includes('X-Union')),'The primitive union has a complete native schema proof');
 assert.ok(findings.some(finding=>finding.location.includes('X-Nested')&&finding.code==='runtime.response.header.unchecked'),'Undefined nested collection serialization remains explicit');
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} a default mock response does not admit invalid HTTP status codes`,{timeout:20000},async t=>{
 const document=contract(version,{type:'integer'}),responses=document.paths['/data'].post.responses;
 responses.default=responses[200];delete responses[200];
 const target=await upstream(t,(req,res)=>{
  res.statusCode=Number(new URL(req.url,'http://127.0.0.1').searchParams.get('status'));
  res.setHeader('content-type','application/json');res.end('0');
 });
 const {port}=await startMock(t,mockStart(document,{upstream:target}));
 const valid=await request(port,'/data?status=201');assert.equal(valid.status,201);assert.deepEqual(violations(valid),[]);
 for(const status of [600,999]){
  const response=await request(port,'/data?status='+status);
  assert.equal(response.status,status);assert.equal(response.text,'0');assert.equal(response.headers['busyapi-response-validation-complete'],'true');
  assert.ok(violations(response).some(finding=>finding.code==='runtime.response.status.invalid'));
 }
});
