const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {mockStart,startMock,mockRequest}=require('./mock_test_capture.cjs');

const delimiters={csv:',',ssv:' ',tsv:'\t',pipes:'|'};
function contract(format,outer,inner){
 const items={type:'array',minItems:2,maxItems:2,collectionFormat:inner,items:{type:'integer',enum:[0,'EXACT_VALUE']}};
 const paths=Object.fromEntries(['path','query','header'].filter(location=>outer!=='multi'||location==='query').map(location=>[
  '/'+location+(location==='path'?'/{N}':''),{post:{parameters:[{name:'N',in:location,required:true,type:'array',minItems:2,maxItems:2,collectionFormat:outer,items}],responses:{204:{description:'Accepted'}}}},
 ]));
 const document={swagger:'2.0',info:{title:'Native nested Items',version:'1'},paths};
 const serialized=format==='yaml'?YAML.stringify(document):JSON.stringify(document);
 return serialized.replaceAll(format==='json'?'"EXACT_VALUE"':'EXACT_VALUE','9007199254740993.00');
}
function wire(port,location,value){
 const path='/'+location+(location==='path'?'/'+encodeURIComponent(value):location==='query'?'?'+(Array.isArray(value)?value:[value]).map(value=>'N='+encodeURIComponent(value)).join('&'):'');
 return new Promise((resolve,reject)=>{
  const request=http.request({host:'127.0.0.1',port,path,method:'POST',headers:{'content-length':'0',...(location==='header'?{N:value}:{})}},response=>{
   const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);
   response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,text:Buffer.concat(chunks).toString()}));
  });request.once('error',reject);request.end();
 });
}
for(const format of ['yaml','json'])for(const outer of ['csv','ssv','tsv','pipes','multi'])test(`Swagger ${format} nested Items retain each ${outer} collection layer`,{timeout:20000},async t=>{
 const inner=outer==='pipes'?'csv':'pipes',text=contract(format,outer,inner),input=mockStart(text,{},'file:///nested-items/api.'+format),before=JSON.stringify(input.capture),{port}=await startMock(t,input);
 const rows=['0'+delimiters[inner]+'9007199254740993','9007199254740993'+delimiters[inner]+'0'];
 const good=outer==='multi'?rows:rows.join(delimiters[outer]);
 for(const location of outer==='multi'?['query']:['path','query','header']){
  const valid=await wire(port,location,good);assert.equal(valid.status,204,location+': '+valid.text);
  const bad=outer==='multi'?rows.map(row=>row.replace('9007199254740993','9007199254740992')):good.replace('9007199254740993','9007199254740992');
  const invalid=await wire(port,location,bad);assert.equal(invalid.status,422,location+': '+invalid.text);
  assert.ok(JSON.parse(invalid.headers['sl-violations']).some(finding=>finding.nativeCode==='runtime.schema.incompatible'&&finding.source.resource===input.capture.root));
 }
 assert.equal(JSON.stringify(input.capture),before);
});

for(const format of ['yaml','json'])test(`Swagger ${format} nested identical delimiters require a schema-proven grouping`,{timeout:20000},async t=>{
 const input=mockStart(contract(format,'csv','csv'),{},'file:///nested-items/api.'+format),{port}=await startMock(t,input);
 for(const location of ['path','query','header']){
  const valid=await wire(port,location,'0,9007199254740993,9007199254740993,0');assert.equal(valid.status,204,valid.text);
  assert.equal((await wire(port,location,'0,9007199254740992,9007199254740993,0')).status,422);
 }
});

for(const format of ['yaml','json'])for(const outer of ['csv','ssv','tsv','pipes'])test(`Swagger ${format} proxy response checks nested ${outer} headers without replacing their bytes`,{timeout:20000},async t=>{
 const inner=outer==='pipes'?'csv':'pipes',good=['0'+delimiters[inner]+'9007199254740993','9007199254740993'+delimiters[inner]+'0'].join(delimiters[outer]);
 const upstream=http.createServer((request,response)=>{
  response.statusCode=204;response.setHeader('X-Values',request.url.includes('good')?good:good.replace('0993','0992'));response.end();
 });
 await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
 t.after(()=>{upstream.closeAllConnections();upstream.close();});
 const document={swagger:'2.0',info:{title:'Nested header proxy',version:'1'},paths:{'/p':{post:{responses:{204:{description:'No content',headers:{'X-Values':{type:'array',collectionFormat:outer,minItems:2,maxItems:2,items:{type:'array',collectionFormat:inner,minItems:2,maxItems:2,items:{type:'integer',enum:[0,'EXACT_VALUE']}}}}}}}}}};
 const serialized=format==='yaml'?YAML.stringify(document):JSON.stringify(document),text=serialized.replaceAll(format==='json'?'"EXACT_VALUE"':'EXACT_VALUE','9007199254740993.00');
 const input=mockStart(text,{upstream:'http://127.0.0.1:'+upstream.address().port},'file:///nested-proxy/api.'+format),{port}=await startMock(t,input);
 for(const valid of [true,false]){
  const response=await mockRequest(port,valid?'/p?good':'/p');
  assert.equal(response.status,204,response.text);assert.equal(response.text,'');
  assert.equal(response.headers['x-values'],valid?good:good.replace('0993','0992'));
  assert.equal(response.headers['busyapi-response-validation-complete'],'true');
  const findings=JSON.parse(response.headers['sl-violations']??'[]');
  if(valid)assert.deepEqual(findings,[]);
  else assert.ok(findings.some(finding=>finding.code==='runtime.schema.incompatible'&&finding.source.resource===input.capture.root&&finding.location.includes('X-Values')),JSON.stringify(findings));
 }
});
