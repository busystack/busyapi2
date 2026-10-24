const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {requestMultipartEncoding}=require('./dist/execution.cjs');

const root='file:///multipart/api.json',external='file:///multipart/shared.yaml';
function packet(version,format='json'){
 const encoded=version.startsWith('3.0.')?{type:'string',format:'byte'}:{type:['string','null'],contentEncoding:'base64'};
 const shared={Field:encoded,Header:{$ref:'#/ActualHeader'},ActualHeader:{schema:{type:'string',enum:['base64'],pattern:'^base64$'}}};
 const value={openapi:version,info:{title:'MIME',version:'unrelated'},paths:{'/upload':{post:{requestBody:{content:{'multipart/form-data':{
  schema:{allOf:[{type:'object',properties:{encoded:{$ref:'shared.yaml#/Field'},array:{type:'array',items:{$ref:'shared.yaml#/Field'}},raw:{type:'object'},optional:encoded}}]},
  encoding:{encoded:{headers:{'Content-Transfer-Encoding':{$ref:'shared.yaml#/Header'}}},raw:{contentType:'application/json',headers:{'content-transfer-encoding':{$ref:'shared.yaml#/Header'}}}}
 }}},responses:{204:{description:'ok'}}}}}};
 const text=format==='json'?JSON.stringify(value):'# Native MIME fixture\n'+YAML.stringify(value);
 const resource=format==='yaml'?root.replace('.json','.yaml'):root;
 return {root:resource,snapshot:version+'-'+format,resource,pointer:'/paths/~1upload/post',mediaType:'multipart/form-data',resources:[{id:resource,text,generation:2},{id:external,text:YAML.stringify(shared),generation:3}],parts:[{name:'encoded',kind:'string'},{name:'array',kind:'item-string'},{name:'raw',kind:'other'},{name:'optional',kind:'other'}],files:[]};
}

for(const version of ['3.0.0','3.0.4','3.1.0','3.1.2','3.2.0','3.2.1'])for(const format of ['json','yaml'])test(`${version} ${format} resolves native implicit, explicit and referenced transfer encodings`,async()=>{
 const input=packet(version,format),before=input.resources.map(value=>value.text);
 const result=await requestMultipartEncoding(input);
 assert.equal(result.snapshot,input.snapshot);assert.match(result.identity,/^[0-9a-f]{64}$/);
 assert.equal(result.parts.encoded.string.encoding,'base64');assert.equal(result.parts.encoded.string.schemaEncoded,true);
 assert.equal(result.parts.encoded.string.source.resource,input.root);
 assert.match(result.parts.encoded.string.source.pointer,/headers\/Content-Transfer-Encoding$/);
 assert.ok(result.parts.encoded.string.source.range[1]>result.parts.encoded.string.source.range[0]);
 assert.equal(result.parts.array.string.encoding,'base64');assert.equal(result.parts.array.string.source.resource,external);
 assert.equal(result.parts.raw.other.encoding,'base64');assert.equal(result.parts.raw.other.schemaEncoded,false);
 assert.deepEqual({...result.parts.optional.other},{schemaEncoded:false});
 assert.deepEqual(input.resources.map(value=>value.text),before);
});

function mutate(input,change){
 const value=JSON.parse(input.resources[0].text);change(value.paths['/upload'].post.requestBody.content['multipart/form-data'],value);
 return {...input,resources:[{...input.resources[0],text:JSON.stringify(value)},...input.resources.slice(1)]};
}
for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} conflicting transfer headers and unresolved references cannot be prepared`,async()=>{
 const input=packet(version);
 for(const schema of [{type:'string',enum:['binary']},{type:'string',pattern:'^quoted-printable$'}]){
  const changed=mutate(input,media=>{media.encoding.encoded.headers['Content-Transfer-Encoding']={schema};});
  await assert.rejects(requestMultipartEncoding(changed),error=>error.code==='request.multipart.encoding.undefined'&&error.range[1]>error.range[0]);
 }
 for(const ref of ['missing.yaml#/Header','shared.yaml#/Missing']){
  const changed=mutate(input,media=>{media.encoding.encoded.headers['Content-Transfer-Encoding']={$ref:ref};});
  await assert.rejects(requestMultipartEncoding(changed),error=>error.code==='request.reference'&&error.range[1]>error.range[0]);
 }
 const forbidden=mutate(input,media=>{media.encoding.encoded.headers['X-Custom']={schema:{type:'string'}};});
 await assert.rejects(requestMultipartEncoding(forbidden),error=>error.code==='request.multipart.headers');
});

test('legacy byte format is not a modern content encoding, and non-string instances ignore modern content annotations',async()=>{
 const input=mutate(packet('3.2.1'),media=>{
  media.schema={type:'object',properties:{plain:{type:'string',format:'byte'},union:{type:['string','integer','null'],contentEncoding:'base64'}}};delete media.encoding;
 });
 const result=await requestMultipartEncoding({...input,parts:[{name:'plain',kind:'literal'},{name:'union',kind:'other'},{name:'union',kind:'string'}]});
 assert.deepEqual({...result.parts.plain.string},{schemaEncoded:false});
 assert.deepEqual({...result.parts.union.other},{schemaEncoded:false});
 assert.equal(result.parts.union.string.encoding,'base64');
});

test('transfer token policy checks constraints instead of guessing from an enum or example',async()=>{
 const input=mutate(packet('3.0.4'),media=>{
  media.encoding.raw.headers['content-transfer-encoding']={schema:{type:'string',enum:['binary','base64'],pattern:'^base64$'}};
 });
 const result=await requestMultipartEncoding({...input,parts:[{name:'raw',kind:'other'}]});
 assert.equal(result.parts.raw.other.encoding,'base64');
 const example=mutate(input,media=>{media.encoding.raw.headers['content-transfer-encoding'].example='binary';});
 await assert.rejects(requestMultipartEncoding({...example,parts:[{name:'raw',kind:'other'}]}),error=>error.code==='request.multipart.header.invalid');
});

test('unsupported and ambiguous annotations remain serialization limitations, not invented schema failures',async()=>{
 for(const change of [
  media=>{media.schema.allOf[0].properties.encoded={type:'string',contentEncoding:'rot13'};delete media.encoding;},
  media=>{media.schema.allOf[0].properties.encoded={allOf:[{type:'string',contentEncoding:'base64'},{contentEncoding:'base16'}]};delete media.encoding;},
  media=>{media.schema.allOf[0].properties.encoded={oneOf:[{type:'string',contentEncoding:'base64'},{type:'string',contentEncoding:'base16'}]};delete media.encoding;},
  (media,value)=>{value.jsonSchemaDialect='https://unsupported.invalid/dialect';delete media.encoding;},
 ]){
  const input=mutate(packet('3.2.1'),change);
  await assert.rejects(requestMultipartEncoding({...input,parts:[{name:'encoded',kind:'string'}]}),error=>['request.multipart.encoding.unsupported','request.multipart.encoding.undefined','request.multipart.dialect.unsupported'].includes(error.code));
 }
});

test('an unimplemented token in a referenced header schema is incomplete, not an invalid contract',async()=>{
 const input=packet('3.2.1'),shared={Field:{type:'string',contentEncoding:'base64'},Header:{schema:{$ref:'#/Token'}},Token:{type:'string',enum:['unimplemented-token']}};
 const resources=[input.resources[0],{...input.resources[1],text:YAML.stringify(shared)}];
 assert.equal(require('./dist/model.cjs').analyse({...input,resources}).complete,true);
 await assert.rejects(requestMultipartEncoding({...input,resources,parts:[{name:'raw',kind:'other'}]}),error=>error.code==='request.multipart.encoding.unsupported'&&error.range[1]>error.range[0]);
});

test('file array unions cannot silently select scalar annotations or item annotations',async()=>{
 const input=mutate(packet('3.2.1'),media=>{
  media.schema={type:'object',properties:{file:{type:['string','array'],contentEncoding:'base64',items:{type:'string',contentEncoding:'base16'}}}};
  delete media.encoding;
 });
 await assert.rejects(requestMultipartEncoding({...input,parts:[],files:['file']}),error=>error.code==='request.multipart.encoding.unsupported'&&error.kind==='unsupported'&&error.source.resource===input.root&&error.range[1]>error.range[0]);
});
