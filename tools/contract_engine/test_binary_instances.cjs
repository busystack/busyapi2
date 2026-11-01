const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const versions=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const binary=Buffer.from([0,255,128]);
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
function capture(version,format,schema,type='application/octet-stream',extra={}){
 const root='file:///binary/api.'+format,at='/paths/~1parts/post/requestBody/content/'+escape(type);
 const media={schema,...extra},value={openapi:version,info:{title:'Binary instances',version:'original'},paths:{'/parts':{post:{requestBody:{content:{[type]:media}},responses:{200:{description:'Echo',content:{[type]:media}}}}}}};
 const text=(format==='json'?JSON.stringify(value):'# Keep exact source 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 return {root,snapshot:version+format,resources:[{id:root,text,generation:1}],at,type,hasItemSchema:Object.hasOwn(extra,'itemSchema')};
}
async function run(input,bytes=binary,subject='request-body'){
 const {at,type,hasItemSchema,...source}=input;
 const pointer=subject==='response-body'?at.replace('/requestBody/','/responses/200/'):at;
 return evaluateSchemas({...source,runtimeInstances:[{subject,location:type,text:bytes.toString('base64'),mediaType:type.startsWith('multipart/')?type+'; boundary=Fixture':type,mediaBase64:true,
  ...(type.startsWith('multipart/')?{form:{resource:source.root,pointer}}:{}),schema:{resource:source.root,pointer:pointer+'/schema'},
  ...(hasItemSchema?{itemSchema:{resource:source.root,pointer:pointer+'/itemSchema'}}:{}),
 }]});
}
function assertResult(result,valid){
 assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));
 assert(result.runtimeEvaluations.length>0);
 assert.equal(result.runtimeEvaluations.every(value=>value.complete===true&&value.valid===true),valid,JSON.stringify(result.runtimeFindings));
}
function wire(parts,boundary='Fixture'){
 const chunks=[];
 for(const part of parts){chunks.push(Buffer.from('--'+boundary+'\r\nContent-Type: '+(part.type??'application/octet-stream')+'\r\n\r\n'),Buffer.isBuffer(part.body)?part.body:Buffer.from(part.body),'\r\n');}
 chunks.push('--'+boundary+'--\r\n');return Buffer.concat(chunks.map(value=>Buffer.isBuffer(value)?value:Buffer.from(value)));
}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} raw binary stays outside all six JSON types`,async()=>{
 const original=capture(version,format,{}),before=original.resources[0].text;
 for(const subject of ['request-body','response-body']){
  assertResult(await run(original,binary,subject),true);
  assertResult(await run(capture(version,format,true),binary,subject),true);
  for(const schema of [false,{type:'null'},{type:'string',format:'binary'},{type:['null','string','number','boolean','object','array']},{const:null},{enum:[null,false,0,'',{},[]]}])assertResult(await run(capture(version,format,schema),binary,subject),false);
  for(const schema of [{not:{type:'null'}},{oneOf:[{type:'string'},{}]},{if:{type:'null'},then:false,else:true},{minLength:100,minimum:100,required:['absent'],minItems:10}])assertResult(await run(capture(version,format,schema),binary,subject),true);
 }
 assert.equal(original.resources[0].text,before);
});
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])test(`${version} ${format} legacy binary retains its original octet string`,async()=>{
 assertResult(await run(capture(version,format,{type:'string',format:'binary',minLength:3,maxLength:3})),true);
 assertResult(await run(capture(version,format,{type:'string',format:'binary',maxLength:2})),false);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} mixed binary MIME preserves whole-schema conditionals and exact JSON`,async()=>{
 const schema={type:'array',minItems:2,maxItems:2,prefixItems:[{if:{type:'null'},then:false,else:{not:{type:'string'}}},{type:'object',required:['id'],properties:{id:{type:'integer',enum:['EXACT']}}}],items:false};
 const input=capture(version,format,schema,'multipart/mixed',{prefixEncoding:[{contentType:'application/octet-stream'},{contentType:'application/json'}]});
 const body=wire([{body:binary},{type:'application/json',body:'{"id":9007199254740993.00}'}]);
 assertResult(await run(input,body),true);
 assertResult(await run(input,wire([{body:binary},{type:'application/json',body:'{"id":9007199254740992}'}])),false);
 for(const first of [false,{type:'null'},{const:null}])assertResult(await run(capture(version,format,{...schema,prefixItems:[first,schema.prefixItems[1]]},'multipart/mixed', {prefixEncoding:[{contentType:'application/octet-stream'},{contentType:'application/json'}]}),body),false);
});
for(const version of ['3.2.0','3.2.1'])test(`${version} binary equality differs from null and compares octets`,async()=>{
 const input=capture(version,'json',{type:'array',minItems:2,uniqueItems:true},'multipart/mixed',{itemEncoding:{contentType:'application/octet-stream'}});
 assertResult(await run(input,wire([{body:binary},{body:binary}])),false);
 assertResult(await run(input,wire([{body:binary},{body:Buffer.from([0,255,129])} ])),true);
 const mixed=capture(version,'json',{type:'array',prefixItems:[{}, {type:'null'}],items:false,uniqueItems:true,contains:{not:{type:['null','string','number','boolean','object','array']}},minContains:1,maxContains:1},'multipart/mixed',{prefixEncoding:[{contentType:'application/octet-stream'},{contentType:'application/json'}]});
 assertResult(await run(mixed,wire([{body:binary},{type:'application/json',body:'null'}])),true);
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} named multipart includes distinct binary leaves`,async()=>{
 const input=capture(version,format,{type:'object',required:['file','id'],properties:{file:{not:{type:'null'}},id:{type:'integer',enum:['EXACT']}}},'multipart/form-data',{encoding:{file:{contentType:'application/octet-stream'},id:{contentType:'text/plain'}}});
 const body=Buffer.concat([Buffer.from('--Fixture\r\nContent-Disposition: form-data; name="file"\r\nContent-Type: application/octet-stream\r\n\r\n'),binary,Buffer.from('\r\n--Fixture\r\nContent-Disposition: form-data; name="id"\r\nContent-Type: text/plain\r\n\r\n9007199254740993.00\r\n--Fixture--\r\n')]);
 assertResult(await run(input,body),true);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} nested binary ownership reaches whole and item schemas`,async()=>{
 const bytes=wire([{type:'multipart/mixed; boundary=Inner',body:wire([{body:binary},{body:Buffer.alloc(0)}],'Inner')}]);
 const item={type:'array',prefixItems:[{not:{type:'null'}},{not:{type:'null'}}],minItems:2,maxItems:2,uniqueItems:true};
 const extra={itemEncoding:{contentType:'multipart/mixed',itemEncoding:{contentType:'application/octet-stream'}},itemSchema:item};
 assertResult(await run(capture(version,format,{type:'array',items:item},'multipart/mixed',extra),bytes),true);
 assertResult(await run(capture(version,format,{type:'array'},'multipart/mixed',{...extra,itemSchema:{type:'array',items:{const:null}}}),bytes),false);
});
for(const version of versions)test(`${version} binary media classification preserves JSON and unsupported codecs`,async()=>{
 for(const type of ['application/octet-stream','image/png','audio/ogg','video/mp4','font/woff2','application/pdf']){
  assertResult(await run(capture(version,'json',{not:{type:'null'}},type)),true);
  assertResult(await run(capture(version,'json',{not:{type:'null'}},type),Buffer.alloc(0)),true);
 }
 for(const type of ['application/xml','image/svg+xml','application/busy-unknown']){
  const result=await run(capture(version,'json',{},type),Buffer.from('<value/>'));
  assert.equal(result.complete,false);assert(result.runtimeFindings.some(value=>value.kind==='unsupported'));
 }
 assertResult(await run(capture(version,'json',{type:'null'},'application/problem+json'),Buffer.from('null')),true);
});
for(const version of versions)test(`${version} binary never falls back from an explicit unsupported dialect`,async()=>{
 const result=await run(capture(version,'yaml',{$schema:'https://example.invalid/unsupported-dialect'}));
 assert.equal(result.complete,false);assert(result.runtimeEvaluations.every(value=>value.complete===false));
});
for(const version of versions)test(`${version} canonical external schema references retain binary and exact value semantics`,async()=>{
 const input=capture(version,'json',{$ref:'./model.json#/$defs/Binary'});
 input.resources.push({id:'file:///binary/model.json',generation:3,text:JSON.stringify({$schema:'https://json-schema.org/draft/2020-12/schema',$id:'file:///binary/model.json',$defs:{Binary:{allOf:[{not:{type:'null'}},{if:{type:'string'},then:false,else:true}]}}})});
 assertResult(await run(input),true);
 input.resources[1].text=input.resources[1].text.replace('"not":{"type":"null"}','"type":"null"');input.resources[1].generation++;
 assertResult(await run(input),false);
});
for(const version of versions)test(`${version} raw binary follows dynamic resource scope without converting to null`,async()=>{
 const input=capture(version,'json',{$dynamicRef:'./model.json#node'});
 input.resources.push({id:'file:///binary/model.json',generation:1,text:JSON.stringify({$schema:'https://json-schema.org/draft/2020-12/schema',$id:'file:///binary/model.json',$dynamicAnchor:'node',not:{type:'null'}})});
 assertResult(await run(input),true);
 input.resources[1].text=input.resources[1].text.replace('"not":{"type":"null"}','"type":"null"');input.resources[1].generation++;
 assertResult(await run(input),false);
});
