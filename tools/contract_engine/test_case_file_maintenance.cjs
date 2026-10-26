const assert=require('node:assert/strict');
const {test}=require('node:test');
const base=process.env.BUSYAPI_CASE_FILE_BASELINE||__dirname;
const YAML=require(base+'/node_modules/yaml');
const {planFileMove,planFileDeletion}=require(base+'/dist/refactoring_file.cjs');
const {SourceDocument}=require(base+'/dist/document.cjs');
for(const version of ['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json']){
 const root='file:///project/api.'+format,source='file:///project/payload.'+format,destination='file:///project/new%20%E9%9B%AA/payload.'+format;
 const swagger=version==='2.0';
 const op={responses:{204:{description:'No body'}},...(swagger?{consumes:['multipart/form-data'],parameters:[{name:'asset',in:'formData',type:'file'}]}:{requestBody:{content:{'multipart/form-data':{schema:{type:'object',properties:{asset:version.startsWith('3.0.')?{type:'string',format:'binary'}:{}}},encoding:{asset:{contentType:'application/octet-stream'}}}}}})};
 const value={[swagger?'swagger':'openapi']:version,info:{title:'Case files',version:'unrelated'},paths:{'/items':{post:op}}};
 const api={id:root,text:format==='json'?JSON.stringify(value):YAML.stringify(value),generation:1};
 const manifest={id:'file:///project/busyapi.yaml',text:'version: 1\nroots: [{name: api, path: api.'+format+'}]\n# Retain case source\ntests:\n  - name: upload\n    operation: {method: post, path: /items}\n    body:\n      mediaType: multipart/form-data\n      value: {literal: "payload.'+format+'"}\n      files:\n        - {name: asset, path: "./payload.'+format+'", mediaType: application/octet-stream}\nx-literal: {path: "payload.'+format+'"}\n',generation:2};
 const data={id:source,text:'{"openapi":"3.2.1","$ref":"literal payload", "n":9007199254740993.00}',generation:3};
 const packet={snapshot:'case-file-'+version+'-'+format,resources:[api],contexts:[{root,resources:[root]}],target:{resource:source,generation:3},manifest};
 test(`${version} ${format} moving a case input repairs only its owned path`,()=>{
  const plan=planFileMove({...packet,moveSource:data,destinationResource:destination});
  const edits=plan.edits.filter(edit=>edit.buffer===manifest.id);assert.equal(edits.length,1);
  let after=manifest.text;for(const edit of [...edits].reverse())after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
  const changed=new SourceDocument(after,manifest.id);
  assert.equal(changed.node('/tests/0/body/files/0/path').value,'./new 雪/payload.'+format);
  assert.equal(changed.node('/tests/0/body/value/literal').value,'payload.'+format);
  assert.equal(changed.node('/x-literal/path').value,'payload.'+format);
  assert(plan.usages.some(usage=>usage.connection==='case-file'&&usage.pointer==='/tests/0/body/files/0/path'));
 });
 test(`${version} ${format} deleting a configured case input is blocked`,()=>{
  const plan=planFileDeletion({...packet,deletionSource:data});
  assert(plan.blockers.some(blocker=>blocker.code==='file.delete.case-file'));
  assert(plan.usages.some(usage=>usage.connection==='case-file'&&usage.resource===manifest.id));
 });
}
const root='file:///project/api.json',source='file:///project/payload.json';
const api={id:root,text:'{"openapi":"3.0.4","info":{"title":"Case paths","version":"1"},"paths":{}}',generation:1};
const data={id:source,text:'opaque serialized data',generation:2};
const original='version: 1\nroots: [{name: Main, path: api.json}]\ntests: [{name: upload, body: {files: [{name: asset, path: "./payload.json"}]}}]\n';
const manifest={id:'file:///project/busyapi.yaml',text:original,generation:3};
const packet={snapshot:'case-files',resources:[api],contexts:[{root,resources:[root]}],target:{resource:source,generation:2},manifest};
function move(overrides={}){return planFileMove({...packet,moveSource:data,destinationResource:'file:///project/new.json',...overrides});}
function remove(overrides={}){return planFileDeletion({...packet,deletionSource:data,...overrides});}
function after(plan,text=original){for(const edit of [...plan.edits].reverse())if(edit.buffer===manifest.id)text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);return text;}
test('retained API URI identity still repairs the physical saved upload path',()=>{
 const plan=move({retainIdentity:true});const doc=new SourceDocument(after(plan),manifest.id);
 assert.equal(doc.node('/tests/0/body/files/0/path').value,'./new.json');
 assert.equal(doc.node('/resourceMappings/payload.json').value,'new.json');
 assert.equal(plan.file.retainedIdentity,source);
});
test('no-op move keeps every configuration byte and exposes no spurious usages',()=>{
 const plan=move({destinationResource:source});assert.deepEqual(plan.edits,[]);assert.deepEqual(plan.transitions,[]);assert.deepEqual(plan.usages,[]);
});
test('a saved file cannot be moved outside its project boundary',()=>{
 assert.throws(()=>move({destinationResource:'file:///outside/payload.json'}),e=>e.code==='file.move.case-file.boundary'&&e.source.resource===manifest.id&&e.source.pointer==='/tests/0/body/files/0/path');
});
test('case locators use literal filesystem percent spelling and decoded destination characters',()=>{
 const encodedSource='file:///project/%25literal.json',text=original.replace('./payload.json','./%literal.json');
 const plan=move({target:{resource:encodedSource,generation:2},moveSource:{...data,id:encodedSource},manifest:{...manifest,text},destinationResource:'file:///project/100%25%20%E9%9B%AA.json'});
 const doc=new SourceDocument(after(plan,text),manifest.id);assert.equal(doc.node('/tests/0/body/files/0/path').value,'./100% 雪.json');
});
for(const tests of ['false','{}','[false]','[{body: {files: false}}]','[{body: {files: [{path: "../payload.json"}]}}]','[{body: {files: [{path: "/payload.json"}]}}]','[{body: {files: [{path: false}]}}]']){
 test('malformed case file ownership cannot prove safe maintenance: '+tests,()=>{
  const bad={...manifest,text:'version: 1\nroots: [{name: Main, path: api.json}]\ntests: '+tests+'\n'};
  for(const run of [()=>move({manifest:bad}),()=>remove({manifest:bad})])assert.throws(run,e=>e.code==='test.configuration'&&e.source.resource===manifest.id);
 });
}
for(const tests of ['null','[]'])test('absent saved files preserve unrelated maintenance: '+tests,()=>{
 const empty={...manifest,text:'version: 1\nroots: [{name: Main, path: api.json}]\ntests: '+tests+'\n'};
 assert.deepEqual(remove({manifest:empty}).blockers,[]);assert.deepEqual(move({manifest:empty}).edits,[]);
});
test('all matching case entries are source-edited and lookalike payloads remain exact',()=>{
 const text=original.replace('tests: [','x-literal: {files: [{path: "./payload.json"}]}\n# Keep\ntests: [').replace('name: upload','name: first').replace('}]}}]','}]}}, {name: second, body: {files: [{name: asset, path: "payload.json"}], value: {path: "./payload.json"}}}]');
 const plan=move({manifest:{...manifest,text}}),doc=new SourceDocument(after(plan,text),manifest.id);
 assert.equal(doc.node('/tests/0/body/files/0/path').value,'./new.json');assert.equal(doc.node('/tests/1/body/files/0/path').value,'new.json');
 assert.equal(doc.node('/tests/1/body/value/path').value,'./payload.json');assert.equal(doc.node('/x-literal/files/0/path').value,'./payload.json');assert.equal(plan.usages.length,2);
});
test('shared YAML upload ownership refuses ambiguous edits but still protects deletion',()=>{
 const shared={...manifest,text:'version: 1\nroots: [{name: Main, path: api.json}]\nx-copy: &file {name: asset, path: "./payload.json"}\ntests: [{body: {files: [*file]}}]\n'};
 assert.throws(()=>move({manifest:shared}),e=>e.code.startsWith('yaml.')||e.code.startsWith('edit.'));
 assert(remove({manifest:shared}).blockers.some(e=>e.code==='file.delete.case-file'));
});
test('deletion identity captures configuration revisions independently of the API graph',()=>{
 assert.notEqual(remove().identity,remove({manifest:{...manifest,generation:4}}).identity);
 assert.notEqual(remove().identity,remove({manifest:{...manifest,text:original+'# new review\n'}}).identity);
});
test('disagreeing graph and configuration snapshots cannot certify deletion',()=>{
 assert.throws(()=>remove({resources:[api,{...manifest,text:original+'# disagreement\n'}]}),e=>e.code==='file.delete.snapshot');
});
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json']){
 test(`${version} ${format} dual contract/upload source refuses changed payload bytes and retained identity preserves them`,()=>{
  const root='file:///project/api.'+format,source='file:///project/payload.'+format,model='file:///project/model.'+format;
  const value={[version==='2.0'?'swagger':'openapi']:version,info:{title:'Dual owner',version:'1'},paths:{},...(version==='2.0'?{definitions:{Value:{$ref:'./payload.'+format+'#/Value'}}}:{components:{schemas:{Value:{$ref:'./payload.'+format+'#/Value'}}}})};
  const serialize=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);
  const resources=[{id:root,generation:1,text:serialize(value)},{id:source,generation:2,text:serialize({Value:{$ref:'./model.'+format}})},{id:model,generation:1,text:serialize({type:'string'})}];
  const manifest={id:'file:///project/busyapi.yaml',generation:1,text:'version: 1\nroots: [{name: Main, path: api.'+format+'}]\ntests: [{body: {files: [{name: asset, path: "./payload.'+format+'"}]}}]\n'};
  const input={snapshot:'dual-owner',resources,contexts:[{root,resources:resources.map(r=>r.id)}],target:{resource:source,generation:2},manifest,destinationResource:'file:///project/new/payload.'+format};
  assert.throws(()=>planFileMove(input),e=>e.code==='file.move.case-file.content'&&e.source.resource===manifest.id&&e.source.pointer==='/tests/0/body/files/0/path');
  const plan=planFileMove({...input,retainIdentity:true});assert(!plan.edits.some(e=>e.buffer===source));
  const edits=plan.edits.filter(e=>e.buffer===manifest.id);let text=manifest.text;for(const edit of [...edits].reverse())text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
  assert.equal(new SourceDocument(text,manifest.id).node('/tests/0/body/files/0/path').value,'./new/payload.'+format);
  assert.equal(resources[1].text,serialize({Value:{$ref:'./model.'+format}}));
 });
}
