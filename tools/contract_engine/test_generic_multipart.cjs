const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {requestOperation,requestFormMediaTypes,requestMultipartEncoding}=require('./dist/execution.cjs');
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2'];
function capture(version,format,options={}){
 const root='file:///named/api.'+format,at='/paths/~1parts/post/requestBody/content/multipart~1mixed';
 const media={
  schema:{type:'object',required:['flag','metadata'],properties:{
   flag:options.flagSchema??{type:'boolean',enum:[false]},
   metadata:{type:'object',required:['id'],properties:{id:{type:'integer',enum:['EXACT']}}},
  }},
  encoding:{
   flag:{contentType:'text/plain',headers:{'X-Tag':options.header??{required:true,schema:{type:'string',enum:['retained']}}}},
   metadata:options.metadataEncoding??{contentType:'application/json'},
  },
 };
 const value={openapi:version,info:{title:'Named MIME',version:'original'},paths:{'/parts':{post:{requestBody:{required:true,content:{'multipart/mixed':media}},responses:{204:{description:'Empty'}}}}}};
 const text=(format==='yaml'?'# Preserve comments 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)).replaceAll(format==='yaml'?'EXACT':'"EXACT"','9007199254740993.00');
 return {root,snapshot:version+format,resources:[{id:root,text,generation:1}],resource:root,pointer:'/paths/~1parts/post',at};
}
function wire(flag='false',tag='retained',number='9007199254740993.00'){
 return '--Fixture\r\nContent-Disposition: form-data; name="flag"\r\nContent-Type: text/plain\r\nX-Tag: '+tag+'\r\n\r\n'+flag+'\r\n--Fixture\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n{"id":'+number+'}\r\n--Fixture--\r\n';
}
async function evaluate(input,text){
 const {at,...capture}=input;
 return evaluateSchemas({...capture,runtimeInstances:[{subject:'request-body',location:'multipart/mixed',text:Buffer.from(text).toString('base64'),mediaBase64:true,mediaType:'multipart/mixed; boundary=Fixture',form:{resource:input.root,pointer:at},schema:{resource:input.root,pointer:at+'/schema'}}]});
}
for(const version of versions)for(const format of ['yaml','json']){
 test(`${version} ${format} generic named MIME keeps original schema and header checks`,async()=>{
  const input=capture(version,format),original=input.resources[0].text;
  const result=await evaluate(input,wire());
  assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));
  assert.equal(result.runtimeEvaluations.every(value=>value.valid===true),true,JSON.stringify(result.runtimeFindings));
  for(const body of [wire('true'),wire('false','wrong'),wire('false','retained','9007199254740992'),wire().replace('X-Tag: retained\r\n','')]){
   const bad=await evaluate(input,body);assert.equal(bad.complete,true,JSON.stringify(bad.runtimeFindings));
   assert.equal(bad.runtimeEvaluations.every(value=>value.valid===true),false,JSON.stringify(bad.runtimeFindings));
  }
  assert.equal(input.resources[0].text,original);
 });
 test(`${version} ${format} generic named MIME projects the existing typed form binding`,async()=>{
  const input=capture(version,format),plan=requestOperation(input),media=plan.requestBody.content[0];
  assert.equal(media.formBinding,'multipart-named');assert.equal(media.form.legacyBinary,version.startsWith('3.0.'));
  assert.equal(media.form.multipartStyle,!version.startsWith('3.0.'));
  for(const mediaType of ['multipart/mixed','multipart/mixed; charset=UTF-8']){
   const selected=requestFormMediaTypes({...input,mediaType,parts:['flag','metadata'],files:[],choices:{}});
   assert.equal(selected.types.flag,'text/plain');assert.equal(selected.types.metadata,'application/json');
   const transfer=await requestMultipartEncoding({...input,mediaType,parts:[{name:'metadata',kind:'other'}],files:[]});
   assert.equal(transfer.parts.metadata.other.schemaEncoded,false);
  }
 });
}
test('older families do not infer an unnamed positional multipart mapping',async()=>{
 for(const version of ['3.0.4','3.1.2']){
  const result=await evaluate(capture(version,'json'),wire().replaceAll('Content-Disposition: form-data; name="flag"\r\n',''));
  assert.equal(result.complete,false);assert(result.runtimeFindings.some(value=>value.detailCode==='runtime.form.unnamed.unsupported'));
 }
});

for(const version of ['3.0.4','3.1.2'])for(const format of ['yaml','json']){
 test(`${version} ${format} generic MIME defaults text to ASCII while form-data retains UTF-8`,async()=>{
  const input=capture(version,format,{flagSchema:{type:'string',enum:['café']}});
  const body=wire('café');
  const explicit=await evaluate(input,body.replace('Content-Type: text/plain\r\n','Content-Type: text/plain; charset=utf-8\r\n'));
  assert.equal(explicit.complete,true,JSON.stringify(explicit.runtimeFindings));assert(explicit.runtimeEvaluations.every(value=>value.valid));
  const missing=await evaluate(input,body);assert.equal(missing.complete,true);assert(missing.runtimeEvaluations.some(value=>!value.valid));
  assert(missing.runtimeFindings.some(value=>value.detailCode==='runtime.media.charset'));
  const form={...input,at:input.at.replace('multipart~1mixed','multipart~1form-data'),resources:input.resources.map(resource=>({...resource,text:resource.text.replaceAll('multipart/mixed','multipart/form-data')}))};
  const result=await evaluateSchemas({...form,runtimeInstances:[{subject:'request-body',location:'multipart/form-data',text:Buffer.from(body).toString('base64'),mediaBase64:true,mediaType:'multipart/form-data; boundary=Fixture',form:{resource:form.root,pointer:form.at},schema:{resource:form.root,pointer:form.at+'/schema'}}]});
  assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert(result.runtimeEvaluations.every(value=>value.valid),JSON.stringify(result.runtimeFindings));
 });
 test(`${version} ${format} generic MIME header references retain exact numbers and their schema owner`,async()=>{
  const input=capture(version,format,{header:{$ref:'headers.yaml#/Count'}});
  input.resources.push({id:'file:///named/headers.yaml',generation:2,text:'# Keep original header\r\nCount: &count\r\n  required: true\r\n  schema: {type: integer, enum: [9007199254740993.00]}\r\nMirror: *count\r\n'});
  const positive=await evaluate(input,wire('false','9007199254740993.00'));
  assert.equal(positive.complete,true,JSON.stringify(positive.runtimeFindings));assert(positive.runtimeEvaluations.every(value=>value.valid));
  const rounded=await evaluate(input,wire('false','9007199254740992'));
  assert.equal(rounded.complete,true);assert(rounded.runtimeEvaluations.some(value=>!value.valid));
  assert(rounded.runtimeFindings.some(value=>value.schema?.resource==='file:///named/headers.yaml'&&value.schema.pointer==='/Count/schema'));
 });
 test(`${version} ${format} named generic multipart keeps its family-specific style policy`,async()=>{
  const input=capture(version,format,{metadataEncoding:{style:'form',explode:false,contentType:'application/json'}});
  const plan=requestOperation(input),metadata=plan.requestBody.content[0].form.parts.metadata;
  assert.equal(metadata.styled,version.startsWith('3.1.'));
  const body=version.startsWith('3.0.')?wire():wire().replace('Content-Type: application/json','Content-Type: text/plain').replace('{"id":9007199254740993.00}','id,9007199254740993.00');
  const result=await evaluate(input,body);assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert(result.runtimeEvaluations.every(value=>value.valid),JSON.stringify(result.runtimeFindings));
 });
}
