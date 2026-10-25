const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {mockStart,startMock,mockRequest}=require('./mock_test_capture.cjs');

function wire(number,nested){
 const second=nested?'Content-Type: multipart/mixed; boundary=Inner\r\n\r\n--Inner\r\n\r\nfalse\r\n--Inner\r\n\r\n0\r\n--Inner--\r\n':'Content-Type: text/plain\r\n\r\n';
 return '--Fixture\r\nContent-Type: application/json\r\n\r\n{"id":'+number+'}\r\n--Fixture\r\n'+second+'\r\n--Fixture--\r\n';
}
for(const version of ['3.2.0','3.2.1'])for(const format of ['json','yaml'])for(const nested of [false,true])test(`${version} ${format} ${nested?'nested':'ordered'} mock validates original multipart wire values`,{timeout:20000},async t=>{
 const second=nested?{type:'array',minItems:2,maxItems:2,prefixItems:[{type:'boolean',const:false},{type:'integer',const:0}],items:false}:{type:'string',maxLength:0};
 const media={schema:{type:'array',minItems:2,maxItems:2,prefixItems:[{type:'object',required:['id'],properties:{id:{type:'integer',enum:['EXACT']}},additionalProperties:false},second],items:false},
  prefixEncoding:[{contentType:'application/json'},nested?{contentType:'multipart/mixed',itemEncoding:{contentType:'text/plain'}}:{contentType:'text/plain'}]};
 const value={openapi:version,info:{title:'Captured multipart',version:'unchanged'},paths:{'/parts':{post:{requestBody:{required:true,content:{'multipart/mixed':media}},responses:{204:{description:'Empty'}}}}}};
 const source=(format==='json'?JSON.stringify(value):'# Keep exact values 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 const input=mockStart(source,{},'file:///mock-fixture/api.'+format),original=JSON.stringify(input.capture),{port}=await startMock(t,input);
 const send=body=>mockRequest(port,'/parts',body,{mediaType:'multipart/mixed; boundary=Fixture'});
 const positive=await send(wire('9007199254740993.00',nested));assert.equal(positive.status,204,positive.text);
 for(const body of [wire('9007199254740992',nested),wire('9007199254740993.00',nested).replace('"id":','"missing":'),wire('9007199254740993.00',nested).replace('--Fixture--','--Other--'),
  ...(nested?[wire('9007199254740993.00',nested).replace('false','true')]:[])]){
  const invalid=await send(body);assert.equal(invalid.status,422,invalid.text);
 }
 assert.equal(JSON.stringify(input.capture),original);
});
