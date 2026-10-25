const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','2.0','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function parameter(version,name,location,schema,extra={}){
 return {name,in:location,required:true,...(version==='2.0'?schema:{schema}),...extra};
}
function contract(version,path,parameters){
 return {...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Captured native parameters',version:'1'},paths:{[path]:{post:{parameters,responses:{204:{description:'Accepted'}}}}}};
}
function source(document,format){
 const text=format==='json'?JSON.stringify(document):YAML.stringify(document);
 return text.replaceAll(format==='json'?'"EXACT_VALUE"':'EXACT_VALUE','9007199254740993.00');
}
function wire(port,path,headers={}){
 return new Promise((resolve,reject)=>{
  const req=http.request({host:'127.0.0.1',port,path,method:'POST',headers:{'content-length':'0',...headers}},res=>{
   const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.once('error',reject);
   res.once('end',()=>resolve({status:res.statusCode,headers:res.headers,text:Buffer.concat(chunks).toString()}));
  });req.once('error',reject);req.end();
 });
}

for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} native mock parameters retain exact decimal tokens`,{timeout:20000},async t=>{
 const schema={type:'integer',enum:['EXACT_VALUE']};
 const document=contract(version,'/precise/{ID}',[
  parameter(version,'ID','path',schema),parameter(version,'N','query',schema),parameter(version,'X-Exact','header',schema),
 ]),input=mockStart(source(document,format),{},'file:///parameter-fixture/api.'+format),original=JSON.stringify(input.capture),{port}=await startMock(t,input);
 const valid=await wire(port,'/precise/9007199254740993?N=9007199254740993.000',{'x-exact':'9007199254740993.00'});
 assert.equal(valid.status,204,valid.text);
 for(const [path,query,header,location]of [
  ['9007199254740992','9007199254740993','9007199254740993','path:ID'],
  ['9007199254740993','9007199254740992','9007199254740993','query:N'],
  ['9007199254740993','9007199254740993','9007199254740992','header:X-Exact'],
 ]){
  const response=await wire(port,'/precise/'+path+'?N='+query,{'X-Exact':header});
  assert.equal(response.status,422,location+': '+response.text);
  const findings=JSON.parse(response.headers['sl-violations']??'[]');
  assert.ok(findings.some(finding=>finding.nativeCode==='runtime.schema.incompatible'&&finding.location.includes(location)&&finding.source.resource===input.capture.root&&finding.source.range[1]>finding.source.range[0]),JSON.stringify(findings));
 }
 assert.equal(JSON.stringify(input.capture),original);
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} query/path names stay case-sensitive and header names do not`,{timeout:20000},async t=>{
 const document=contract(version,'/case/{ID}',[
  parameter(version,'ID','path',{type:'string',enum:['雪/é~']}),
  parameter(version,'Code','query',{type:'string',enum:['UPPER']}),
  parameter(version,'code','query',{type:'string',enum:['lower']}),
  parameter(version,'X-Case','header',{type:'string',enum:['value']}),
 ]),{port}=await startMock(t,mockStart(document));
 const path='/case/'+encodeURIComponent('雪/é~');
 const valid=await wire(port,path+'?Code=UPPER&code=lower',{'x-case':'value'});assert.equal(valid.status,204,valid.text);
 for(const query of ['Code=lower&code=UPPER','CODE=UPPER&code=lower','Code=UPPER&CODE=lower'])assert.equal((await wire(port,path+'?'+query,{'X-CASE':'value'})).status,422,query);
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} empty/false/zero parameter values retain their presence`,{timeout:20000},async t=>{
 const document=contract(version,'/scalars',[
  parameter(version,'empty','query',{type:'string',enum:['']},version==='2.0'?{allowEmptyValue:true}:{}),
  parameter(version,'flag','query',{type:'boolean',enum:[false]}),
  parameter(version,'zero','query',{type:'integer',enum:[0]}),
  parameter(version,'X-Empty','header',{type:'string',enum:['']}),
 ]),{port}=await startMock(t,mockStart(document));
 const valid=await wire(port,'/scalars?empty=&flag=false&zero=0',{'x-empty':''});assert.equal(valid.status,204,valid.text);
 for(const [query,headers]of [
  ['flag=false&zero=0',{'x-empty':''}],['empty=&flag=true&zero=0',{'x-empty':''}],
  ['empty=&flag=false&zero=1',{'x-empty':''}],['empty=&flag=false&zero=0',{}],
 ])assert.equal((await wire(port,'/scalars?'+query,headers)).status,422,query);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} native cookie parameter assertions are enforced`,{timeout:20000},async t=>{
 const document=contract(version,'/cookie',[
  parameter(version,'Flag','cookie',{type:'boolean',enum:[false]}),
  parameter(version,'Empty','cookie',{type:'string',enum:['']}),
 ]),{port}=await startMock(t,mockStart(document));
 assert.equal((await wire(port,'/cookie',{cookie:'Flag=false; Empty='})).status,204);
 for(const value of ['Flag=true; Empty=','flag=false; Empty=','Flag=false','Empty='])assert.equal((await wire(port,'/cookie',{cookie:value})).status,422,value);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} content parameter data retains JSON types and literal references`,{timeout:20000},async t=>{
 const schema={type:'object',required:['n','$ref'],properties:{n:{type:'integer',enum:['EXACT_VALUE']},$ref:{type:'string'}}};
 const document=contract(version,'/content',[{name:'data',in:'query',required:true,content:{'application/json':{schema}}}]),input=mockStart(source(document,'json')),{port}=await startMock(t,input);
 const query=n=>'/content?data='+encodeURIComponent('{"n":'+n+',"$ref":"./not-a-contract.json"}');
 const valid=await wire(port,query('9007199254740993.000'));assert.equal(valid.status,204,valid.text);
 assert.equal((await wire(port,query('9007199254740992'))).status,422);
 assert.equal((await wire(port,'/content?data='+encodeURIComponent('{bad'))).status,422);
});
