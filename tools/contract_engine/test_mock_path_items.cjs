const {test}=require('node:test'),assert=require('node:assert/strict'),http=require('node:http'),{createHash}=require('node:crypto'),YAML=require('yaml');
const {capturedMockStart,startMock,mockStart}=require('./mock_test_capture.cjs');
function wire(port,path,method='GET',headers={},body){
 return new Promise((resolve,reject)=>{
  const request=http.request({host:'127.0.0.1',port,path,method,headers},response=>{
   const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,text:Buffer.concat(chunks).toString()}));
  });request.once('error',reject);request.end(body);
 });
}
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} mock routes use canonical chained Path Items and exact operation examples`,{timeout:20000},async t=>{
 const root='file:///path-mock/api.'+format,part='file:///path-mock/paths.'+format,legacy=version==='2.0',schema={type:'integer',enum:['EXACT']};
 const response={description:'Exact',...(legacy?{schema:{type:'object',properties:{id:schema}},examples:{'application/json':{id:'EXACT',empty:'',flag:false,n:null,$ref:'literal'}}}:{content:{'application/json':{schema:{type:'object',properties:{id:schema}},example:{id:'EXACT',empty:'',flag:false,n:null,$ref:'literal'}}}})};
 const document={...(legacy?{swagger:version,produces:['application/json']}:{openapi:version}),info:{title:'Path projection',version:'api-version'},...(legacy?{securityDefinitions:{Key:{type:'apiKey',in:'header',name:'X-Key'}}}:{components:{securitySchemes:{Key:{type:'apiKey',in:'header',name:'X-Key'}}}}),paths:{'/p/{ID}':{$ref:'paths.'+format+'#/Alias',parameters:[{name:'ID',in:'path',required:true,...(legacy?schema:{schema})}]}}};
 document.paths['/q/{ID}']=document.paths['/p/{ID}'];
 const shared={Alias:{$ref:'#/Path'},Path:{get:{security:[{Key:[]}],responses:{200:response}},post:{security:[],responses:{204:{description:'Empty'}}}}};
 const encode=value=>(format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 const capture={root,snapshot:'0'.repeat(64),resources:[{id:root,text:encode(document)},{id:part,text:encode(shared)}].map(resource=>({...resource,generation:1,identity:createHash('sha256').update(resource.text).digest('hex')}))};
 const original=JSON.stringify(capture),{port,operations}=await startMock(t,capturedMockStart(capture));assert.equal(operations,4);
 const good=await wire(port,'/p/9007199254740993','GET',{'X-Key':'synthetic-private-value'});assert.equal(good.status,200,good.text);assert.ok(good.text.includes('9007199254740993.00'),good.text);assert.equal(good.headers['sl-violations'],undefined);
 const reused=await wire(port,'/q/9007199254740993','GET',{'X-Key':'synthetic-private-value'});assert.equal(reused.status,200,reused.text);assert.equal(reused.text,good.text);
 const value=JSON.parse(good.text);assert.equal(value.empty,'');assert.equal(value.flag,false);assert.equal(value.n,null);assert.equal(value.$ref,'literal');
 const bad=await wire(port,'/p/9007199254740992','GET',{'X-Key':'synthetic-private-value'});assert.equal(bad.status,422,bad.text);
 const findings=JSON.parse(bad.headers['sl-violations']??'[]');assert.ok(findings.some(finding=>finding.source?.resource===root&&finding.nativeCode==='runtime.schema.incompatible'));
 const unauthenticated=await wire(port,'/p/9007199254740993');assert.equal(unauthenticated.status,401);assert.ok(JSON.parse(unauthenticated.headers['sl-violations']).some(finding=>finding.source.resource===part&&finding.source.pointer==='/Path/get/security/0'));
 assert.equal((await wire(port,'/p/9007199254740993','POST',{authorization:'Bearer unrelated'})).status,204);
 assert.equal(JSON.stringify(capture),original);
});
for(const format of ['yaml','json'])test(`3.2 ${format} canonical QUERY dispatch preserves actual body and security semantics`,{timeout:20000},async t=>{
 const document={openapi:'3.2.1',info:{title:'Query routing',version:'1'},
  components:{securitySchemes:{Key:{type:'apiKey',in:'header',name:'X-Key'}}},
  paths:{'/search':{query:{
   security:[{Key:[]}],requestBody:{required:true,content:{'text/plain':{schema:{type:'string',enum:['hello']}}}},
   responses:{204:{description:'Empty'}},
  }}},
 };
 const input=mockStart(format==='json'?JSON.stringify(document):YAML.stringify(document),{},'file:///query/api.'+format),{port,operations}=await startMock(t,input);assert.equal(operations,1);
 const headers={'X-Key':'synthetic-private-value','content-type':'text/plain','content-length':'5'};
 const valid=await wire(port,'/search?x=0','QUERY',headers,'hello');assert.equal(valid.status,204,valid.text);
 const invalid=await wire(port,'/search?x=0','QUERY',headers,'wrong');assert.equal(invalid.status,422,invalid.text);
 assert.equal((await wire(port,'/search?x=0','QUERY',{'content-type':'text/plain','content-length':'5'},'hello')).status,401);
});
