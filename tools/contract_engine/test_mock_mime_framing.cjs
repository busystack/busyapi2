const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {mockStart,startMock,mockRequest}=require('./mock_test_capture.cjs');

function capture(version,format,nested=false){
 const media=nested?'multipart/mixed':'multipart/form-data',legacy=version==='2.0';
 const content={[media]:{schema:nested?{type:'array',items:{type:'array',items:{type:'string'}}}:{type:'object',properties:{value:{type:'string'}}},
  ...(nested?{itemEncoding:{contentType:'multipart/mixed',itemEncoding:{contentType:'text/plain'}}}:{})}};
 const document={...(legacy?{swagger:version,consumes:[media]}:{openapi:version}),info:{title:'Keep 雪',version:'unchanged'},paths:{'/parts':{post:{
  ...(legacy?{parameters:[{in:'formData',name:'value',type:'string',allowEmptyValue:true}]}:{requestBody:{content}}),responses:{204:{description:'Keep response'}}}}}};
 return mockStart(format==='json'?JSON.stringify(document):'# Keep CRLF\r\n'+YAML.stringify(document).replaceAll('\n','\r\n'),{},'file:///mock-fixture/api.'+format);
}
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} actual mock refuses empty and boundary-prefix MIME framing`,{timeout:20000},async t=>{
 const input=capture(version,format),original=JSON.stringify(input.capture),{port}=await startMock(t,input);
 const wire=value=>'--Fixture\r\nContent-Disposition: form-data; name="value"\r\n\r\n'+value+'\r\n--Fixture--\r\n';
 const send=body=>mockRequest(port,'/parts',body,{mediaType:'multipart/form-data; boundary=Fixture'});
 for(const body of [wire(''),wire('inside--Fixture-is-data'),wire('before\r\n--Other-is-data\r\nafter')]){
  const result=await send(body);assert.equal(result.status,204,result.text);
 }
 for(const body of ['--Fixture--\r\n',wire('before\r\n--Fixture-is-data\r\nafter'),wire('before\r\n--Fixture--invalid\r\nafter')]){
  const result=await send(body);assert.equal(result.status,422,result.text);
  const findings=JSON.parse(result.headers['sl-violations']);assert(findings.some(value=>value.nativeCode==='runtime.body.syntax'&&value.source?.resource===input.capture.root&&value.source.pointer.startsWith('/paths/~1parts/post')&&Array.isArray(value.source.range)),JSON.stringify(findings));
 }
 assert.equal(JSON.stringify(input.capture),original);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} actual mock refuses a nested boundary beginning with its enclosing boundary`,{timeout:20000},async t=>{
 const input=capture(version,format,true),original=JSON.stringify(input.capture),{port}=await startMock(t,input);
 const wire=boundary=>'--Fixture\r\nContent-Type: multipart/mixed; boundary='+boundary+'\r\n\r\n--'+boundary+'\r\n\r\nvalue\r\n--'+boundary+'--\r\n\r\n--Fixture--\r\n';
 for(const [boundary,status]of [['Inner',204],['FixtureNested',422],['Fixture--Nested',422]]){
  const result=await mockRequest(port,'/parts',wire(boundary),{mediaType:'multipart/mixed; boundary=Fixture'});assert.equal(result.status,status,result.text);
 }
 assert.equal(JSON.stringify(input.capture),original);
});
