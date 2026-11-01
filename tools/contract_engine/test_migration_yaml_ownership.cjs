const assert=require('node:assert/strict');
const {test}=require('node:test');
const {planMigration}=require('./dist/migration.cjs');
const {analyse}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');

function delivered(review){return {root:review.outputRoot,snapshot:'cold:'+review.identity,
 resources:review.outputs.map(output=>({id:output.id,text:output.text,generation:0}))};}
async function schemaValues(input,resource,pointer){
 const checked=await evaluateSchemas({...input,runtimeInstances:['null','false','0','"café"','{}','[]'].map(text=>({
  subject:'response-body',location:'application/json',text,schema:{resource,pointer},
 }))});
 assert.equal(checked.complete,true,JSON.stringify(checked.findings));
 assert(checked.runtimeEvaluations.every(value=>value.complete));return checked.runtimeEvaluations.map(value=>value.valid);
}

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
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.producerVersion,'37');
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
])test(`changed shared schema gets independent migration ownership ${version} → ${targetVersion}`,async()=>{
 const text='openapi: "'+version+'"\ninfo: {title: Shared, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    '+body.split('\n')[0]+'\n'+body.split('\n')[1]+'\n';
 const input={root,snapshot:'shared',targetVersion,destination:'file:///reviewed/',resources:[{id:root,text,generation:1}]};
 const result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.status,'faithfully-convertible');
 const output=delivered(result),doc=new SourceDocument(result.outputs.find(value=>value.id===result.outputRoot).text,result.outputRoot);
 assert.equal(doc.dataJson('/x-other'),new SourceDocument(text,root).dataJson('/x-other'));
 assert.equal(analyse(output).status,'complete');
 assert.deepEqual(await schemaValues(output,output.root,'/components/schemas/Value'),await schemaValues(input,root,'/components/schemas/Value'));
 assert(result.presentationChanges.some(change=>change.resource===root&&change.pointer==='/x-other'));
 assert.equal(input.resources[0].text,text);
});

for(const [version,targetVersion]of [['3.0.0','3.0.4'],['3.1.0','3.1.2'],['3.2.0','3.2.1']])
test(`a changed shared patch declaration retains other consumers ${version} → ${targetVersion}`,async()=>{
 const input=capture(version,'x-version: *version\r\n');
 input.resources[0].text=input.resources[0].text.replace('openapi: "'+version+'"','openapi: &version "'+version+'"');
 const original=input.resources[0].text;
 const result=await planMigration({...input,targetVersion});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);
 const output=new SourceDocument(result.outputs.find(value=>value.id===result.outputRoot).text,result.outputRoot);
 assert.equal(output.dataNode('/openapi').value,targetVersion);assert.equal(output.dataNode('/x-version').value,version);
 assert(result.presentationChanges.some(value=>value.resource===root&&value.pointer==='/openapi'));
 assert(result.presentationChanges.some(value=>value.resource===root&&value.pointer==='/x-version'));
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
])test(`migration specializes a changed ${label} and preserves literal bindings`,async()=>{
 const input={root,snapshot:label,targetVersion,destination:'file:///reviewed/',resources:[{id:root,text,generation:1},
  ...(label==='relocated file locator'?[{id:model,text:'Item: {type: string}\n',generation:2}]:[])]};
 const original=input.resources.map(value=>value.text),result=await planMigration(input);
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);
 const output=new SourceDocument(result.outputs.find(value=>value.id===result.outputRoot).text,result.outputRoot),before=new SourceDocument(text,root);
 const literal=label==='relocated file locator'?'/x-reference':'/x-copy';
 assert.equal(output.dataJson(literal),before.dataJson(literal));
 assert.equal(analyse(delivered(result)).status,'complete');
 assert(result.presentationChanges.some(value=>value.resource===root&&value.pointer===literal));
 if(label==='anchored reusable map')assert.equal(output.dataNode('/components/schemas/Value/type').value,'string');
 if(label==='copied body schema')assert(output.dataNode('/paths/~1x/post/requestBody'));
 if(label==='relocated file locator'){
  const reference=analyse(delivered(result)).references.find(reference=>reference.pointer==='/components/schemas/Value/$ref');
  assert.equal(reference.resolution,'resolved');assert.equal(reference.targetPointer,'/Item');
  assert.notEqual(reference.value,before.dataNode(pointer).value);
 }
 assert.deepEqual(input.resources.map(value=>value.text),original);
});

test('a changed external shared schema retains its literal owner and validation behavior',async()=>{
 const input=capture('3.0.4');
 input.resources[1].text='Item: &value {type: string, nullable: true}\nx-copy: *value\n';
 const result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));
 const output=delivered(result),destination=result.changes.find(change=>change.resource===model).destination;
 const after=new SourceDocument(result.outputs.find(value=>value.id===destination).text,destination);
 assert.equal(after.dataJson('/x-copy'),new SourceDocument(input.resources[1].text,model).dataJson('/x-copy'));
 assert.deepEqual(await schemaValues(output,destination,'/Item'),await schemaValues(input,model,'/Item'));
 assert(result.presentationChanges.some(value=>value.resource===model&&value.pointer==='/Item'));
 assert.equal(input.resources[1].text,'Item: &value {type: string, nullable: true}\nx-copy: *value\n');
});

for(const [components,pointer]of [['components: &components {}\nx-copy: *components\n','/components'],
 ['components: {schemas: &schemas {}}\nx-copy: *schemas\n','/components/schemas']])
test(`migration retains ownership of an empty anchored destination ${pointer}`,async()=>{
 const text='openapi: 3.1.2\ninfo: {title: Destination, version: "1"}\npaths:\n  /x:\n    get:\n      responses:\n        "200":\n          description: Captured\n          content:\n            application/json:\n              schema:\n                type: object\n                $defs:\n                  Value:\n                    type: string\n'+components;
 const input={root,snapshot:pointer,targetVersion:'3.0.4',destination:'file:///reviewed/',resources:[{id:root,text,generation:1}]};
 const result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));
 const output=new SourceDocument(result.outputs.find(value=>value.id===result.outputRoot).text,result.outputRoot);
 assert.equal(output.dataJson('/x-copy'),new SourceDocument(text,root).dataJson('/x-copy'));
 assert.equal(output.dataNode('/components/schemas').children.size,1);
 assert.equal(analyse(delivered(result)).status,'complete');
 assert(result.presentationChanges.some(value=>value.resource===root&&value.pointer===pointer));
 assert.equal(input.resources[0].text,text);
});
