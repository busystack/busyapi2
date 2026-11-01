const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const engine=process.env.BUSYAPI_HEADER_GENERATION_BASELINE||__dirname;
const YAML=require(path.join(engine,'node_modules/yaml'));
const {requestMultipartEncoding}=require(path.join(engine,'dist/execution.cjs'));
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const meta='{"id":9007199254740993.00,"flag":false,"empty":""}';
function fixture(version,format,transfer=false){
 const root='file:///generated-headers/api.'+format,mediaType=transfer?'multipart/form-data':'multipart/mixed';
 const header=transfer?{content:{'text/plain':{schema:{type:'string',enum:['base64']}}}}:{required:true,content:{'application/json':{schema:{type:'object',required:['id','flag','empty'],properties:{id:{type:'integer',enum:['EXACT']},flag:{type:'boolean',enum:[false]},empty:{type:'string',maxLength:0}}}}}};
 const name=transfer?'Content-Transfer-Encoding':'X-Meta';
 const value={openapi:version,info:{title:'Keep 雪',version:'unrelated'},paths:{'/parts':{post:{requestBody:{content:{[mediaType]:{schema:{type:'object',properties:{value:{type:'string'}}},encoding:{value:{contentType:'text/plain',headers:{[name]:{$ref:'headers.yaml#/Alias'}}}}}}},responses:{204:{description:'Empty'}}}}}};
 const text=(format==='json'?JSON.stringify(value):'# Keep exact source\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'));
 const shared=('# Keep shared alias\r\n'+YAML.stringify({Actual:header,Alias:header}).replaceAll('\n','\r\n')).replaceAll('EXACT','9007199254740993.00');
 return {root,resource:root,pointer:'/paths/~1parts/post',snapshot:version+format,mediaType,resources:[{id:root,text,generation:2},{id:'file:///generated-headers/headers.yaml',text:shared,generation:3}],parts:[{name:'value',kind:'string'}],files:[],headers:transfer?{}:{value:[{name,value:meta}]}};
}
for(const version of versions.filter(version=>!version.startsWith('3.2.')))for(const format of ['yaml','json'])test(`${version} ${format} generated generic MIME headers retain explicit exact wire values`,async()=>{
 const input=fixture(version,format),before=JSON.stringify(input.resources),result=await requestMultipartEncoding(input);
 assert.equal(result.identity.length,64);assert.equal(result.snapshot,input.snapshot);
 assert.deepEqual(result.parts.value.headers.map(({name,value})=>({name,value})),[{name:'X-Meta',value:meta}]);
 assert.deepEqual(result.parts.value.string,{schemaEncoded:false});assert.equal(JSON.stringify(input.resources),before);
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} captured transfer Header content selects an implemented valid token`,async()=>{
 const input=fixture(version,format,true),before=JSON.stringify(input.resources),result=await requestMultipartEncoding(input);
 assert.equal(result.parts.value.string.encoding,'base64');assert.equal(result.parts.value.string.schemaEncoded,false);
 assert.equal(result.parts.value.string.source.resource,input.root);assert.match(result.parts.value.string.source.pointer,/\/headers\/Content-Transfer-Encoding$/);
 assert.equal(JSON.stringify(input.resources),before);
});
for(const version of ['3.0.4','3.1.2'])for(const format of ['yaml','json'])test(`${version} ${format} malformed or stale MIME inputs cannot produce header lines`,async()=>{
 const input=fixture(version,format);
 for(const [fields,code]of [
  [[{name:'Bad Name',value:'x'}],'request.multipart.header.syntax'],
  [[{name:'X-Meta',value:'x\r\nInjected: yes'}],'request.multipart.header.syntax'],
  [[{name:'X-Meta',value:'\0'}],'request.multipart.header.syntax'],
  [[{name:'X-Meta',value:'café'}],'request.multipart.header.syntax'],
  [[{name:'Content-Type',value:'text/plain'}],'request.multipart.header.controlled'],
  [[{name:'Content-Disposition',value:'override'}],'request.multipart.header.controlled'],
  [[{name:'Content-Transfer-Encoding',value:'base64'}],'request.multipart.header.controlled'],
  [[{name:'X-Meta',value:'x'.repeat(8193)}],'limit.request.multipart.headers'],
  [Array.from({length:62},()=>({name:'X-Field',value:'x'})),'request.multipart.headers'],
 ])await assert.rejects(requestMultipartEncoding({...input,headers:{value:fields}}),error=>error.code===code);
 await assert.rejects(requestMultipartEncoding({...input,headers:{removed:[]}}),error=>error.code==='request.multipart.header.stale');
 const empty=await requestMultipartEncoding({...input,headers:{value:[{name:'X-Empty',value:''},{name:'X-Empty',value:'0'}]}});
 assert.deepEqual(empty.parts.value.headers.map(({name,value})=>({name,value})),[{name:'X-Empty',value:''},{name:'X-Empty',value:'0'}]);
 const before=JSON.stringify(input.resources);await requestMultipartEncoding(input);assert.equal(JSON.stringify(input.resources),before);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} form-data cannot transmit an additional ignored MIME header`,async()=>{
 await assert.rejects(requestMultipartEncoding({...fixture(version,'yaml',true),headers:{value:[{name:'X-Extra',value:'x'}]}}),error=>error.code==='request.multipart.header.forbidden');
});

for(const version of ['3.1.2','3.2.1'])test(`${version} MIME base64 model strings retain non-folding spelling on actual entity evaluation`,async()=>{
 const {evaluateSchemas}=require(path.join(engine,'dist/schema_evaluation.cjs'));
 for(const [wire,model]of [['Zg== ','Zg== '],['Zg==\t','Zg==\t'],['Zg==!','Zg==!'],['Zg==\r\n','Zg==']]){
  const input=fixture(version,'json',true),value=JSON.parse(input.resources[0].text);
  const at='/paths/~1parts/post/requestBody/content/multipart~1form-data';
  value.paths['/parts'].post.requestBody.content[input.mediaType].schema.properties.value={type:'string',contentEncoding:'base64',enum:[model]};
  input.resources[0].text=JSON.stringify(value);
  const text='--Fixture\r\nContent-Disposition: form-data; name="value"\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n'+wire+'\r\n--Fixture--\r\n';
  const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'request-body',location:input.mediaType,text:Buffer.from(text).toString('base64'),mediaType:input.mediaType+'; boundary=Fixture',mediaBase64:true,form:{resource:input.root,pointer:at},schema:{resource:input.root,pointer:at+'/schema'}}]});
  assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert.equal(result.runtimeEvaluations.every(value=>value.valid===true),true,JSON.stringify(result.runtimeFindings));
 }
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} actual form-data token Header content uses captured media semantics`,async()=>{
 const {evaluateSchemas}=require(path.join(engine,'dist/schema_evaluation.cjs'));
 const input=fixture(version,format,true),value=YAML.parse(input.resources[0].text),at='/paths/~1parts/post/requestBody/content/multipart~1form-data';
 value.paths['/parts'].post.requestBody.content[input.mediaType].schema.properties.value={type:'string',enum:['f']};
 input.resources[0].text=format==='yaml'?YAML.stringify(value):JSON.stringify(value);
 const original=JSON.stringify(input.resources);
 for(const [token,valid]of [['base64',true],['binary',false]]){
  const text='--Fixture\r\nContent-Disposition: form-data; name="value"\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: '+token+'\r\n\r\nZg==\r\n--Fixture--\r\n';
  const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'request-body',location:input.mediaType,text:Buffer.from(text).toString('base64'),mediaType:input.mediaType+'; boundary=Fixture',mediaBase64:true,form:{resource:input.root,pointer:at},schema:{resource:input.root,pointer:at+'/schema'}}]});
  assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert.equal(result.runtimeEvaluations.every(value=>value.valid===true),valid,JSON.stringify(result.runtimeFindings));
  if(!valid)assert(result.runtimeFindings.some(value=>value.schema?.resource===input.resources[1].id));
 }
 assert.equal(JSON.stringify(input.resources),original);
});
