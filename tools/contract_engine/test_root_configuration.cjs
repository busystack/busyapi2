const {test}=require('node:test');
const assert=require('node:assert/strict');
const {planRootRemoval}=require('./dist/refactoring_file.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const id='file:///p/busyapi.yaml';
function capture(input,other=[]){
 const resources=input.configuredRoots.map((id,index)=>({id,generation:0,text:id.endsWith('.json')?JSON.stringify({openapi:'3.2.1',info:{title:'Root '+index,version:'1'},paths:{}}):'openapi: 3.2.1\ninfo: {title: Root '+index+', version: "1"}\npaths: {}\n'}));
 resources.push(input.manifest,...other);
 return {...input,resources,manifestAliases:[],contexts:input.configuredRoots.map(root=>({root,resources:resources.map(resource=>resource.id)}))};
}
for(const json of [false,true])for(const last of [false,true])test(`root declaration removal preserves exact unknown data and other owners json=${json} last=${last}`,()=>{
 const text=json?'{\r\n"version":1,"roots":[{"name":"First","path":"one 雪.yaml"}'+(last?'':',{"name":"Second","path":"two.json"}')+'],"unknown":{"n":900719925474099312345,"$ref":"literal"}}':
  '# retained 😀\r\nversion: 1\nroots:\n  - {name: First, path: "one 雪.yaml"} # removed owner\r\n'+(last?'':'  - {name: Second, path: two.json} # kept owner\n')+'unknown: {n: 900719925474099312345, $ref: "literal"}';
 const input=capture({snapshot:'root-config',manifest:{id,text,generation:3,hasBom:true},target:{index:0,name:'First',resource:'file:///p/one%20%E9%9B%AA.yaml'},configuredRoots:['file:///p/one%20%E9%9B%AA.yaml',...last?[]:['file:///p/two.json']]});
 const before=JSON.stringify(input),plan=planRootRemoval(input),output=plan.changes[0].after;
 assert.equal(plan.kind,'root-remove');assert.equal(plan.remaining,last?0:1);assert.deepEqual(plan.transitions,[]);assert.deepEqual(plan.checkedRoots,input.configuredRoots);assert.deepEqual(plan.blockers,[]);
 assert.deepEqual(new SourceDocument(output,id).root.value.roots,last?[]:[{name:'Second',path:'two.json'}]);
 assert(output.includes('900719925474099312345'));assert(output.includes('literal'));assert.equal(output.endsWith('\n'),false);
 if(!json){assert(output.startsWith('# retained 😀\r\n'));if(!last)assert(output.includes('# kept owner'));}
 let applied=text;for(const edit of [...plan.edits].sort((a,b)=>b.start-a.start)){
  assert.equal(edit.buffer,id);assert.equal(edit.generation,3);assert.equal(text.slice(edit.start,edit.end),edit.expected);
  applied=applied.slice(0,edit.start)+edit.replacement+applied.slice(edit.end);
 }
 assert.equal(applied,output);assert.equal(JSON.stringify(input),before);assert.deepEqual(plan,planRootRemoval(input));
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`manifest dual ownership uses canonical consumers, not payload spellings ${version} json=${json}`,()=>{
 const manifest={id,generation:3,text:'version: 1\nroots: [{name: First, path: one.yaml, type: string}, {name: Second, path: two.yaml, type: integer}]\n$defs:\n  Stable: {$id: "https://example.invalid/stable", $dynamicAnchor: node, type: object, properties: {next: {$dynamicRef: "#node"}}}\nunknown: {$ref: "#/roots/0"}\n'};
 const base=capture({snapshot:'dual-role',manifest,target:{index:0,name:'First',resource:'file:///p/one.yaml'},configuredRoots:['file:///p/one.yaml','file:///p/two.yaml']});
 function api(schema,example){
  const value={openapi:version,info:{title:'Root',version:'1'},paths:{},components:{schemas:{Use:schema}},'x-data':{$ref:'busyapi.yaml#/roots/0'}};
  if(example)value.components.examples={Data:example};
  const text=json?JSON.stringify(value):require('yaml').stringify(value);
  return {...base,resources:base.resources.map(resource=>resource.id===base.configuredRoots[1]?{...resource,text}:resource)};
 }
 for(const pointer of ['/roots/0','/roots/1','/roots','']){
  const plan=planRootRemoval(api({$ref:'busyapi.yaml#'+pointer}));
  assert(plan.blockers.some(value=>value.code==='root.remove.consumer'&&value.pointer==='/components/schemas/Use/$ref'));
  assert(plan.usages.some(value=>value.target.resource===id));
 }
 const safe=api({$ref:'busyapi.yaml#/$defs/Stable'},{value:{$ref:'busyapi.yaml#/roots/0',n:9007199254740992}});
 assert.deepEqual(planRootRemoval(safe).blockers,[]);
 const later={...api({$ref:'busyapi.yaml#/roots/0'}),target:{index:1,name:'Second',resource:'file:///p/two.yaml'}};
 assert.deepEqual(planRootRemoval(later).blockers,[],'an earlier schema keeps its identity when a later registration is removed');
 for(const locator of ['busyapi.yaml','https://example.invalid/configuration']){
  const input=api({type:'string'},{externalValue:locator});
  if(locator.startsWith('https:'))input.manifestAliases=[locator];
  const plan=planRootRemoval(input);
  assert(plan.blockers.some(value=>value.code==='root.remove.data-consumer'&&value.pointer==='/components/examples/Data/externalValue'));
 }
 const missing=planRootRemoval(api({$ref:'not-approved.yaml#/Missing'}));
 assert(missing.blockers.some(value=>value.code==='root.remove.analysis'));
 assert.throws(()=>planRootRemoval({...safe,contexts:[]}),error=>error.code==='root.context');
 assert.throws(()=>planRootRemoval({...safe,manifest:{...manifest,text:manifest.text+'# newer\n'}}),error=>error.code==='edit.stale');
});
test('a stale declaration, invalid source or shared syntax cannot silently remove a different owner',()=>{
 const base={snapshot:'root-config',manifest:{id,text:'version: 1\nroots: [{name: First, path: one.yaml}]\n',generation:0},target:{index:0,name:'First',resource:'file:///p/one.yaml'},configuredRoots:['file:///p/one.yaml']};
 for(const input of [{...base,target:{...base.target,name:'Second'}},{...base,target:{...base.target,index:1}},
  {...base,manifest:{...base.manifest,text:'version: 1\nroots: [\n'}},
  {...base,manifest:{...base.manifest,text:'version: 1\nroot: &shared {name: First, path: one.yaml}\nroots: [*shared]\n'}}])
  assert.throws(()=>planRootRemoval(input),error=>/^(root\.|edit\.shared)/.test(error.code));
});
