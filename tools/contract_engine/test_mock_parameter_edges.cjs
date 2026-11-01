const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const {mockStart,startMock}=require('./mock_test_capture.cjs');
function parameter(version,name,location,schema,extra={}){
 return {name,in:location,required:true,...(version==='2.0'?schema:{schema}),...extra};
}
function contract(version,parameters){return {...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Native parameter edges',version:'1'},paths:{'/p':{post:{parameters,responses:{204:{description:'Accepted'}}}}}};}
function wire(port,query='',headers={}){
 return new Promise((resolve,reject)=>{
  const req=http.request({host:'127.0.0.1',port,path:'/p'+(query?'?'+query:''),method:'POST',headers:{'content-length':'0',...headers}},res=>{
   const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.once('error',reject);
   res.once('end',()=>resolve({status:res.statusCode,headers:res.headers,text:Buffer.concat(chunks).toString()}));
  });req.once('error',reject);req.end();
 });
}

test('Swagger query empty-value permission remains independent from string schema validity',{timeout:20000},async t=>{
 const document=contract('2.0',[parameter('2.0','empty','query',{type:'string',enum:['']})]);
 const {port}=await startMock(t,mockStart(document));
 assert.equal((await wire(port,'empty=')).status,422);
 assert.equal((await wire(port,'empty')).status,422);
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} empty and prototype-like query/header names retain wire ownership`,{timeout:20000},async t=>{
 const document=contract(version,[parameter(version,'','query',{type:'string',enum:['empty-name']}),parameter(version,'__proto__','query',{type:'string',enum:['query']}),parameter(version,'__proto__','header',{type:'string',enum:['header']})]);
 const {port}=await startMock(t,mockStart(document));
 const valid=await wire(port,'=empty-name&__proto__=query',Object.fromEntries([['__proto__','header']]));
 assert.equal(valid.status,204,valid.text);
 assert.equal((await wire(port,'=empty-name&__proto__=wrong',Object.fromEntries([['__proto__','header']]))).status,422);
 assert.equal((await wire(port,'=empty-name&__proto__=query',Object.fromEntries([['__proto__','wrong']]))).status,422);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} malformed exploded header fields cannot disappear before native evaluation`,{timeout:20000},async t=>{
 const schema={type:'object',required:['A','b'],additionalProperties:false,properties:{A:{type:'integer',enum:[0]},b:{type:'boolean',enum:[false]}}};
 const {port}=await startMock(t,mockStart(contract(version,[parameter(version,'X-Object','header',schema,{style:'simple',explode:true})])));
 assert.equal((await wire(port,'',{'x-object':'A=0,b=false'})).status,204);
 assert.equal((await wire(port,'',{'x-object':'A=0,b=false,garbage'})).status,422);
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} a bounded large typed parameter set does not exhaust reports on invented string candidates`,{timeout:30000},async t=>{
 const parameters=Array.from({length:120},(_,index)=>parameter(version,'N'+index,'query',{type:'integer',enum:[0]}));
 const {port}=await startMock(t,mockStart(contract(version,parameters)));
 const query=parameters.map(parameter=>parameter.name+'=0').join('&');
 const valid=await wire(port,query);assert.equal(valid.status,204,valid.text);
 assert.equal((await wire(port,query.replace('N100=0','N100=1'))).status,422);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} undefined nested parameter models are explicitly incomplete`,{timeout:20000},async t=>{
 const nested={type:'object',properties:{child:{type:'object',required:['n'],properties:{n:{type:'integer'}}}},required:['child']};
 const {port}=await startMock(t,mockStart(contract(version,[parameter(version,'data','query',nested,{style:'deepObject'})])));
 for(const query of ['data[child][n]=1','data[child]=1']){
  const response=await wire(port,query);assert.equal(response.status,501,response.text);
  const result=JSON.parse(response.text);assert.equal(result.complete,false);
  assert.ok(result.findings.some(finding=>finding.kind==='unsupported'&&finding.source.range[1]>finding.source.range[0]));
 }
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} form-style cookie arrays use the form delimiter`,{timeout:20000},async t=>{
 const schema={type:'array',minItems:2,maxItems:2,items:{type:'integer',enum:[0,2]}};
 const {port}=await startMock(t,mockStart(contract(version,[parameter(version,'a','cookie',schema,{style:'form',explode:true})])));
 const valid=await wire(port,'',{cookie:'a=0&a=2'});assert.equal(valid.status,204,valid.text);
 assert.equal((await wire(port,'',{cookie:'a=0&a=3'})).status,422);
});
