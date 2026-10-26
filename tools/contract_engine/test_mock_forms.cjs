const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {mockStart,startMock,mockRequest}=require('./mock_test_capture.cjs');

function document(version) {
 const legacy=version==='2.0',properties={
  amount:{type:'integer',enum:['__exact__']},flag:{type:'boolean',enum:[false]},
  label:{type:'string',enum:['雪+é']},ids:{type:'array',minItems:2,maxItems:2,uniqueItems:true,items:{type:'integer',minimum:0}},empty:{type:'string',maxLength:0},
  ...(legacy?{}:{meta:{type:'object',properties:{$ref:{type:'string'},tiny:{type:'number',minimum:0}},required:['$ref','tiny']}}),
 };
 const media={'application/x-www-form-urlencoded':{schema:{type:'object',properties,required:Object.keys(properties),additionalProperties:false}},
  'multipart/form-data':{schema:{type:'object',properties,required:Object.keys(properties),additionalProperties:false}}};
 return {...(legacy?{swagger:version,consumes:Object.keys(media)}:{openapi:version}),info:{title:'Native form bodies',version:'1'},
  paths:{'/form':{post:{...(legacy?{parameters:Object.entries(properties).map(([name,schema])=>({name,in:'formData',required:true,...schema,...(schema.type==='array'?{collectionFormat:'multi'}:{}),...(name==='empty'?{allowEmptyValue:true}:{})}))}:{requestBody:{required:true,content:media}}),responses:{204:{description:'Empty'}}}}}};
}
function fields(legacy) {
 return [['amount','9007199254740993'],['flag','false'],['label','雪+é'],['ids','0'],['ids','2'],['empty',''],
  ...(legacy?[]:[['meta','{"$ref":"./not-a-reference.json","tiny":1e-999}']])];
}
function wire(entries,multipart) {
 if(!multipart)return {body:entries.map(([name,value])=>encodeURIComponent(name)+'='+encodeURIComponent(value)).join('&'),mediaType:'application/x-www-form-urlencoded'};
 const boundary='busyapi-native-form-boundary';
 const body=entries.map(([name,value])=>'--'+boundary+'\r\nContent-Disposition: form-data; name="'+name+'"\r\nContent-Type: '+(name==='meta'?'application/json':'text/plain; charset=utf-8')+'\r\n\r\n'+value+'\r\n').join('')+'--'+boundary+'--\r\n';
 return {body,mediaType:'multipart/form-data; boundary='+boundary};
}

for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['json','yaml'])test(`${version} ${format} native mocks decode exact URL-encoded and multipart form instances`,{timeout:20000},async t=>{
 const legacy=version==='2.0',value=document(version),serialized=format==='json'?JSON.stringify(value):YAML.stringify(value);
 const source=serialized.replaceAll(format==='json'?'"__exact__"':'__exact__','9007199254740993.00'),input=mockStart(source,{},'file:///mock-fixture/api.'+format),original=JSON.stringify(input.capture),{port}=await startMock(t,input);
 for(const multipart of [false,true]){
  const send=async values=>{const {body,mediaType}=wire(values,multipart);return mockRequest(port,'/form',body,{mediaType});};
  const positive=await send(fields(legacy));assert.equal(positive.status,204,positive.text);
  for(const values of [
   fields(legacy).map(([name,value])=>[name,name==='amount'?'9007199254740992':value]),
   fields(legacy).map(([name,value])=>[name,name==='flag'?'true':value]),
   fields(legacy).filter(([name])=>name!=='flag'),
   fields(legacy).map(([name,value])=>[name,name==='ids'?'0':value]),
   fields(legacy).filter(([name,value])=>name!=='ids'||value!=='2'),
  ]){const result=await send(values);assert.equal(result.status,422,result.text);}
  if(!legacy){const unknown=await send([...fields(legacy),['unknown','x']]);assert.equal(unknown.status,422,unknown.text);}
 }
 assert.equal(JSON.stringify(input.capture),original);
});

function multipart(parts,boundary='native-file-boundary') {
 return {mediaType:'multipart/form-data; boundary='+boundary,body:Buffer.concat(parts.flatMap(part=>[
  Buffer.from('--'+boundary+'\r\nContent-Disposition: form-data; name="'+part.name+'"'+(part.filename===undefined?'':'; filename="'+part.filename+'"')+'\r\nContent-Type: '+(part.type??'application/octet-stream')+'\r\n'+(part.transfer===undefined?'':'Content-Transfer-Encoding: '+part.transfer+'\r\n')+'\r\n'),
  Buffer.isBuffer(part.data)?part.data:Buffer.from(part.data),Buffer.from('\r\n'),
 ]).concat(Buffer.from('--'+boundary+'--\r\n')))};
}
function binaryContract(version,schema,encoding) {
 return {openapi:version,info:{title:'Native file binding',version:'1'},paths:{'/form':{post:{requestBody:{required:true,content:{'multipart/form-data':{
  schema:{type:'object',properties:{file:schema},required:['file'],additionalProperties:false},...(encoding?{encoding:{file:encoding}}:{}),
 }}},responses:{204:{description:'Empty'}}}}}};
}
async function sendPart(port,data,transfer) {
 const {body,mediaType}=multipart([{name:'file',filename:'café.bin',data,transfer}]);return mockRequest(port,'/form',body,{mediaType});
}

for(const version of ['3.0.0','3.0.4'])test(`${version} native mock file instances retain all binary octets before transfer decoding`,{timeout:20000},async t=>{
 const data=Buffer.from([0,255,65]),schema={type:'string',format:'binary',minLength:3,maxLength:3,enum:[data.toString('latin1')]};
 const encoding={headers:{'Content-Transfer-Encoding':{required:true,schema:{type:'string',enum:['base64']}}}};
 const {port}=await startMock(t,mockStart(binaryContract(version,schema,encoding)));
 assert.equal((await sendPart(port,'AP9B','base64')).status,204);
 for(const value of ['AA==','AP9BAA==','AP9C'])assert.equal((await sendPart(port,value,'base64')).status,422);
 assert.equal((await sendPart(port,'AP9B')).status,422,'required part header must not disappear');
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} native mock keeps schema-encoded strings distinct from decoded file octets`,{timeout:20000},async t=>{
 const schema={type:'string',...(version==='3.0.4'?{format:'byte'}:{contentEncoding:'base64'}),enum:['AP9B'],minLength:4,maxLength:4};
 const {port}=await startMock(t,mockStart(binaryContract(version,schema)));
 assert.equal((await sendPart(port,'AP\r\n9B','base64')).status,204);
 assert.equal((await sendPart(port,'AP9C','base64')).status,422);
 const conflict=await sendPart(port,'AP9B','base16');assert.equal(conflict.status,501,conflict.text);
 assert.ok(JSON.parse(conflict.text).findings.some(finding=>finding.source.pointer.endsWith(version==='3.0.4'?'/format':'/contentEncoding')));
});

for(const [encoding,value]of [['base64','Zm9vYmFy'],['base64url','Zm9vYmFy'],['base16','666f6f626172'],['base32','MZXW6YTBOI======'],['base32hex','CPNMUOJ1E8======'],['quoted-printable','foo=3Dbar'],['binary','foobar'],['identity','foobar'],['7bit','foobar'],['8bit','foobar']])test(`native multipart ${encoding} evaluates the encoded schema string`,{timeout:20000},async t=>{
 const {port}=await startMock(t,mockStart(binaryContract('3.2.1',{type:'string',contentEncoding:encoding,enum:[value]})));
 const result=await sendPart(port,value,encoding);assert.equal(result.status,204,result.text);
});

for(const version of ['3.1.2','3.2.1'])test(`${version} format binary alone cannot select the legacy octet-string model`,{timeout:20000},async t=>{
 const {port}=await startMock(t,mockStart(binaryContract(version,{type:'string',format:'binary',minLength:3},{contentType:'application/octet-stream'})));
 const result=await sendPart(port,Buffer.from([0,255,65]));assert.equal(result.status,422,result.text);
 const response=JSON.parse(result.text);
 assert(response.validation.some(finding=>finding.message.startsWith('runtime.schema.incompatible:')));
 assert(!response.validation.some(finding=>finding.message.includes('unchecked')));
 // The generated error response is still not an authored response contract.
 assert.equal(response.complete,false);
});

test('Swagger file parameters validate presence and MIME framing without becoming Schema Objects',{timeout:20000},async t=>{
 const source={swagger:'2.0',info:{title:'File parameter',version:'1'},consumes:['multipart/form-data'],paths:{'/form':{post:{parameters:[{in:'formData',name:'file',type:'file',required:true}],responses:{204:{description:'Empty'}}}}}};
 const {port}=await startMock(t,mockStart(source));
 for(const data of [Buffer.alloc(0),Buffer.from([0,255,65])])assert.equal((await sendPart(port,data)).status,204);
 const {body,mediaType}=multipart([{name:'other',data:'not the file'}]);assert.equal((await mockRequest(port,'/form',body,{mediaType})).status,422);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} form styles retain encoded delimiters, objects and scalar kinds`,{timeout:20000},async t=>{
 const schema={type:'object',required:['csv','options'],properties:{
  csv:{type:'array',minItems:2,maxItems:2,items:{type:'string'}},
  options:{type:'object',required:['zero','no','empty','unicode'],properties:{zero:{type:'integer',maximum:0},no:{type:'boolean',enum:[false]},empty:{type:'string',maxLength:0},unicode:{type:'string',enum:['雪+é']}}},
 },additionalProperties:false};
 const value=binaryContract(version,schema);
 value.paths['/form'].post.requestBody.content={'application/x-www-form-urlencoded':{schema,encoding:{csv:{style:'form',explode:false},options:{style:'deepObject',explode:true}}}};
 const {port}=await startMock(t,mockStart(value));
 const raw='csv=a%2Cb,%E9%9B%AA&options%5Bzero%5D=-0&options%5Bno%5D=false&options%5Bempty%5D=&options%5Bunicode%5D=%E9%9B%AA%2B%C3%A9';
 const positive=await mockRequest(port,'/form',raw,{mediaType:'application/x-www-form-urlencoded'});assert.equal(positive.status,204,positive.text);
 const bad=await mockRequest(port,'/form',raw.replace('=false','=true'),{mediaType:'application/x-www-form-urlencoded'});assert.equal(bad.status,422,bad.text);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} multipart style applicability follows the owning family`,{timeout:20000},async t=>{
 const schema={type:'object',required:['ids'],properties:{ids:{type:'array',minItems:2,maxItems:2,items:{type:'integer',minimum:0}}}};
 const value=binaryContract(version,schema);
 value.paths['/form'].post.requestBody.content['multipart/form-data']={schema,encoding:{ids:{style:'form',explode:false,contentType:'application/json'}}};
 const {port}=await startMock(t,mockStart(value));
 const input=multipart(version==='3.0.4'?[{name:'ids',type:'application/json',data:'0'},{name:'ids',type:'application/json',data:'2'}]:[{name:'ids',type:'text/plain',data:'0,2'}]);
 const positive=await mockRequest(port,'/form',input.body,{mediaType:input.mediaType});assert.equal(positive.status,204,positive.text);
});

test('Swagger form collectionFormat and Items Objects retain their distinct wire meanings',{timeout:20000},async t=>{
 const formats={csv:',',ssv:' ',tsv:'\t',pipes:'|',multi:undefined};
 const value={swagger:'2.0',info:{title:'Native collections',version:'1'},consumes:['application/x-www-form-urlencoded'],paths:{'/form':{post:{
  parameters:Object.keys(formats).map(name=>({name,in:'formData',required:true,type:'array',collectionFormat:name,minItems:2,maxItems:2,items:{type:'integer',minimum:0}})),responses:{204:{description:'Empty'}},
 }}}};
 const {port}=await startMock(t,mockStart(value)),raw=Object.entries(formats).flatMap(([name,separator])=>separator===undefined?[name+'=0',name+'=2']:[name+'='+encodeURIComponent('0'+separator+'2')]).join('&');
 const positive=await mockRequest(port,'/form',raw,{mediaType:'application/x-www-form-urlencoded'});assert.equal(positive.status,204,positive.text);
 const bad=await mockRequest(port,'/form',raw.replace('csv=0%2C2','csv=-1%2C2'),{mediaType:'application/x-www-form-urlencoded'});assert.equal(bad.status,422,bad.text);
});

test('MIME framing rejects malformed boundaries, singleton headers and escapes without partial success',{timeout:20000},async t=>{
 const value=binaryContract('3.0.4',{type:'string',format:'binary'}),{port}=await startMock(t,mockStart(value));
 const valid=multipart([{name:'file',data:Buffer.from([0,255,65])}]);
 for(const [body,mediaType]of [
  [valid.body,'multipart/form-data'],
  [valid.body.subarray(0,valid.body.length-25),valid.mediaType],
  [Buffer.from(valid.body.toString('latin1').replace('Content-Disposition:','Content-Disposition: form-data; name="file"\r\nContent-Disposition:'),'latin1'),valid.mediaType],
  [Buffer.from(valid.body.toString('latin1').replace('Content-Type: application/octet-stream','Content-Type: application/octet-stream\r\nContent-Type: application/octet-stream'),'latin1'),valid.mediaType],
 ]){const result=await mockRequest(port,'/form',body,{mediaType});assert.equal(result.status,422,result.text);}
 const form=document('3.0.4');const other=await startMock(t,mockStart(form));
 for(const raw of [Buffer.from('amount=%G0'),Buffer.from([97,109,111,117,110,116,61,37,185,177])]){
  const result=await mockRequest(other.port,'/form',raw,{mediaType:'application/x-www-form-urlencoded'});assert.equal(result.status,422,result.text);
 }
});

test('a delimiter-looking file sequence is retained and MIME preambles/epilogues stay outside the instance',{timeout:20000},async t=>{
 const data=Buffer.from('before\r\n--native-file-boundary-is-data\r\nafter'),schema={type:'string',format:'binary',enum:[data.toString('latin1')]};
 const {port}=await startMock(t,mockStart(binaryContract('3.0.4',schema))),wire=multipart([{name:'file',data}]);
 const body=Buffer.concat([Buffer.from('preamble\r\n'),wire.body,Buffer.from('epilogue')]);
 const result=await mockRequest(port,'/form',body,{mediaType:wire.mediaType});assert.equal(result.status,204,result.text);
});

test('ignored MIME extension headers remain visible without blocking a valid native mock response',{timeout:20000},async t=>{
 const value=binaryContract('3.0.4',{type:'string',format:'binary'},{headers:{'X-Not-A-MIME-Part-Header':{required:true,schema:{type:'string'}}}});
 const {port}=await startMock(t,mockStart(value)),result=await sendPart(port,Buffer.from([0,255]));assert.equal(result.status,204,result.text);
 const notes=JSON.parse(result.headers['sl-violations']);assert.ok(notes.some(note=>note.code==='runtime.form.header.ignored'&&note.source.pointer.includes('/headers/')));
});
