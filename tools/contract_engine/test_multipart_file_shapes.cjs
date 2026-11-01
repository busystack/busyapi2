const assert=require('node:assert/strict');
const {test}=require('node:test');
const path=require('node:path');
const engine=process.env.BUSYAPI_FILE_SHAPE_BASELINE||__dirname;
const YAML=require(path.join(engine,'node_modules/yaml'));
const {requestMultipartEncoding,requestFormMediaTypes,requestOperation}=require(path.join(engine,'dist/execution.cjs'));
const {evaluateSchemas}=require(path.join(engine,'dist/schema_evaluation.cjs'));

function packet(version,format,shape){
 const root='file:///approved/api.'+format,shared='file:///approved/model.yaml';
 const scalar=version.startsWith('3.0.')?{type:'string',format:'binary'}:{type:'string'};
 const property=version.startsWith('3.0.')?{oneOf:[scalar,{type:'array',items:scalar}]}:{type:['array','string'],items:{type:'string'}};
 const value={openapi:version,info:{title:'Keep 雪',version:'unrelated'},paths:{'/files':{post:{requestBody:{content:{'multipart/form-data':{
  schema:{type:'object',properties:{asset:{$ref:'./model.yaml#/File'}}},encoding:{asset:{contentType:version.startsWith('3.0.')?'application/octet-stream':'text/plain'}}
 }}},responses:{204:{description:'No body'}}}}}};
 return {root,resource:root,pointer:'/paths/~1files/post',snapshot:'file-shape-'+version+'-'+format,mediaType:'multipart/form-data',
  resources:[{id:root,text:format==='json'?JSON.stringify(value):'# Keep comments\r\n'+YAML.stringify(value).replace(/\n/g,'\r\n'),generation:1},{id:shared,text:YAML.stringify({File:property}),generation:2}],
  parts:[],files:['asset'],fileShapes:{asset:shape}};
}

for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2'])for(const format of ['yaml','json'])for(const shape of ['single','array']){
 test(`${version} ${format} explicit ${shape} file values retain native schema ownership`,async()=>{
  const input=packet(version,format,shape),before=input.resources.map(value=>value.text);
  const result=await requestMultipartEncoding(input);
  assert.equal(result.snapshot,input.snapshot);
  assert.equal(result.parts.asset.fileArray,shape==='array');
  assert.equal(result.parts.asset.string.schemaEncoded,false);
  if(version.startsWith('3.0.')){
   assert.equal(result.parts.asset.string.instanceEncoding,'octets');
   assert.equal(result.parts.asset.string.instanceSource.resource,'file:///approved/model.yaml');
   assert.equal(result.parts.asset.string.instanceSource.pointer,shape==='array'?'/File/oneOf/1/items/format':'/File/oneOf/0/format');
  }
  const plan=requestOperation(input);
  assert.deepEqual(plan.requestBody.content[0].form.parts.asset.fileShapes,['single','array']);
  assert.deepEqual(input.resources.map(value=>value.text),before);
 });
}

test('file shape choices reject stale names and unknown modes without source edits',async()=>{
 for(const choices of [{missing:'array'},{asset:'tuple'},{asset:false}]){
  const input=packet('3.0.4','yaml','single');input.fileShapes=choices;const before=input.resources.map(value=>value.text);
  await assert.rejects(()=>requestMultipartEncoding(input),error=>error.code==='request.multipart.file-shape');
  assert.deepEqual(input.resources.map(value=>value.text),before);
 }
});

test('a shape choice does not resolve competing string representations',async()=>{
 const input=packet('3.0.4','json','single');
 input.resources[1].text=YAML.stringify({File:{oneOf:[{type:'string',format:'binary'},{type:'string',format:'byte'}]}});
 await assert.rejects(()=>requestMultipartEncoding(input),error=>error.kind==='unsupported');
});

for(const version of ['3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} identical captured MIME bytes retain the selected data shape`,async()=>{
 const input=packet(version,format,'array'),legacy=version.startsWith('3.0.');
 const scalar={type:'string',...(legacy?{format:'binary'}:{}),minLength:3};
 input.resources[1].text=YAML.stringify({File:{oneOf:[{...scalar,minLength:4},{type:'array',minItems:1,maxItems:1,items:scalar}]}});
 const pointer='/paths/~1files/post/requestBody/content/multipart~1form-data';
 const body='--Fixture\r\nContent-Disposition: form-data; name="asset"; filename="blob.bin"\r\nContent-Type: '+(legacy?'application/octet-stream':'text/plain')+'\r\n\r\nabc\r\n--Fixture--\r\n';
 const checked=await evaluateSchemas({...input,runtimeInstances:['single','array'].map(shape=>({subject:'request-body',location:shape,text:body,mediaType:'multipart/form-data; boundary=Fixture',schema:{resource:input.root,pointer:pointer+'/schema'},form:{resource:input.root,pointer,fileShapes:{asset:shape}}}))});
 assert.equal(checked.complete,true,JSON.stringify(checked.runtimeFindings));
 assert.deepEqual(checked.runtimeEvaluations.map(value=>value.valid),[false,true],JSON.stringify(checked.runtimeFindings));
 assert(input.resources[1].text.includes('minLength'));
});

test('single selections reject repeated file and mixed field inputs before capture',async()=>{
 for(const fields of [false,true]){
  const input=packet('3.0.4','yaml','single');
  if(fields)input.parts=[{name:'asset',kind:'string'}];else input.files.push('asset');
  await assert.rejects(()=>requestMultipartEncoding(input),error=>error.code==='request.multipart.file-shape');
 }
});

test('explicit null and array shape maps are protocol failures',async()=>{
 for(const choices of [null,[],{asset:null}]){
  const input=packet('3.0.4','json','single');input.fileShapes=choices;
  await assert.rejects(()=>requestMultipartEncoding(input),error=>error.code==='request.multipart.file-shape');
 }
});

for(const version of ['3.0.4','3.1.2'])test(`${version} chained escaped schema references retain the original shape and transfer locations`,async()=>{
 const input=packet(version,'yaml','array'),property=YAML.parse(input.resources[1].text).File;
 input.resources[1].text=YAML.stringify({File:{$ref:'./nested/model.json#/a~1b~0c'}});
 input.resources.push({id:'file:///approved/nested/model.json',text:JSON.stringify({'a/b~c':property}),generation:3});
 const result=await requestMultipartEncoding(input);
 assert.equal(result.parts.asset.fileArray,true);
 if(version.startsWith('3.0.')){
  assert.equal(result.parts.asset.string.instanceSource.resource,'file:///approved/nested/model.json');
  assert.equal(result.parts.asset.string.instanceSource.pointer,'/a~1b~0c/oneOf/1/items/format');
 }
});

test('modern styled multipart retains its separate representation boundary',async()=>{
 const input=packet('3.1.2','json','array'),document=JSON.parse(input.resources[0].text);
 document.paths['/files'].post.requestBody.content['multipart/form-data'].encoding.asset.style='form';
 input.resources[0].text=JSON.stringify(document);
 assert.equal(requestOperation(input).requestBody.content[0].form.parts.asset.fileShapes,undefined);
 await assert.rejects(()=>requestMultipartEncoding(input),error=>error.kind==='unsupported');
});

for(const version of ['3.2.0','3.2.1'])test(`${version} named multipart owns repeated file values and positional content stays separate`,async()=>{
 const input=packet(version,'json','array'),before=input.resources.map(resource=>resource.text),plan=requestOperation(input);
 assert.deepEqual(plan.requestBody.content[0].form.parts.asset.fileShapes,['single','array']);
 const encoded=await requestMultipartEncoding(input);assert.equal(encoded.parts.asset.fileArray,true);
 assert.deepEqual(input.resources.map(resource=>resource.text),before);
 const value=JSON.parse(input.resources[0].text),content=value.paths['/files'].post.requestBody.content;
 content['multipart/mixed']={schema:{type:'array',items:{type:'string'}}};delete content['multipart/form-data'];
 const positional={...input,mediaType:'multipart/mixed',resources:[{...input.resources[0],text:JSON.stringify(value)},...input.resources.slice(1)]};
 assert.equal(requestOperation(positional).requestBody.content[0].formBinding,undefined);
 await assert.rejects(()=>requestMultipartEncoding(positional),error=>error.code==='request.multipart.encoding');
});

for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2'])for(const format of ['yaml','json'])for(const shape of ['single','array'])test(`${version} ${format} selected ${shape} owns the default file media`,()=>{
 const input=packet(version,format,shape),root=format==='json'?JSON.parse(input.resources[0].text):YAML.parse(input.resources[0].text);
 delete root.paths['/files'].post.requestBody.content['multipart/form-data'].encoding;
 input.resources[0].text=format==='json'?JSON.stringify(root):YAML.stringify(root);
 const scalar={type:'string',...(version.startsWith('3.0.')?{format:'binary'}:{})};
 input.resources[1].text=YAML.stringify({File:{oneOf:[scalar,{type:'array',items:scalar}]}});
 const result=requestFormMediaTypes({...input,choices:{},files:[{name:'asset',fallback:'application/octet-stream'}]});
 assert.deepEqual(result.files,[version.startsWith('3.0.')?'application/octet-stream':'text/plain']);
});

for(const [items,expected]of [[{type:'object'},'application/json'],[{},'application/octet-stream'],[{type:'boolean'},'text/plain']])test(`selected array files retain ${expected} item defaults`,()=>{
 const input=packet('3.1.2','json','array'),root=JSON.parse(input.resources[0].text);
 delete root.paths['/files'].post.requestBody.content['multipart/form-data'].encoding;
 input.resources[0].text=JSON.stringify(root);input.resources[1].text=YAML.stringify({File:{type:'array',items}});
 const result=requestFormMediaTypes({...input,choices:{},files:[{name:'asset',fallback:'image/png'}]});
 assert.deepEqual(result.files,[expected]);
});

for(const items of [{type:['string','object']},{type:'array',items:{type:'string'}}])test('competing or nested default item media remain source-located limitations',()=>{
 const input=packet('3.1.2','json','array'),root=JSON.parse(input.resources[0].text);
 delete root.paths['/files'].post.requestBody.content['multipart/form-data'].encoding;
 input.resources[0].text=JSON.stringify(root);input.resources[1].text=YAML.stringify({File:{type:'array',items}});
 assert.throws(()=>requestFormMediaTypes({...input,choices:{},files:[{name:'asset',fallback:'text/plain'}]}),error=>error.code==='request.form.content-type.unsupported'&&error.kind==='unsupported'&&error.source.resource===input.root);
});

test('file media choices reject malformed and stale shape maps',()=>{
 for(const shapes of [null,[],{asset:null},{other:'array'},{asset:'tuple'}]){
  const input=packet('3.0.4','json','array');
  assert.throws(()=>requestFormMediaTypes({...input,fileShapes:shapes,choices:{},files:[{name:'asset',fallback:'text/plain'}]}),error=>error.code==='request.multipart.file-shape');
 }
});

for(const version of ['3.0.4','3.1.2'])for(const format of ['yaml','json'])test(`${version} ${format} original MIME evaluation shares selected default media`,async()=>{
 const input=packet(version,format,'array'),legacy=version.startsWith('3.0.'),root=format==='json'?JSON.parse(input.resources[0].text):YAML.parse(input.resources[0].text);
 delete root.paths['/files'].post.requestBody.content['multipart/form-data'].encoding;
 input.resources[0].text=format==='json'?JSON.stringify(root):YAML.stringify(root);
 const scalar={type:'string',...(legacy?{format:'binary'}:{}),minLength:3};
 input.resources[1].text=YAML.stringify({File:{oneOf:[{...scalar,minLength:4},{type:'array',minItems:1,maxItems:1,items:scalar}]}});
 const pointer='/paths/~1files/post/requestBody/content/multipart~1form-data';
 const body='--Fixture\r\nContent-Disposition: form-data; name="asset"; filename="blob.bin"\r\nContent-Type: '+(legacy?'application/octet-stream':'text/plain')+'\r\n\r\nabc\r\n--Fixture--\r\n';
 const checked=await evaluateSchemas({...input,runtimeInstances:['single','array'].map(shape=>({subject:'request-body',location:shape,text:body,mediaType:'multipart/form-data; boundary=Fixture',schema:{resource:input.root,pointer:pointer+'/schema'},form:{resource:input.root,pointer,fileShapes:{asset:shape}}}))});
 assert.equal(checked.complete,true,JSON.stringify(checked.runtimeFindings));
 assert.deepEqual(checked.runtimeEvaluations.map(value=>value.valid),[false,true],JSON.stringify(checked.runtimeFindings));
});

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const binding of ['generic','ordered-form','item-schema','nested'])test(`${version} ${format} unowned file grouping refuses ${binding} MIME`,async()=>{
 const input=packet(version,format,'array'),value=YAML.parse(input.resources[0].text),content=value.paths['/files'].post.requestBody.content,media=content['multipart/form-data'];
 const type=binding==='generic'?'multipart/mixed':'multipart/form-data';
 const item={type:'object',properties:{asset:{type:'string'}}};
 if(binding==='nested'){media.schema={type:'object',properties:{asset:{type:'array',items:{type:'string'}}}};media.encoding.asset={contentType:'multipart/mixed'};}
 else if(binding==='generic'){media.schema={type:'array',items:{type:'string'}};content[type]=media;delete content['multipart/form-data'];}
 else {media.schema={type:'array',items:item};if(binding==='item-schema')media.itemSchema=item;}
 input.resources[0].text=format==='yaml'?YAML.stringify(value):JSON.stringify(value);
 const pointer='/paths/~1files/post/requestBody/content/'+type.replaceAll('/','~1');
 const disposition=type==='multipart/form-data'?'Content-Disposition: form-data; name="asset"\r\n':'';
 const text=binding==='nested'?'--Fixture\r\n'+disposition+'Content-Type: multipart/mixed; boundary=Inner\r\n\r\n--Inner\r\nContent-Type: text/plain\r\n\r\nabc\r\n--Inner--\r\n\r\n--Fixture--\r\n':'--Fixture\r\n'+disposition+'Content-Type: text/plain\r\n\r\nabc\r\n--Fixture--\r\n';
 const before=input.resources.map(resource=>resource.text),result=await evaluateSchemas({...input,runtimeInstances:[{subject:'request-body',location:'grouping',text,mediaType:type+'; boundary=Fixture',schema:{resource:input.root,pointer:pointer+'/schema'},form:{resource:input.root,pointer,fileShapes:{asset:'array'}}}]});
 assert.equal(result.complete,false,JSON.stringify(result.runtimeFindings));assert(result.runtimeFindings.some(finding=>finding.detailCode==='runtime.form.file-shape'),JSON.stringify(result.runtimeFindings));assert.deepEqual(input.resources.map(resource=>resource.text),before);
});
