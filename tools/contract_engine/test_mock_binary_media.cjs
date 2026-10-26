const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const {mockStart,capturedMockStart,startMock,mockRequest}=require('./mock_test_capture.cjs');

const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const bytes=Buffer.from([0,255,128]);
function document(version,schemas){
 const swagger=version==='2.0';
 return {...(swagger?{swagger:version,consumes:['application/octet-stream']}:{openapi:version}),info:{title:'Captured binary media',version:'3.2.1'},
  paths:Object.fromEntries(Object.entries(schemas).map(([name,schema])=>['/'+name,{post:{
   ...(swagger?{parameters:[{name:'body',in:'body',schema:schema??{}}]}:{requestBody:{content:{'application/octet-stream':schema===undefined?{}:{schema}}}}),
   responses:{204:{description:'Empty'}}}}]))};
}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} mock binary bodies retain their captured media owner`,{timeout:20000},async t=>{
 const legacy=version==='2.0'||version.startsWith('3.0.');
 const value=document(version,{free:undefined,empty:{},valid:legacy?{format:'binary',minLength:3,maxLength:3,enum:[bytes.toString('latin1')]}:{not:{type:'null'}},invalid:legacy?{maxLength:2}:{type:'string',format:'binary'}});
 const source=format==='json'?JSON.stringify(value):'# Original 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
 const input=mockStart(source,{},'file:///mock-fixture/api.'+format),before=JSON.stringify(input.capture),{port}=await startMock(t,input);
 for(const path of ['free','empty','valid']){
  const result=await mockRequest(port,'/'+path,bytes,{mediaType:'application/octet-stream'});
  assert.equal(result.status,204,result.text);
 }
 const invalid=await mockRequest(port,'/invalid',bytes,{mediaType:'application/octet-stream'});
 assert.equal(invalid.status,422,invalid.text);
 assert(!invalid.text.includes('runtime.request.body.unchecked'),invalid.text);
 const empty=await mockRequest(port,'/free',Buffer.alloc(0),{mediaType:'application/octet-stream'});assert.equal(empty.status,204,empty.text);
 assert.equal(JSON.stringify(input.capture),before);
});

for(const format of ['yaml','json'])test(`Swagger ${format} file and schema-free responses are checked on actual proxy bytes`,{timeout:20000},async t=>{
 const seen=[];
 const upstream=http.createServer((request,response)=>{
  const parts=[];request.on('data',part=>parts.push(part));request.on('end',()=>{
   seen.push({method:request.method,path:request.url,bytes:Buffer.concat(parts)});
   const empty=['/empty','/untyped-empty'].includes(request.url),untyped=request.url.startsWith('/untyped-');
   response.writeHead(200,{...(!untyped?{'content-type':'application/json'}:{}),'content-length':empty?0:bytes.length});
   response.end(empty?undefined:bytes);
  });
 });
 await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
 t.after(()=>new Promise(resolve=>{upstream.closeAllConnections();upstream.close(resolve);}));
 const value={swagger:'2.0',info:{title:'Original file response',version:'3.2.1'},produces:['application/json'],paths:Object.fromEntries(['file','empty','forbidden','untyped-empty','untyped-forbidden'].map(name=>['/'+name,{post:{responses:{200:{$ref:'#/responses/'+(name==='file'?'File':'Empty')}}}}])),responses:{File:{description:'Binary file',schema:{$ref:'#/responses/Bytes/schema'}},Bytes:{description:'Reusable file schema',schema:{$ref:'./response-file.'+format}},Empty:{description:'No response content'}}};
 const source=format==='json'?JSON.stringify(value):YAML.stringify(value),root='file:///mock-fixture/api.'+format;
 const resource=(id,text)=>({id,text,generation:2,identity:createHash('sha256').update(text).digest('hex')});
 const input=capturedMockStart({root,snapshot:'a'.repeat(64),resources:[resource(root,source),resource('file:///mock-fixture/response-file.'+format,'{"type":"file"}')]},{upstream:'http://127.0.0.1:'+upstream.address().port}),original=JSON.stringify(input.capture),{port}=await startMock(t,input);
 const file=await mockRequest(port,'/file',undefined);assert.equal(file.status,200,file.text);
 assert.equal(file.headers['sl-violations'],undefined,JSON.stringify(file.headers));
 const empty=await mockRequest(port,'/empty',undefined);assert.equal(empty.status,200,empty.text);assert.equal(empty.headers['sl-violations'],undefined);
 const forbidden=await mockRequest(port,'/forbidden',undefined);assert.equal(forbidden.status,200,forbidden.text);
 assert(JSON.parse(forbidden.headers['sl-violations']).some(finding=>finding.code==='runtime.response.body.forbidden'),JSON.stringify(forbidden.headers));
 const untypedEmpty=await mockRequest(port,'/untyped-empty',undefined);assert.equal(untypedEmpty.status,200,untypedEmpty.text);assert.equal(untypedEmpty.headers['sl-violations'],undefined);
 const untypedForbidden=await mockRequest(port,'/untyped-forbidden',undefined);assert.equal(untypedForbidden.status,200,untypedForbidden.text);
 assert(JSON.parse(untypedForbidden.headers['sl-violations']).some(finding=>finding.code==='runtime.response.body.forbidden'),JSON.stringify(untypedForbidden.headers));
 assert.deepEqual(seen.map(value=>[value.method,value.path,value.bytes.length]),[['POST','/file',0],['POST','/empty',0],['POST','/forbidden',0],['POST','/untyped-empty',0],['POST','/untyped-forbidden',0]]);
 assert.equal(JSON.stringify(input.capture),original);
});
