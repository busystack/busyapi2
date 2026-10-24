const {test}=require('node:test');
const assert=require('node:assert/strict');
const {analyse}=require('./dist/model.cjs');
const {requestOperation,requestParameterValues,planResponseExample,semanticDiffCoverage,executionCaseValues,planExecutionEnvironment}=require('./dist/execution.cjs');
const {deriveBundle}=require('./dist/derived_bundle.cjs');

const id='file:///execution/openapi.json';
const document={
 openapi:'3.2.1',info:{title:'Execution',version:'1'},
 servers:[{url:'https://{tenant}.example.invalid/v1',variables:{tenant:{default:'demo'}}}],
 components:{
  securitySchemes:{bearer:{type:'http',scheme:'bearer'}},
  pathItems:{Shared:{get:{responses:{204:{description:'shared'}}}}},
  schemas:{Dynamic:{$dynamicAnchor:'node',type:'object',properties:{next:{$dynamicRef:'#node'}}}},
 },
 paths:{'/things/{id}':{
  parameters:[{name:'id',in:'path',required:true,style:'matrix',schema:{type:'string'}}],
  get:{
   security:[{bearer:[]}],
   parameters:[{name:'tag',in:'query',explode:true,schema:{type:'array',items:{type:'string'}}}],
   responses:{200:{description:'ok',content:{'application/json':{examples:{literal:{value:{$ref:'payload data',amount:9007199254740992}}}}}}},
  },
 }},
};
const text=JSON.stringify(document).replace('9007199254740992','9007199254740993');
const input={root:id,snapshot:'captured-snapshot',resources:[{id,text,generation:7,identity:'captured'}]};

test('request parameter scalar projection reuses strict CST numeric lexemes at every leaf',()=>{
 const result=requestParameterValues({values:{array:'[9007199254740993,123456789012345678901234567890,1.0000000000000000001,false,null,"雪"]',object:'{"n":1.234567890123456789e99,"text":"100"}'}});
 assert.deepEqual(result,{version:1,values:{array:['9007199254740993','123456789012345678901234567890','1.0000000000000000001',false,null,'雪'],object:{n:'1.234567890123456789e99',text:'100'}}});
 for(const raw of ['[1,]','{"n":1,"n":2}','NaN','undefined'])assert.throws(()=>requestParameterValues({values:{value:raw}}));
});

test('request projection keeps inherited semantics, locations and exact example text',()=>{
 const operation=analyse(input).operations[0];
 const result=requestOperation({...input,resource:id,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(result.version,1);assert.equal(result.snapshot,input.snapshot);assert.equal(result.family,'3.2');
 assert.deepEqual(result.parameters.map(parameter=>[parameter.name,parameter.in,parameter.style,parameter.explode]),[
  ['id','path','matrix',false],['tag','query','form',true],
 ]);
 assert.equal(result.servers[0].url,'https://{tenant}.example.invalid/v1');
 assert.deepEqual(result.security.requirements[0].schemes,['bearer']);
 const example=result.responses[0].content[0].example;
 assert.equal(example.name,'literal');
 assert.match(example.raw,/"\$ref":"payload data"/);
 assert.match(example.raw,/9007199254740993/);
 assert.deepEqual(example.source.range.length,2);
});

test('reviewed response example is a located exact transaction and never resolves data refs',()=>{
 const operation=analyse(input).operations[0];
 const plan=requestOperation({...input,resource:id,pointer:operation.pointer,occurrence:operation.occurrence});
 const media=plan.responses[0].content[0];
 const raw='{"$ref":"still response data","amount":9007199254740993}';
 const result=planResponseExample({...input,target:media.definition,raw,redacted:true});
 assert.equal(result.kind,'response-example');assert.equal(result.redacted,true);
 assert.ok(result.edits.length>0);assert.match(result.changes[0].after,/9007199254740993/);
 assert.match(result.changes[0].after,/still response data/);
 assert.equal(result.bodyIdentity.length,64);
});

test('semantic coverage names pinned comparator gaps instead of claiming completeness',()=>{
 const result=semanticDiffCoverage(input);
 assert.ok(result.dynamicReferences.length>0);
 assert.ok(result.reusablePathItems.length>0);
 assert.equal(result.coverage.dynamicReferences,'unclassified');
 assert.equal(result.coverage.reusablePathItems,'unclassified');
});

test('oasdiff input keeps exact embedded schemas while using a proved local entry reference',()=>{
 const root='file:///execution/multi.json',schema='file:///execution/schema.json';
 const rootText=JSON.stringify({openapi:'3.1.2',info:{title:'Diff input',version:'1'},paths:{'/items':{get:{responses:{200:{description:'ok',content:{'application/json':{schema:{$ref:'./schema.json'}}}}}}}}});
 const schemaText='{"type":"integer","enum":[9007199254740993]}';
 const result=deriveBundle({root,snapshot:'oasdiff-snapshot',consumer:'oasdiff',outputId:'file:///temporary/base.json',resources:[
  {id:root,text:rootText,generation:1,identity:'root'},
  {id:schema,text:schemaText,generation:1,identity:'schema'},
 ]});
 assert.equal(result.complete,true);
 assert.match(result.output.text,/"\$ref":"#\/components\/schemas\//);
 assert.match(result.output.text,/9007199254740993/);
 assert.doesNotMatch(result.output.text,/"\$ref":"file:\/\/\/execution\/schema\.json#/);
});

test('H05 H07 H08 H15 projection retains item constraints, scope alternatives and representation layers',()=>{
 const value={
   openapi:'3.2.1',info:{title:'Projection',version:'1'},
   components:{securitySchemes:{oauth:{type:'oauth2',flows:{clientCredentials:{tokenUrl:'https://auth.invalid/token',scopes:{read:'Read'}}}}}},
   paths:{'/items':{post:{
     security:[{oauth:['read']},{}],
     parameters:[{name:'color',in:'cookie',style:'cookie',schema:{type:'array',items:{type:'string'}},examples:{pair:{serializedValue:'color=red; color=blue'}}}],
     requestBody:{content:{'multipart/form-data':{examples:{parts:{dataValue:{metadata:{id:1},note:'fish&chips'}}},encoding:{metadata:{contentType:'application/json'}}}}},
     responses:{200:{description:'ok',content:{'application/jsonl':{schema:{type:'array'},itemSchema:{type:'object',required:['id'],properties:{id:{type:'integer'}}}}}}}
   }}}
 };
 const packet={...input,resources:[{...input.resources[0],text:JSON.stringify(value)}]};
 const operation=analyse(packet).operations[0];
 const plan=requestOperation({...packet,resource:id,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(plan.parameters[0].explode,true);
 assert.equal(plan.parameters[0].example.representation,'serialized');
 assert.equal(plan.parameters[0].example.level,'parameter');
 assert.deepEqual(plan.security.requirements.map(r=>r.scopes),[{oauth:['read']},{}]);
 assert.match(plan.responses[0].content[0].itemSchema.pointer,/itemSchema$/);
 assert.match(plan.responses[0].content[0].schema.pointer,/schema$/);
 assert.deepEqual(plan.requestBody.content[0].example.fields,{metadata:['{"id":1}'],note:['fish&chips']});
 assert.equal(plan.requestBody.content[0].example.level,'media');
});

test('T01 saved YAML case values retain exact numeric types and lexemes through the canonical CST',()=>{
 const {executionCaseValues}=require('./dist/execution.cjs');
 const numbers=['1.0000000000000000001','9007199254740993','123456789012345678901234567890','1e-100','1e100'];
 const source={id:'file:///execution/busyapi.yaml',text:`version: 1\ntests:\n - name: exact\n   parameters: {query: {values: [${numbers.join(',')}]}}\n   body: {mediaType: application/json, value: {values: [${numbers.join(',')}], text: "9007199254740993"}}\n`};
 const values=executionCaseValues({source,name:'exact'});
 assert.deepEqual(values.parameters['query\0values'],{text:'['+numbers.join(',')+']',json:true});
 assert.equal(values.body.text,'{"values":['+numbers.join(',')+'],"text":"9007199254740993"}');
});

test('U4 JSON formatting preserves exact numeric lexemes and treats data refs literally',()=>{
 const {inspectExecutionJson}=require('./dist/execution.cjs');
 const raw='{"n":1.0000000000000000001,"big":9007199254740993,"$ref":"literal","items":[1e100]}';
 const inspected=inspectExecutionJson({text:raw});
 assert.match(inspected.pretty,/1\.0000000000000000001/);
 assert.match(inspected.pretty,/9007199254740993/);
 assert.match(inspected.pretty,/1e100/);
 assert.equal(inspected.entries[2].text,'"literal"');
 assert.throws(()=>inspectExecutionJson({text:'{"n":1,}'}));
});


test('H07 YAML scalar nodes keep literal media strings and form fields',()=>{
 const text='openapi: 3.2.1\ninfo: {title: Test, version: "1"}\npaths: {/x: {post: {requestBody: {content: {text/plain: {example: hello}, application/x-www-form-urlencoded: {examples: {fields: {dataValue: {note: "fish&chips", amount: 1.0000000000000000001}}}}}}, responses: {"204": {description: ok}}}}}\n';
 const packet={root:id,snapshot:'yaml-scalar',resources:[{id:id.replace('.json','.yaml'),text,generation:1,identity:'a'}]};packet.root=packet.resources[0].id;
 const operation=analyse(packet).operations[0];const plan=requestOperation({...packet,resource:packet.root,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(plan.requestBody.content[0].example.text,'hello');
 assert.deepEqual(plan.requestBody.content[1].example.fields,{note:['fish&chips'],amount:['1.0000000000000000001']});
 const {executionCaseValues}=require('./dist/execution.cjs');
 const values=executionCaseValues({source:{id:'file:///busyapi.yaml',text:'version: 1\ntests: [{name: raw, parameters: {query: {word: hello}}, body: {mediaType: text/plain, value: hello}}]\n'},name:'raw'});
 assert.deepEqual(values.parameters['query\0word'],{text:'hello',json:false});assert.deepEqual(values.body,{text:'hello',json:false});
 const nested=text.replace('note: "fish&chips"','note: {inner: "fish&chips"}');
 const nestedPacket={...packet,resources:[{...packet.resources[0],text:nested}]};
 const nestedPlan=requestOperation({...nestedPacket,resource:packet.root,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.match(nestedPlan.requestBody.content[1].example.conversionError,/nested|structured/i);
 const nestedJson=text.replace('text/plain: {example: hello}', 'application/json: {example: {outer: {inner: 1}}}, text/plain: {example: hello}');
 const jsonPlan=requestOperation({...packet,resources:[{...packet.resources[0],text:nestedJson}],resource:packet.root,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(jsonPlan.requestBody.content.find(m=>m.mediaType==='application/json').example.conversionError,undefined);
});

test('T01 saved exact values retain the existing numeric work bound before any request',()=>{
 const text='version: 1\ntests: [{name: bounded, body: {mediaType: application/json, value: '+ '1'.repeat(4097) +'}}]\n';
 assert.throws(()=>executionCaseValues({source:{id:'file:///project/busyapi.yaml',text},name:'bounded'}),error=>error.code==='limit.schema.numeric'&&error.message.includes('/tests/0/body/value')&&error.range[0]>0);
});

test('U3 configuration setup patches owned leaves and preserves exact unrelated CST values',()=>{
 const text="version: 1\nenvironments:\n  local:\n    baseUrl: http://old.example.test\n    x-extra: {exact: 1.0000000000000000001}\n    authentication:\n      alternative: 0\n      x-auth: {exact: 9007199254740993}\n      schemes:\n        access: {tokenRef: old-reference, x-scheme: 123456789012345678901234567890}\n    tls: {caFile: ca.pem, clientKeyPasswordRef: old-reference, x-tls: keep}\n";
 const result=planExecutionEnvironment({root:'file:///project/openapi.yaml',snapshot:'captured',source:{id:'file:///project/busyapi.yaml',generation:1,text},name:'local',definition:{baseUrl:'http://new.example.test',variables:{},headers:{},authentication:{alternative:0,schemes:{access:{tokenRef:'new-reference'}}},tls:{caFile:'ca.pem'}}});
 const after=result.changes[0].after;
 for(const value of ['1.0000000000000000001','9007199254740993','123456789012345678901234567890','x-tls: keep','http://new.example.test','new-reference'])assert.ok(after.includes(value),value);
 assert.ok(!after.includes('clientKeyPasswordRef'));
});

test('F04A canonical saved inputs traverse aliases at every structural level without rounding',()=>{
 const aliases=`version: 1
x-number: &number 1.0000000000000000001
x-large: &large 9007199254740993
x-object: &object {decimal: *number, large: *large}
x-query: &query {q: *large, nested: *object}
x-parameters: &parameters {query: *query}
x-body: &body {value: *object}
x-case: &case {name: exact, parameters: *parameters, body: *body}
tests: [*case]
`;
 const inline='version: 1\ntests: [{name: exact, parameters: {query: {q: 9007199254740993, nested: {decimal: 1.0000000000000000001, large: 9007199254740993}}}, body: {value: {decimal: 1.0000000000000000001, large: 9007199254740993}}}]\n';
 const project=text=>executionCaseValues({source:{id:'file:///execution/busyapi.yaml',text},name:'exact'});
 assert.deepEqual(project(aliases),project(inline));
 assert.equal(project(aliases).parameters['query\0q'].text,'9007199254740993');
 assert.throws(()=>project(aliases.replace('1.0000000000000000001','1'.repeat(4097))),e=>e.code.startsWith('limit.')&&e.range?.length===2);
});

test('F04B aliased field maps arrays objects and nested items preserve form conversion semantics',()=>{
 const project=(media,body)=>{
 const rid='file:///execution/alias.yaml';
 const text=`openapi: 3.2.1
info: {title: Aliases, version: '1'}
x-colors: &colors [red, blue]
x-number: &number 1.0000000000000000001
x-item: &item {n: *number}
x-items: &items [*item]
x-fields: &fields {color: *colors, n: *number}
paths:
  /x:
    post:
      requestBody:
        content:
          ${media}:
            examples: {sample: {dataValue: ${body}}}
      responses: {'204': {description: ok}}
`;
 const packet={root:rid,snapshot:'aliases',resources:[{id:rid,text,generation:1}]};
 const operation=analyse(packet).operations[0];
 return requestOperation({...packet,resource:rid,pointer:operation.pointer,occurrence:operation.occurrence}).requestBody.content[0].example;
 };
 for(const media of ['application/x-www-form-urlencoded','multipart/form-data']){
  const aliased=project(media,'*fields'),inline=project(media,'{color: [red, blue], n: 1.0000000000000000001}');
  assert.deepEqual(aliased.fields,inline.fields);
  assert.deepEqual(aliased.fields,{color:['red','blue'],n:['1.0000000000000000001']});
  for(const [alias,plain] of [['{field: *item}','{field: {n: 1.0000000000000000001}}'],['{field: *items}','{field: [{n: 1.0000000000000000001}]}']]){
   const a=project(media,alias),b=project(media,plain);
   assert.deepEqual(a.fields,b.fields);assert.equal(a.compositeFields,true);assert.equal(a.conversionError,b.conversionError);assert(a.conversionError);
  }
 }
});
