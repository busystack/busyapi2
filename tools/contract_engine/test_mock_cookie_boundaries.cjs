const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

function parameter(name,schema,extra={}){return {name,in:'cookie',required:true,style:'form',explode:false,schema,...extra};}
function contract(version,routes){return {openapi:version,info:{title:'Cookie boundaries',version:'api-version'},paths:Object.fromEntries(routes.map(([path,parameters])=>[path,{post:{parameters,responses:{204:{description:'Accepted'}}}}]))};}
function wire(port,path,cookie){return new Promise((resolve,reject)=>{
 const request=http.request({host:'127.0.0.1',port,path,method:'POST',headers:{'content-length':'0',cookie}},response=>{
  const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);
  response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,text:Buffer.concat(chunks).toString()}));
 });request.once('error',reject);request.end();
});}

for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2'])for(const format of ['yaml','json'])test(`${version} ${format} cookie data is decoded after delimiter boundaries`,{timeout:20000},async t=>{
 const strings={type:'array',minItems:1,maxItems:1,items:{type:'string',enum:['one,雪','a&=+%','']}};
 const mixed={type:'array',minItems:1,maxItems:1,items:{anyOf:[{type:'integer',enum:['EXACT']},{type:'boolean',enum:[false]},version.startsWith('3.0.')?{type:'string',nullable:true,enum:[null]}:{type:'null'}]}};
 const object={type:'object',required:['a,b','zero'],properties:{'a,b':{type:'string',enum:['c,d']},zero:{type:'integer',enum:[0]}},additionalProperties:false};
 const document=contract(version,[
  ['/list',[parameter('Value',strings)]],['/mixed',[parameter('Value',mixed)]],
  ['/object',[parameter('Object',object,{explode:true})]],
  ['/content',[{name:'Value',in:'cookie',required:true,content:{'application/json':{schema:{type:'object',required:['x'],properties:{x:{type:'string',enum:['100%']}},additionalProperties:false}}}}]],
 ]);
 const root='file:///cookie-boundaries/api.'+format,text=(format==='yaml'?YAML.stringify(document):JSON.stringify(document)).replaceAll(format==='yaml'?'EXACT':'"EXACT"','9007199254740993.00');
 const input=mockStart(text,{},root),before=JSON.stringify(input.capture),{port}=await startMock(t,input);
 for(const [path,cookie]of [
  ['/list','Value=one%2C%E9%9B%AA'],['/list','Value=one%2c%E9%9B%AA'],['/list','Value=a%26%3D%2B%25'],['/list','Value='],
  ['/mixed','Value=9007199254740993.00'],['/mixed','Value=false'],['/mixed','Value=null'],
  ['/object','a%2Cb=c%2Cd&zero=0'],['/content','Value=%7B%22x%22%3A%22100%25%22%7D'],
 ]){
  const response=await wire(port,path,cookie);assert.equal(response.status,204,path+': '+response.text);
  assert.equal(response.headers['busyapi-response-validation-complete'],'true');
  assert.deepEqual(JSON.parse(response.headers['sl-violations']??'[]'),[]);
 }
 for(const [path,cookie,code]of [
  ['/list','Value=one%2C%E9%9B%AA,other','runtime.request.parameter.serialization'],
  ['/list','Value=bad%','runtime.request.parameter.serialization'],
  ['/mixed','Value=9007199254740992','runtime.schema.incompatible'],
 ]){
  const response=await wire(port,path,cookie);assert.equal(response.status,422,response.text);
  const findings=JSON.parse(response.headers['sl-violations']??'[]');
  assert(findings.some(finding=>finding.nativeCode===code&&finding.source.resource===root&&finding.source.range[1]>finding.source.range[0]),response.text);
 }
 assert.equal(JSON.stringify(input.capture),before);
});

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} refuses the newer forbidden explode false declaration`,()=>{
 const document=contract(version,[['/list',[parameter('Value',{type:'array',items:{type:'string'}})]]]);
 const root='file:///cookie-family/api.'+format,text=format==='yaml'?YAML.stringify(document):JSON.stringify(document);
 const result=analyse({root,snapshot:version,resources:[{id:root,text,generation:1}]});
 assert.equal(result.status,'invalid');assert(result.findings.some(finding=>finding.code==='parameter.cookie.explode'));
 assert.equal(document.paths['/list'].post.parameters[0].explode,false);
});
