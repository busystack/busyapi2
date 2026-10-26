const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const bytes=Buffer.from([0,255,128]);

async function check(version,format,schema,contentType='application/octet-stream',body=bytes){
 const root='file:///binary-selection/api.'+format;
 const value={openapi:version,info:{title:'Original',version:'api-version'},paths:{'/file':{post:{requestBody:{content:{[contentType]:{schema}}},responses:{204:{description:'Empty'}}}}}};
 const text=format==='json'?JSON.stringify(value):'# Keep 雪 and CRLF\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
 return evaluateSchemas({root,snapshot:version+format,resources:[{id:root,generation:1,text}],runtimeInstances:[{subject:'request-body',location:contentType,mediaType:contentType,mediaBase64:true,text:body.toString('base64'),schema:{resource:root,pointer:'/paths/~1file/post/requestBody/content/'+contentType.replaceAll('~','~0').replaceAll('/','~1')+'/schema'}}]});
}
function result(value,valid){
 assert.equal(value.complete,true,JSON.stringify(value.runtimeFindings));
 assert.equal(value.runtimeEvaluations.every(item=>item.complete===true&&item.valid===true),valid,JSON.stringify(value.runtimeFindings));
}
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])test(`${version} ${format} binary media chooses its legacy octet model without requiring redundant type and format`,async()=>{
 for(const schema of [{},{format:'binary'},{type:'string'},{type:'string',minLength:3,maxLength:3},{enum:['\u0000ÿ\u0080']},{allOf:[{minLength:3},{maxLength:3}]}])result(await check(version,format,schema),true);
 for(const schema of [{type:'integer'},{enum:[null]},{type:'string',minLength:4},{type:'string',maxLength:2},{not:{type:'string'}}])result(await check(version,format,schema),false);
 result(await check(version,format,{},'application/octet-stream',Buffer.alloc(0)),true);
 const unknown=await check(version,format,{},'application/xml');
 assert.equal(unknown.complete,false);assert(unknown.runtimeFindings.some(value=>value.kind==='unsupported'));
});
for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} binary media retains the modern non-JSON model`,async()=>{
 result(await check(version,format,{}),true);
 result(await check(version,format,{type:'string',format:'binary'}),false);
 result(await check(version,format,{type:'null'}),false);
 result(await check(version,format,{not:{type:'null'}}),true);
});
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])test(`${version} ${format} named binary parts use their legacy media model with optional schema hints`,async()=>{
 for(const type of ['multipart/form-data','multipart/mixed'])for(const field of [{},{format:'binary'},{type:'string'},{type:'string',minLength:4}]){
  const root='file:///binary-selection/form.'+format,at='/paths/~1file/post/requestBody/content/'+type.replace('/','~1');
  const media={schema:{type:'object',required:['file'],properties:{file:field}},encoding:{file:{contentType:'application/octet-stream'}}};
  const value={openapi:version,info:{title:'Original',version:'api-version'},paths:{'/file':{post:{requestBody:{content:{[type]:media}},responses:{204:{description:'Empty'}}}}}};
  const text=format==='json'?JSON.stringify(value):'# Keep source\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
  const body=Buffer.concat([Buffer.from('--Fixture\r\nContent-Disposition: form-data; name="file"\r\nContent-Type: application/octet-stream\r\n\r\n'),bytes,Buffer.from('\r\n--Fixture--\r\n')]);
  result(await evaluateSchemas({root,snapshot:version+format+type,resources:[{id:root,text,generation:1}],runtimeInstances:[{subject:'request-body',location:type,mediaType:type+'; boundary=Fixture',mediaBase64:true,text:body.toString('base64'),form:{resource:root,pointer:at},schema:{resource:root,pointer:at+'/schema'}}]}),field.minLength===undefined);
 }
});
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} schema-free media retains its captured family's byte model`,async()=>{
 const root='file:///binary-selection/empty.'+format,at='/paths/~1file/post/requestBody/content/application~1octet-stream';
 const value={openapi:version,info:{title:'Original',version:'3.2.1'},paths:{'/file':{post:{requestBody:{content:{'application/octet-stream':{}}},responses:{204:{description:'Empty'}}}}}};
 const text=format==='json'?JSON.stringify(value):'# Keep source\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
 const input={root,snapshot:version+format,resources:[{id:root,text,generation:1}],runtimeInstances:[{subject:'request-body',location:'application/octet-stream',mediaType:'application/octet-stream',mediaBase64:true,text:bytes.toString('base64'),media:{resource:root,pointer:at}}]};
 const evaluated=await evaluateSchemas(input);result(evaluated,true);
 assert.equal(evaluated.runtimeEvaluations[0].syntax,version.startsWith('3.0.')?'octets':'binary');
});

for(const format of ['yaml','json'])test(`${format} media ownership follows captured references and version switches without stale semantics`,async()=>{
 const root='file:///binary-selection/switch.'+format,part='file:///binary-selection/shared.'+format,at='/paths/~1file/post/requestBody/content/application~1octet-stream';
 const encode=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);
 for(const version of ['3.0.4','3.1.2','3.2.1','3.0.0','3.2.0','3.1.0']){
  const value={openapi:version,info:{title:'Switch',version:'2.0'},paths:{'/file':{post:{requestBody:{$ref:'shared.'+format+'#/Body'},responses:{204:{description:'Empty'}}}}}};
  const fragment={Body:{content:{'application/octet-stream':{schema:{type:'string'}}}},Literal:{$ref:'missing-example.json'}};
  const resources=[{id:root,text:encode(value),generation:1},{id:part,text:encode(fragment),generation:2}],original=JSON.stringify(resources);
  const instance={subject:'request-body',location:'application/octet-stream',mediaType:'application/octet-stream',mediaBase64:true,text:bytes.toString('base64'),media:{resource:part,pointer:'/Body/content/application~1octet-stream'}};
  result(await evaluateSchemas({root,snapshot:'same-switch-identity',resources,runtimeInstances:[instance]}),version.startsWith('3.0.'));
  const forged=await evaluateSchemas({root,snapshot:'same-switch-identity',resources,runtimeInstances:[{...instance,schema:{resource:part,pointer:'/Literal'}}]});
  assert.equal(forged.complete,false);assert(forged.runtimeFindings.some(finding=>finding.detailCode==='runtime.media.owner'&&finding.source.resource===part));
  assert.equal(JSON.stringify(resources),original);
 }
});

for(const format of ['yaml','json'])test(`${format} a missing media owner cannot borrow the root family or example payload`,async()=>{
 const root='file:///binary-selection/invalid.'+format;
 const value={openapi:'3.2.1',info:{title:'No fallback',version:'3.0.4'},paths:{},components:{examples:{Payload:{value:{content:{'application/octet-stream':{}}}}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value);
 for(const pointer of ['/missing','/components/examples/Payload/value/content/application~1octet-stream']){
  const value=await evaluateSchemas({root,snapshot:'missing-owner',resources:[{id:root,text,generation:1}],runtimeInstances:[{subject:'response-body',location:'body',mediaType:'application/octet-stream',mediaBase64:true,text:bytes.toString('base64'),media:{resource:root,pointer}}]});
  assert.equal(value.complete,false);assert(value.runtimeEvaluations.every(item=>item.complete===false&&item.valid===false));
  assert(value.runtimeFindings.some(finding=>finding.kind==='unsupported'&&finding.detailCode==='runtime.media.owner'&&finding.source.pointer===pointer));
 }
});

for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} response part headers and request Encoding restrictions have separate ownership`,async()=>{
 const root='file:///binary-selection/response.'+format,type='multipart/form-data',at='/paths/~1file/post';
 const field=version.startsWith('3.0.')?{type:'string',minLength:3,maxLength:3}:{not:{type:'null'}};
 const media={schema:{type:'object',properties:{file:field},required:['file']},encoding:{file:{contentType:'text/plain'}}};
 const value={openapi:version,info:{title:'Explicit part media',version:'api-version'},paths:{'/file':{post:{requestBody:{content:{[type]:media}},responses:{200:{description:'Actual parts',content:{[type]:media}}}}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),input={root,snapshot:version+format,resources:[{id:root,text,generation:1}]};
 const body=Buffer.concat([Buffer.from('--Fixture\r\nContent-Disposition: form-data; name="file"\r\nContent-Type: application/octet-stream\r\n\r\n'),bytes,Buffer.from('\r\n--Fixture--\r\n')]);
 for(const [subject,pointer,valid]of [['request-body',at+'/requestBody',false],['response-body',at+'/responses/200',!version.startsWith('3.2.')]]){
  const checked=await evaluateSchemas({...input,runtimeInstances:[{subject,location:type,mediaType:type+'; boundary=Fixture',mediaBase64:true,text:body.toString('base64'),form:{resource:root,pointer:pointer+'/content/multipart~1form-data'}}]});
  result(checked,valid);
 }
});
