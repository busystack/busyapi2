const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

function send(port,path){return new Promise((resolve,reject)=>{
 const request=http.request({host:'127.0.0.1',port,path,method:'POST',headers:{'content-length':'0'}},response=>{
  const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);
  response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,text:Buffer.concat(chunks).toString()}));
 });request.once('error',reject);request.end();
});}
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} proxy headers use captured composition proofs without changing upstream bytes`,{timeout:20000},async t=>{
 const server=http.createServer((request,response)=>{
  const bad=request.url.includes('bad');response.setHeader('content-type','application/json');
  response.setHeader('X-Values',['0',(bad?'9007199254740992':'9007199254740993.000')+',false,x']);
  response.setHeader('X-Object',bad?'a=0,b=1':'a=0,b=false');response.setHeader('X-Null','null');
  response.end('0');
 });
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 const headers={
  'X-Values':{schema:{type:'array',minItems:4,maxItems:4,items:{anyOf:[{type:'integer',enum:[0,'EXACT']},{type:'boolean',enum:[false]},{type:'string',enum:['x']}]}}},
  'X-Object':{explode:true,schema:{type:'object',required:['a','b'],properties:{a:{type:'integer'},b:{anyOf:[{type:'boolean'},{type:'integer',enum:[0]}]}},additionalProperties:false}},
  'X-Null':{schema:version.startsWith('3.0.')?{type:'string',nullable:true,enum:[null]}:{type:'null'}},
 };
 const response={description:'Actual headers',headers,content:{'application/json':{schema:{type:'integer'}}}};
 const document={openapi:version,info:{title:'Mock header compositions',version:'1'},paths:{'/data':{post:{responses:{200:response}}}}};
 const text=(format==='yaml'?YAML.stringify(document):JSON.stringify(document)).replaceAll(format==='yaml'?'EXACT':'"EXACT"','9007199254740993.00');
 const input=mockStart(text,{upstream:'http://127.0.0.1:'+server.address().port},'file:///mock-header-compositions/api.'+format),original=JSON.stringify(input.capture);
 const {port}=await startMock(t,input),good=await send(port,'/data'),bad=await send(port,'/data?bad');
 assert.equal(good.status,200);assert.equal(good.text,'0');assert.equal(good.headers['busyapi-response-validation-complete'],'true');
 assert.deepEqual(JSON.parse(good.headers['sl-violations']??'[]'),[]);
 assert.equal(good.headers['x-values'],'0, 9007199254740993.000,false,x');assert.equal(good.headers['x-null'],'null');
 assert.equal(bad.status,200);assert.equal(bad.text,'0');assert.equal(bad.headers['busyapi-response-validation-complete'],'true');
 const findings=JSON.parse(bad.headers['sl-violations']??'[]');
 for(const name of ['X-Values','X-Object'])assert(findings.some(finding=>finding.location.includes(name)&&finding.code==='runtime.schema.incompatible'&&finding.source.resource===input.capture.root&&finding.source.range[1]>finding.source.range[0]),JSON.stringify(findings));
 assert(!findings.some(finding=>finding.location.includes('X-Null')));
 assert.equal(JSON.stringify(input.capture),original);
});
