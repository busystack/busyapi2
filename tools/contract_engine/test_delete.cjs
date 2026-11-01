const assert = require('node:assert/strict');
const {test} = require('node:test');
const YAML = require('yaml');
const {planDelete} = require('./dist/refactoring_delete.cjs');
const {createGraph,inspect} = require('./dist/model.cjs');
const apply = (input, plan) => input.resources.map(resource => {
 let text = resource.text;
 for(const edit of plan.edits.filter(e=>e.buffer===resource.id).sort((a,b)=>b.start-a.start)) {
  assert.equal(text.slice(edit.start,edit.end),edit.expected);
  text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
 }
 return {...resource,text};
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`reviewed object deletion ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///project/root.'+(json?'json':'yaml'), part='file:///project/part.json';
 const value={openapi:version,info:{title:'Delete',version:'1'},paths:{},components:{schemas:{Model:{type:'object',properties:{old:{type:'string',maxLength:12},keep:{type:'number'}},required:['old','keep'],examples:[{old:'do not rewrite'}],dependentRequired:{keep:['old']},'x-data':{old:{$ref:'literal'}}},Unused:{type:'object',properties:{self:{$ref:'#/components/schemas/Unused'}}},External:{$ref:'part.json#/Schema'}},securitySchemes:{Key:{type:'http',scheme:'bearer'}}},security:[{Key:[]}]};
 const text=json?JSON.stringify(value,null,2):'# kept 😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
 const input={snapshot:'captured',resources:[{id:root,generation:3,text},{id:part,generation:4,text:JSON.stringify({Schema:{$ref:(json?'root.json':'root.yaml')+'#/components/schemas/Model'}})}],contexts:[{root,resources:[root,part]}],target:{resource:root,generation:3,pointer:'/components/schemas/Model/properties/old'}};
 const plan=planDelete(input), resources=apply(input,plan), actual=json?JSON.parse(resources[0].text):YAML.parse(resources[0].text);
 assert.equal(plan.kind,'object-delete');assert.equal(plan.blockers.length,0);
 assert(!Object.hasOwn(actual.components.schemas.Model.properties,'old'));assert.deepEqual(actual.components.schemas.Model.required,['keep']);
 assert.deepEqual(actual.components.schemas.Model.examples,[{old:'do not rewrite'}]);assert.deepEqual(actual.components.schemas.Model.dependentRequired,{keep:['old']});
 assert.equal(actual.components.schemas.Model['x-data'].old.$ref,'literal');assert(plan.preservedRelationships.some(p=>p.endsWith('/dependentRequired')));
 assert(plan.usages.some(u=>u.resource===part&&u.effect==='definition-content-changes'));
 assert.equal(resources[1].text,input.resources[1].text);assert.equal(createGraph({root,resources}).graph.issues.length,0);
 assert.equal(plan.transitions[0].mode,'removal');assert.equal(plan.transitions[0].to,'/components/schemas/Model/properties');
 if(!json){assert(resources[0].text.startsWith('# kept 😀\r\n'));assert(!/(?<!\r)\n/.test(resources[0].text));}
 const used=planDelete({...input,target:{...input.target,pointer:'/components/schemas/Model'}});
 assert(used.blockers.some(u=>u.resource===part&&u.effect==='would-be-unresolved'));
 const security=planDelete({...input,target:{...input.target,pointer:'/components/securitySchemes/Key'}});
 assert(security.blockers.some(u=>u.connection==='security'));
 const unused=planDelete({...input,target:{...input.target,pointer:'/components/schemas/Unused'}});
 assert.equal(unused.blockers.length,0);assert(unused.usages.some(u=>u.effect==='removed-with-object'));
 assert(!Object.hasOwn((json?JSON.parse:YAML.parse)(apply(input,unused)[0].text).components.schemas,'Unused'));
 assert.throws(()=>planDelete({...input,target:{...input.target,pointer:'/info/title'}}),e=>e.code==='refactor.delete.required');
 assert.equal(inspect({...input,root,resource:root,pointer:'/info'}).removable,false);
 assert.equal(inspect({...input,root,resource:root,pointer:'/components/schemas/Model'}).removable,true);
 assert.throws(()=>planDelete({...input,target:{...input.target,generation:2}}),e=>e.code==='edit.stale');
});
test('array deletion repairs proven sibling pointers across resources without retargeting examples',()=>{
 const root='file:///project/root.json', part='file:///project/part.json';
 const value={openapi:'3.2.1',info:{title:'Array',version:'1'},paths:{},components:{schemas:{M:{anyOf:[false,{type:'string'},{type:'number'}]},Use:{$ref:'#/components/schemas/M/anyOf/2'},External:{$ref:'part.json#/Use'}},examples:{E:{value:{$ref:'#/components/schemas/M/anyOf/2'}}}}};
 const input={snapshot:'s',resources:[{id:root,generation:1,text:JSON.stringify(value)},{id:part,generation:2,text:'{"Use":{"$ref":"root.json#/components/schemas/M/anyOf/1"}}'}],contexts:[{root,resources:[root,part]}],target:{resource:root,generation:1,pointer:'/components/schemas/M/anyOf/0'}};
 const plan=planDelete(input), resources=apply(input,plan), after=JSON.parse(resources[0].text);
 assert.equal(plan.blockers.length,0);assert.equal(plan.edits.length,2);
 assert.equal(after.components.schemas.Use.$ref,'#/components/schemas/M/anyOf/1');
 assert.equal(JSON.parse(resources[1].text).Use.$ref,'root.json#/components/schemas/M/anyOf/0');
 assert.equal(after.components.examples.E.value.$ref,'#/components/schemas/M/anyOf/2');
 assert.deepEqual(plan.transitions.slice(1).map(t=>[t.from,t.to]),[['/components/schemas/M/anyOf/1','/components/schemas/M/anyOf/0'],['/components/schemas/M/anyOf/2','/components/schemas/M/anyOf/1']]);
 assert.equal(createGraph({root,resources}).graph.issues.length,0);
});
test('a surviving dynamic-scope candidate blocks deletion even when its static target remains',()=>{
 const root='file:///project/root.json';
 const value={openapi:'3.2.1',info:{title:'Dynamic',version:'1'},paths:{},components:{schemas:{Base:{$id:'https://example.test/base',$dynamicAnchor:'node',type:'object',properties:{child:{$dynamicRef:'#node'}}},Override:{$id:'https://example.test/override',$dynamicAnchor:'node',allOf:[{$ref:'https://example.test/base'}]}}}};
 const input={snapshot:'d',resources:[{id:root,generation:1,text:JSON.stringify(value)}],contexts:[{root,resources:[root]}],target:{resource:root,generation:1,pointer:'/components/schemas/Override'}};
 const plan=planDelete(input);
 assert(plan.blockers.some(b=>b.effect==='dynamic-scope-candidate'));
});
test('required discriminator and OAuth flow fields cannot become optional through deletion metadata',()=>{
 for(const version of ['3.1.2','3.2.1']){
  const root='file:///project/root.json';
  const value={openapi:version,info:{title:'Required',version:'1'},paths:{},components:{schemas:{M:{oneOf:[false],discriminator:{propertyName:'kind'}}},securitySchemes:{OAuth:{type:'oauth2',flows:{authorizationCode:{authorizationUrl:'https://example.test/auth',tokenUrl:'https://example.test/token',scopes:{}}}}}}};
  const input={snapshot:'required',resources:[{id:root,generation:1,text:JSON.stringify(value)}],contexts:[{root,resources:[root]}]};
  for(const pointer of ['/components/schemas/M/discriminator/propertyName','/components/securitySchemes/OAuth/flows/authorizationCode/authorizationUrl','/components/securitySchemes/OAuth/flows/authorizationCode/scopes'])
   assert.throws(()=>planDelete({...input,target:{resource:root,generation:1,pointer}}),e=>e.code==='refactor.delete.required');
 }
});
