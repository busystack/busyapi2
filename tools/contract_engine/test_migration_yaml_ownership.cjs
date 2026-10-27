const assert=require('node:assert/strict');
const {test}=require('node:test');
const {planMigration}=require('./dist/migration.cjs');
const {analyse}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');

const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const targets=['2.0','3.0.4','3.1.2','3.2.1'];
const root='file:///approved/api.yaml',model='file:///approved/models.yaml';
const tail='x-literal: &payload\r\n  number: 9007199254740993.00 # exact\r\n  text: "café 東京"\r\n  ref: {$ref: literal-only}\r\nx-copy: *payload\r\nx-false: &flag false\r\nx-flag: *flag\r\nx-empty: &empty ""\r\nx-empty-copy: *empty\r\n';
function capture(version,extra=''){
 const swagger=version==='2.0';
 const text='# Keep organization\r\n'+(swagger?'swagger':'openapi')+': "'+version+'"\r\n'+
  'info: &metadata {title: Alias, version: "1"}\r\npaths: {}\r\n'+
  (swagger?'definitions:\r\n  Value:':'components:\r\n  schemas:\r\n    Value:')+' {$ref: "models.yaml#/Item"}\r\n'+tail+extra;
 return {root,snapshot:'ownership-'+version,targetVersion:'3.2.1',destination:'file:///reviewed/',resources:[
  {id:root,text,generation:1},{id:model,generation:2,text:'# Shared exact model\r\nItem: {type: object, required: [id], properties: {id: {type: integer, enum: [9007199254740993.00]}}, additionalProperties: false}\r\n'+tail}]};
}
for(const version of versions)for(const targetVersion of targets)
test(`migration preserves untouched YAML ownership ${version} → ${targetVersion}`,async()=>{
 const input={...capture(version),targetVersion},before=input.resources.map(value=>value.text);
 const result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.producerVersion,'15');
 assert.equal(result.status,'faithfully-convertible');assert.deepEqual(input.resources.map(value=>value.text),before);
 const output=result.outputs.find(value=>value.id===result.outputRoot);
 assert(output.text.startsWith('# Keep organization\r\n'));
 assert(output.text.includes('info: &metadata {title: Alias, version: "1"}\r\n'));
 assert(output.text.includes(tail));
 assert.equal(result.outputs.find(value=>value.id!==result.outputRoot).text,before[1]);
 const resources=result.outputs.map(value=>({id:value.id,text:value.text,generation:0}));
 const captured={root:result.outputRoot,snapshot:'cold-'+version+targetVersion,resources};
 assert.equal(analyse(captured).status,'complete');
 const evaluations=await evaluateSchemas({...captured,runtimeInstances:['9007199254740993.00','9007199254740992.00'].map(number=>({
  subject:'response-body',location:'exact',text:'{"id":'+number+'}',schema:{resource:result.outputRoot,pointer:targetVersion==='2.0'?'/definitions/Value':'/components/schemas/Value'}}))});
 assert.equal(evaluations.complete,true,JSON.stringify(evaluations.findings));
 assert.deepEqual(evaluations.runtimeEvaluations.map(value=>value.valid),[true,false]);
});

for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])
test(`an unchanged anchored declaration retains its alias ${version}`,async()=>{
 const input=capture(version,'x-version: *version\r\n');
 input.resources[0].text=input.resources[0].text.replace('openapi: "'+version+'"','openapi: &version "'+version+'"');
 const result=await planMigration({...input,targetVersion:version});
 assert.equal(result.complete,true,JSON.stringify(result.problems));
 assert(result.outputs[0].text.includes('openapi: &version "'+version+'"'));
 assert(result.outputs[0].text.includes('x-version: *version'));
});

for(const [version,targetVersion,body,pointer]of [
 ['3.0.4','3.1.2','Value: &value {type: string, nullable: true}\nx-other: *value','/components/schemas/Value/type'],
 ['3.1.2','3.0.4','Value: &value false\nx-other: *value','/components/schemas/Value'],
])test(`changed shared schema stays a located blocker ${version} → ${targetVersion}`,async()=>{
 const text='openapi: "'+version+'"\ninfo: {title: Shared, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    '+body.split('\n')[0]+'\n'+body.split('\n')[1]+'\n';
 const input={root,snapshot:'shared',targetVersion,destination:'file:///reviewed/',resources:[{id:root,text,generation:1}]};
 const result=await planMigration(input);
 assert.equal(result.complete,false);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
 const problem=result.problems.find(value=>value.code==='edit.shared');
 assert(problem,JSON.stringify(result.problems));assert.equal(problem.resource,root);assert.equal(problem.pointer,pointer);
 assert(problem.range[1]>problem.range[0]);assert.equal(input.resources[0].text,text);
});

for(const [version,targetVersion]of [['3.0.0','3.0.4'],['3.1.0','3.1.2'],['3.2.0','3.2.1']])
test(`a changed shared patch declaration is a located review blocker ${version} → ${targetVersion}`,async()=>{
 const input=capture(version,'x-version: *version\r\n');
 input.resources[0].text=input.resources[0].text.replace('openapi: "'+version+'"','openapi: &version "'+version+'"');
 const original=input.resources[0].text;
 const result=await planMigration({...input,targetVersion});
 assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
 assert(result.problems.some(value=>value.code==='edit.shared'&&value.resource===root&&value.pointer==='/openapi'&&value.range[1]>value.range[0]),JSON.stringify(result.problems));
 assert.equal(input.resources[0].text,original);
});

test('unchanged anchored canonical references and schema identities retain their YAML owners',async()=>{
 const text='openapi: 3.1.2\ninfo: {title: Canonical, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Value:\n      $ref: &reference "https://schemas.invalid/item"\nx-reference: *reference\n';
 const shared='$schema: https://json-schema.org/draft/2020-12/schema\n$id: &identity "https://schemas.invalid/item"\ntype: integer\nenum: [9007199254740993.00]\nx-identity: *identity\n';
 const input={root,snapshot:'canonical',targetVersion:'3.2.1',destination:'file:///reviewed/',resources:[{id:root,text,generation:1},{id:model,text:shared,generation:2}]};
 const result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));
 assert(result.outputs[0].text.includes('$ref: &reference "https://schemas.invalid/item"'));
 assert(result.outputs[0].text.includes('x-reference: *reference'));
 assert.equal(result.outputs[1].text,shared);
 assert.deepEqual(input.resources.map(value=>value.text),[text,shared]);
});

for(const [label,text,targetVersion,pointer]of [
 ['anchored reusable map','swagger: "2.0"\ninfo: {title: Shared, version: "1"}\npaths: {}\ndefinitions: &definitions {Value: {type: string}}\nx-copy: *definitions\n','3.0.4','/definitions'],
 ['copied body schema','swagger: "2.0"\ninfo: {title: Shared, version: "1"}\nconsumes: [application/json]\npaths: {/x: {post: {parameters: [{$ref: "#/parameters/Body"}], responses: {204: {description: Empty}}}}}\nparameters:\n  Body:\n    name: payload\n    in: body\n    schema:\n      type: object\n      default: &payload {}\nx-copy: *payload\n','3.0.4','/parameters/Body/schema/default'],
 ['relocated file locator','openapi: 3.1.2\ninfo: {title: Shared, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Value:\n      $ref: &reference "models.yaml#/Item"\nx-reference: *reference\n','3.2.1','/components/schemas/Value/$ref'],
])test(`migration refuses a changed ${label} at its physical owner`,async()=>{
 const input={root,snapshot:label,targetVersion,destination:'file:///reviewed/',resources:[{id:root,text,generation:1},
  ...(label==='relocated file locator'?[{id:model,text:'Item: {type: string}\n',generation:2}]:[])]};
 const original=input.resources.map(value=>value.text),result=await planMigration(input);
 assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
 assert(result.problems.some(value=>value.code==='edit.shared'&&value.resource===root&&value.pointer===pointer&&value.range[1]>value.range[0]),JSON.stringify(result.problems));
 assert.deepEqual(input.resources.map(value=>value.text),original);
});

test('a changed external shared schema reports the original resource and field',async()=>{
 const input=capture('3.0.4');
 input.resources[1].text='Item: &value {type: string, nullable: true}\nx-copy: *value\n';
 const result=await planMigration(input);
 assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
 assert(result.problems.some(value=>value.code==='edit.shared'&&value.resource===model&&value.pointer==='/Item/type'&&value.range[1]>value.range[0]),JSON.stringify(result.problems));
});

for(const [components,pointer]of [['components: &components {}\nx-copy: *components\n','/components'],
 ['components: {schemas: &schemas {}}\nx-copy: *schemas\n','/components/schemas']])
test(`migration retains ownership of an empty anchored destination ${pointer}`,async()=>{
 const text='openapi: 3.1.2\ninfo: {title: Destination, version: "1"}\npaths:\n  /x:\n    get:\n      responses:\n        "200":\n          description: Captured\n          content:\n            application/json:\n              schema:\n                type: object\n                $defs:\n                  Value:\n                    type: string\n'+components;
 const input={root,snapshot:pointer,targetVersion:'3.0.4',destination:'file:///reviewed/',resources:[{id:root,text,generation:1}]};
 const result=await planMigration(input);
 assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
 assert(result.problems.some(value=>value.code==='edit.shared'&&value.resource===root&&value.pointer===pointer&&value.range[1]>value.range[0]),JSON.stringify(result.problems));
 assert.equal(input.resources[0].text,text);
});
