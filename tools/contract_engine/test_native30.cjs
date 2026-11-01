const assert = require('node:assert/strict');
const {test} = require('node:test');
const YAML = require('yaml');
const {analyse, createGraph, inspect, propose} = require('./dist/model.cjs');
const {evaluateSchemas} = require('./dist/schema_evaluation.cjs');
const {referenceDocument} = require('./dist/reference_projection.cjs');
const {assistSource} = require('./dist/source_assistance.cjs');
const {deriveBundle} = require('./dist/derived_bundle.cjs');
const {requestOperation} = require('./dist/execution.cjs');
const {SourceDocument} = require('./dist/document.cjs');
const {planRename} = require('./dist/refactoring.cjs');
const versions = ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'];
const contract = (version, schema = {type:'string',nullable:true}) => ({
  openapi:version,info:{title:'Native 雪😀',version:'api-version'},servers:[{url:'https://api.invalid/v1'}],
  paths:{'/pets/{id}':{parameters:[{name:'id',in:'path',required:true,schema:{type:'integer'}}],get:{
    operationId:'getPet',parameters:[{name:'q',in:'query',schema:{type:'array',items:{type:'string'}},style:'form',explode:false}],
    responses:{200:{description:'Pet',content:{'application/json':{schema:{$ref:'#/components/schemas/Pet'},examples:{empty:{value:null},text:{value:'pet'}}}}}},
  }}},components:{schemas:{Pet:schema},securitySchemes:{Key:{type:'apiKey',in:'header',name:'X-Key'}}},security:[{Key:[]}],
  'x-preserved':{number:111,'$ref':'literal',zero:0,empty:'',false:false},
});
function capture(value,json=true,extra=[]) {
  const root='file:///approved/native30.'+(json?'json':'yaml');
  const text=(json?JSON.stringify(value):'# Keep source\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll('111','9007199254740993.00');
  return {root,resource:root,snapshot:'native30',resources:[{id:root,text,generation:1,identity:'input'},...extra]};
}
for(const version of versions)for(const json of [true,false])test(`native ${version} ${json?'JSON':'YAML'} authoring, reference, assistance, execution and bundle`,async()=>{
  const input=capture(contract(version),json),before=input.resources[0].text;
  const result=analyse(input);
  assert.equal(result.status,'complete',JSON.stringify(result.findings));
  assert.equal(result.specification.family,'3.0');assert.equal(result.specification.declaredVersion,version);
  assert(!result.info.fields.some(field=>field.name==='summary'));
  assert.equal(result.operations.length,1);assert.equal(result.operations[0].family,'3.0');
  const pointer='/components/schemas/Pet',page=inspect({...input,pointer});
  assert(page.fields.some(f=>f.name==='nullable'&&f.type==='boolean'));
  assert(page.fields.some(f=>f.name==='exclusiveMinimum'&&f.type==='boolean'));
  assert(!page.fields.some(f=>['$id','$schema','$defs','const','prefixItems'].includes(f.name)));
  assert(!page.fields.find(f=>f.name==='type').options.includes('null'));
  const target={resource:input.root,generation:1,pointer,range:page.range,expected:before.slice(...page.range)};
  const plan=propose({...input,target,actions:[{kind:'set',pointer:pointer+'/nullable',value:false}]});
  let after=before;for(const edit of [...plan.edits].sort((a,b)=>b.start-a.start))after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
  assert.equal(after,before.replace(json?'"nullable":true':'nullable: true',json?'"nullable":false':'nullable: false'));
  assert.equal(input.resources[0].text,before);
  const caret=before.indexOf('nullable')+3;
  const help=assistSource({...input,caret,action:'help'});
  assert.equal(help.help.dialect,'https://spec.openapis.org/oas/3.0/dialect');
  assert(help.help.standard.includes('/v3.0.4.html#schema-object'));
  const projection=referenceDocument(input);assert.equal(projection.complete,true);
  assert(projection.sections.some(s=>s.kind==='schema'&&s.source.pointer===pointer));
  const operation=result.operations[0],execution=requestOperation({...input,pointer:operation.pointer,occurrence:operation.occurrence});
  assert.equal(execution.parameters.find(p=>p.name==='id').required,true);
  assert.equal(execution.parameters.find(p=>p.name==='q').explode,false);
  assert.equal(execution.servers[0].url,'https://api.invalid/v1');
  assert.equal(execution.security.schemes.Key.type,'apiKey');
  const evaluated=await evaluateSchemas(input);assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));
  assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,true]);
  const bundle=deriveBundle({...input,outputId:'https://output.invalid/api.json'});
  assert.equal(JSON.parse(bundle.output.text).openapi,version);
  assert(bundle.output.text.includes('9007199254740993.00'));
  assert.equal(analyse({root:bundle.output.id,snapshot:'bundle',resources:[{id:bundle.output.id,text:bundle.output.text,generation:0}]}).status,'complete');
});

test('3.0 nullability depends on local type and does not override enum, composition or Reference Objects',async()=>{
  const schemas=[
    [{type:'string',nullable:true},[true,true,false]],
    [{nullable:true,enum:['x']},[false,true,false]],
    [{type:'string',nullable:true,enum:['x']},[false,true,false]],
    [{type:'string',nullable:true,allOf:[{type:'string'}]},[false,true,false]],
    [{$ref:'#/components/schemas/Actual',nullable:true,type:'integer',properties:{ignored:{$ref:'missing.json'}}},[false,true,false]],
  ];
  for(const [schema,expected]of schemas){
    const api=contract('3.0.4',schema);api.components.schemas.Actual={type:'string'};
    const input=capture(api),result=await evaluateSchemas({...input,runtimeInstances:['null','"x"','1'].map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer:'/components/schemas/Pet'}}))});
    assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.runtimeEvaluations.map(r=>r.valid),expected);
    if(schema.$ref)assert(!createGraph(input).graph.references.some(r=>r.value==='missing.json'));
  }
});
test('3.0 exclusive boolean bounds and integer/default checks retain exact decimal meaning',async()=>{
  const text='{"openapi":"3.0.4","info":{"title":"Exact","version":"1"},"paths":{},"components":{"schemas":{"N":{"type":"integer","minimum":9007199254740993,"exclusiveMinimum":true},"Tiny":{"type":"integer","default":1e-999}}}}';
  const root='file:///approved/exact.json',input={root,snapshot:'exact30',resources:[{id:root,text,generation:1}]};
  assert(analyse(input).findings.some(f=>f.code==='schema.default.type'));
  const result=await evaluateSchemas({...input,runtimeInstances:['9007199254740992','9007199254740993','9007199254740994','9007199254740993.1'].map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:root,pointer:'/components/schemas/N'}}))});
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.runtimeEvaluations.map(r=>r.valid),[false,false,true,false]);
});
for(const schema of [true,false,{type:['string','null']},{type:'null'},{type:'array'},{type:'number',exclusiveMinimum:1},{const:1},{type:'string',$schema:'https://json-schema.org/draft/2020-12/schema'},{readOnly:true,writeOnly:true},{type:'string',default:1},{allOf:[]}])test(`3.0 rejects wrong-family schema ${JSON.stringify(schema)}`,async()=>{
  const input=capture(contract('3.0.4',schema));
  const structural=analyse(input),semantic=await evaluateSchemas(input);
  assert(structural.findings.some(f=>f.severity==='error')||semantic.findings.some(f=>f.severity==='error'));
  assert(!semantic.runtimeEvaluations.some(r=>r.valid));
});
test('3.0 additionalProperties boolean remains valid while standalone boolean schemas are invalid',async()=>{
  const input=capture(contract('3.0.4',{type:'object',additionalProperties:false}));
  assert.equal(analyse(input).status,'complete');assert.equal((await evaluateSchemas(input)).complete,true);
  assert(!createGraph(input).graph.scopes.has(input.root+'#/components/schemas/Pet/additionalProperties'));
});
test('3.0 request/response required properties honor readOnly/writeOnly without mutating schema',async()=>{
  const input=capture(contract('3.0.4',{type:'object',required:['id','secret','name'],properties:{id:{type:'integer',readOnly:true},secret:{type:'string',writeOnly:true},name:{type:'string'}}}));
  const result=await evaluateSchemas({...input,runtimeInstances:[
    ['request-body','{"secret":"s","name":"n"}'],['response-body','{"id":1,"name":"n"}'],
    ['request-body','{"name":"n"}'],['response-body','{"name":"n"}'],
  ].map(([subject,text])=>({subject,text,location:'application/json',schema:{resource:input.root,pointer:'/components/schemas/Pet'}}))});
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.runtimeEvaluations.map(r=>r.valid),[true,true,false,false]);
});
test('3.0 cross-file chained/recursive references and escaped pointers bundle into native components',async()=>{
  const model='file:///approved/model.yaml',api=contract('3.0.4',{$ref:'model.yaml#/a~1b'});
  const input=capture(api,false,[{id:model,text:'a/b: {type: object, properties: {next: {$ref: "#/a~1b"}}}',generation:2,identity:'model'}]);
  assert.equal(analyse(input).status,'complete');assert.equal((await evaluateSchemas(input)).complete,true);
  const bundled=deriveBundle({...input,outputId:'https://output.invalid/recursive.json'});
  const value=JSON.parse(bundled.output.text);assert.equal(value.openapi,'3.0.4');assert(!bundled.output.text.includes('"$id"'));assert(!bundled.output.text.includes('"$defs"'));
  const after=analyse({root:bundled.output.id,snapshot:'after',resources:[{id:bundled.output.id,text:bundled.output.text,generation:0}]});assert.equal(after.status,'complete',JSON.stringify(after.findings));
});
test('3.0 semantic rename repairs only contract references and keeps literal payload keys',()=>{
  const input=capture(contract('3.0.4')),pointer='/components/schemas/Pet',doc=new SourceDocument(input.resources[0].text,input.root),node=doc.node(pointer);
  const result=planRename({...input,contexts:[{root:input.root,resources:[input.root]}],target:{root:input.root,resource:input.root,generation:1,pointer,range:node.range,expected:doc.text.slice(...node.range)},name:'Renamed'});
  assert(result.changes[0].after.includes('#/components/schemas/Renamed'));assert(result.changes[0].after.includes('"$ref":"literal"'));
});
test('3.0 shared external Path Items retain one operation owner and native reference semantics in bundles',()=>{
  const api=contract('3.0.4');
  api.paths={'/one':{$ref:'paths.yaml#/Shared'},'/two':{$ref:'paths.yaml#/Shared'}};
  api.components['x-busyapi-path-items']={keep:'literal storage'};
  const input=capture(api,false,[{id:'file:///approved/paths.yaml',text:'Shared: {get: {operationId: shared, responses: {204: {description: Empty}}}}',generation:2}]);
  const before=analyse(input);assert.equal(before.status,'complete');assert.equal(before.operations.length,2);
  const bundle=deriveBundle({...input,outputId:'https://output.invalid/paths.json'}),value=JSON.parse(bundle.output.text);
  assert.deepEqual(value.components['x-busyapi-path-items'],{keep:'literal storage'});
  assert(!Object.hasOwn(value.components,'pathItems'));
  const after=analyse({root:bundle.output.id,snapshot:'after',resources:[{id:bundle.output.id,text:bundle.output.text,generation:0}]});
  assert.equal(after.status,'complete',JSON.stringify(after.findings));assert.equal(after.operations.length,2);
  assert.equal(after.operations[0].pointer,after.operations[1].pointer);
});
test('changing declarations never infers a successful family from familiar fields',()=>{
  for(const declaration of [{},{openapi:3.0},{openapi:'3.0'},{openapi:'4.0.0'},{openapi:'3.0.4',swagger:'2.0'}]){
    const input=capture({...declaration,info:{title:'Version',version:'3.2.1'},paths:{}}),result=analyse(input);
    assert.equal(result.complete,false);assert(result.findings.some(f=>f.code.startsWith('version.')));
    assert.throws(()=>createGraph(input),e=>e.code.startsWith('version.'));
  }
});
test('security and Example Object relationships use the selected family',()=>{
  for(const version of ['3.0.4','3.1.2','3.2.1']) {
    const api=contract(version,{type:'string'});api.security=[{Key:['role']}];
    const input=capture(api),result=analyse(input);
    assert.equal(result.findings.some(f=>f.code==='security.scopes.empty'),version==='3.0.4');
    api.security=[{Key:[]}];api.components.examples={Value:{value:0,externalValue:'example.json'}};
    assert(analyse(capture(api)).findings.some(f=>f.code==='example.representations.exclusive'));
    if(version==='3.2.1') {
      api.components.examples={Value:{dataValue:0,serializedValue:'0'}};
      assert(!analyse(capture(api)).findings.some(f=>f.code==='example.representations.exclusive'));
    }
  }
});
test('modern explicit restricted dialect selection remains accurately unsupported',async()=>{
  const api=contract('3.1.2',{type:'string'});api.jsonSchemaDialect='https://spec.openapis.org/oas/3.0/dialect';
  const input=capture(api),result=await evaluateSchemas({...input,runtimeInstances:[{subject:'response-body',location:'application/json',text:'"text"',schema:{resource:input.root,pointer:'/components/schemas/Pet'}}]});
  assert.equal(result.complete,false);assert(!result.runtimeEvaluations.some(r=>r.complete&&r.valid));
});
test('3.0 removing the last required property removes the forbidden empty required array',()=>{
  const api=contract('3.0.4',{type:'object',properties:{name:{type:'string'}},required:['name']}),input=capture(api,false),pointer='/components/schemas/Pet',doc=new SourceDocument(input.resources[0].text,input.root),node=doc.node(pointer);
  const result=propose({...input,target:{resource:input.root,generation:1,pointer,range:node.range,expected:doc.text.slice(...node.range)},actions:[{kind:'setRequired',pointer,name:'name',required:false}]});
  let text=doc.text;for(const edit of [...result.edits].sort((a,b)=>b.start-a.start))text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
  assert(!new SourceDocument(text,input.root).node(pointer).children.has('required'));
  assert.equal(analyse({...input,resources:[{...input.resources[0],text}]}).status,'complete');
});
test('3.0 strict JSON object collections never invoke prototype methods and check semantic uniqueness',()=>{
  const api=contract('3.0.4'),operation=api.paths['/pets/{id}'].get;
  operation.parameters=Array.from({length:261},(_,index)=>({name:'p'+index,in:'query',schema:{type:'string'}}));
  api.tags=[{name:'one'},{name:'two'}];
  let result=analyse(capture(api));assert.equal(result.status,'complete',JSON.stringify(result.findings));
  operation.parameters.push({...operation.parameters[0],description:'different object, same parameter identity'});
  api.tags.push({name:'one',description:'different object, same tag identity'});
  result=analyse(capture(api));assert.equal(result.status,'invalid');
  assert(result.findings.some(f=>f.code==='parameter.duplicate'));assert(result.findings.some(f=>f.code==='tag.name.duplicate'));
});
