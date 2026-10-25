const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse,inspect}=require('./dist/model.cjs');
const {planMigration}=require('./dist/migration.cjs');
const {SourceDocument}=require('./dist/document.cjs');

function fixture(version,format){
 const legacy=version==='2.0',root='file:///roles/api.'+format;
 const schemes={Key:{type:'apiKey',name:'X-Key',in:'header'}};
 const value={...(legacy?{swagger:version}:{openapi:version}),info:{title:'Role semantics',version:'1'},paths:{},security:[{Key:['reader','雪']}],...(legacy?{securityDefinitions:schemes}:{components:{securitySchemes:schemes}})};
 const text=format==='yaml'?'# Retain role names\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value,null,2)+'\n';
 return {root,snapshot:'roles',resources:[{id:root,text,generation:2}]};
}
for(const version of ['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} non-OAuth role names follow native family rules`,()=>{
 const input=fixture(version,format),original=input.resources[0].text;
 const modern=/^3\.[12]\./.test(version),analysis=analyse(input),view=inspect({...input,resource:input.root,pointer:'/security/0/Key'});
 assert.equal(analysis.status,modern?'complete':'invalid',JSON.stringify(analysis.findings));
 assert.equal(view.securityBinding.kind,modern?'roles':'empty');
 assert.equal(view.capabilities.securityRequirementUris,version.startsWith('3.2.'));
 const finding=analysis.findings.find(value=>value.code==='security.scopes.empty');
 if(modern)assert.equal(finding,undefined);
 else {assert.equal(finding.pointer,'/security/0/Key');assert.ok(finding.range[1]>finding.range[0]);}
 assert.equal(input.resources[0].text,original);
});
for(const format of ['yaml','json'])for(const [from,target] of [['3.1.2','3.2.1'],['3.2.1','3.1.2'],['3.1.2','3.0.4'],['3.2.1','2.0']])test(`${format} role migration ${from} to ${target} preserves meaning or locates its blocker`,async()=>{
 const input=fixture(from,format),original=input.resources[0].text;
 const result=await planMigration({...input,targetVersion:target,destination:'file:///roles-output/'});
 if(/^3\.[12]\./.test(target)){
  assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.status,'faithfully-convertible');
  const after={root:result.outputRoot,snapshot:'target',resources:result.outputs.map(output=>({id:output.id,text:output.text,generation:0}))};
  assert.equal(analyse(after).status,'complete');
  const document=new SourceDocument(after.resources.find(resource=>resource.id===after.root).text,after.root);
  assert.deepEqual(document.dataNode('/security/0/Key').value,['reader','雪']);
 }else{
  assert.equal(result.complete,false);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
  const blocker=result.problems.find(value=>value.code==='migration.security.roles');
  assert.ok(blocker,JSON.stringify(result.problems));assert.equal(blocker.reason,'target-representation');
  assert.equal(blocker.resource,input.root);assert.equal(blocker.pointer,'/security/0/Key');assert.ok(blocker.range[1]>blocker.range[0]);
 }
 assert.equal(input.resources[0].text,original);
});

for(const format of ['yaml','json'])for(const targetVersion of ['3.2.1','3.0.4'])test(`${format} shared operation role migration to ${targetVersion} retains its source owner`,async()=>{
 const input=fixture('3.1.2',format),part='file:///roles/shared.'+format;
 const document=format==='json'?JSON.parse(input.resources[0].text):YAML.parse(input.resources[0].text);
 delete document.security;document.paths={'/p':{$ref:'shared.'+format+'#/Path'}};
 const operation={Path:{get:{security:[{Key:['reader','雪']}],responses:{204:{description:'Empty'}}}}};
 const encode=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);
 input.resources[0].text=encode(document);input.resources.push({id:part,generation:5,text:encode(operation)});
 const original=input.resources.map(resource=>resource.text),result=await planMigration({...input,targetVersion,destination:'file:///roles-output/'});
 if(targetVersion==='3.2.1'){
  assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.outputs.length,2);
  assert.equal(result.invariants.requests,'effective-url-serialization-security-and-media');
 }else{
  assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
  const blocker=result.problems.find(value=>value.code==='migration.security.roles');
  assert.ok(blocker,JSON.stringify(result.problems));assert.equal(blocker.resource,part);
  assert.equal(blocker.pointer,'/Path/get/security/0/Key');assert.ok(blocker.range[1]>blocker.range[0]);
 }
 assert.deepEqual(input.resources.map(resource=>resource.text),original);
});
