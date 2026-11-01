const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','2.0','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function fixture(version,format,mediaType,example,field='value'){
 const root='file:///p/api.'+format,schema={type:'object',properties:{id:{type:'integer',enum:['EXACT']}},required:['id']};
 const media={schema,...(field==='example'?{example}:{examples:{Literal:{[field]:example}}})};
 const operation=version==='2.0'?{produces:[mediaType],responses:{200:{description:'Read',schema,examples:{[mediaType]:example}}}}:{requestBody:{content:{[mediaType]:media}},responses:{204:{description:'None'}}};
 const value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Keep 雪',version:'api-version'},paths:{'/items':{post:operation}},'x-data':{$ref:'literal',serializedValue:0}};
 const text=(format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll('"EXACT"','9007199254740993').replaceAll('EXACT','9007199254740993');
 return {root,snapshot:'literal-media',resources:[{id:root,text,generation:2}]};
}
for(const version of versions)for(const format of ['yaml','json']){
 for(const field of version==='2.0'?['value']:['value','example']){
  test(`${version} ${format} ${field} literal XML is not JSON schema data`,async()=>{
   const input=fixture(version,format,'application/xml','<item><id>9007199254740993</id></item>',field),before=input.resources[0].text;
   const result=await evaluateSchemas(input);
   assert.equal(result.complete,false,JSON.stringify(result.findings));
   assert(!result.findings.some(value=>value.code==='example.schema.incompatible'),JSON.stringify(result.findings));
   assert(result.findings.some(value=>value.code==='example.serialization.incomplete'));
   assert.equal(input.resources[0].text,before);
  });
  test(`${version} ${format} ${field} literal form uses the captured media codec`,async()=>{
   const input=fixture(version,format,'application/x-www-form-urlencoded','id=9007199254740993',field),before=input.resources[0].text;
   const result=await evaluateSchemas(input);
   assert.equal(result.complete,true,JSON.stringify(result.findings));
   assert(!result.findings.some(value=>value.code==='example.schema.incompatible'),JSON.stringify(result.findings));
   assert.equal(result.serializedEvaluations.length,1,JSON.stringify(result));assert.equal(result.serializedEvaluations[0].valid,true,JSON.stringify(result.findings));
   if(version!=='2.0'){
    const projected=requestOperation({...input,resource:input.root,pointer:'/paths/~1items/post'}),example=projected.requestBody.content[0].example;
    assert.equal(example.representation,'serialized');assert.equal(example.raw,'id=9007199254740993');
   }
   assert.equal(input.resources[0].text,before);
  });
 }
 test(`${version} ${format} JSON literal string is not silently parsed as JSON object data`,async()=>{
  const input=fixture(version,format,'application/json','{"id":9007199254740993}'),result=await evaluateSchemas(input);
  assert.equal(result.complete,true);assert(result.findings.some(value=>value.code==='example.schema.incompatible'));
  assert.equal(result.serializedEvaluations.length,0);
 });
}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} serialized media cannot infer a JSON string schema`,()=>{
 const {suggestSchema}=require('./dist/schema_suggestion.cjs');
 const input=fixture(version,format,'application/xml','<item/>');
 const pointer=version==='2.0'?'/paths/~1items/post/responses/200/examples/application~1xml':'/paths/~1items/post/requestBody/content/application~1xml/examples/Literal/value';
 assert.throws(()=>suggestSchema({...input,resource:input.root,pointer}),error=>error.code==='suggest.serialized');
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} explicit dataValue remains schema-ready`,()=>{
 const {suggestSchema}=require('./dist/schema_suggestion.cjs');
 const input=fixture(version,format,'application/xml','<item/>','dataValue');
 const result=suggestSchema({...input,resource:input.root,pointer:'/paths/~1items/post/requestBody/content/application~1xml/examples/Literal/dataValue'});
 assert.deepEqual(result.schema,{type:'string'});
});
for(const format of ['yaml','json'])for(const mixed of [false,true])test(`reusable media ${format} retains every literal interpretation mixed=${mixed}`,async()=>{
 const root='file:///p/reusable.'+format,media={schema:{type:'object',properties:{id:{type:'integer',enum:[0]}},required:['id']},examples:{Literal:{value:'id=0'}}};
 const content={'application/x-www-form-urlencoded':{$ref:'#/components/mediaTypes/Shared'},...(mixed?{'application/json':{$ref:'#/components/mediaTypes/Shared'}}:{})};
 const value={openapi:'3.2.1',info:{title:'Keep',version:'api'},paths:{'/items':{post:{requestBody:{content},responses:{204:{description:'None'}}}}},components:{mediaTypes:{Shared:media}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),result=await evaluateSchemas({root,snapshot:'reusable-literal',resources:[{id:root,text,generation:1}]});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,1);assert.equal(result.serializedEvaluations[0].valid,true,JSON.stringify(result));
 assert.equal(result.findings.filter(f=>f.code==='example.schema.incompatible').length,mixed?1:0);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} shared literal Example chains retain source provenance`,async()=>{
 const root='file:///p/root.'+format,shared='file:///p/shared.'+format;
 const value={openapi:version,info:{title:'Keep',version:'api'},paths:{'/items':{post:{requestBody:{content:{'application/x-www-form-urlencoded':{schema:{type:'object',properties:{id:{type:'integer',enum:[0]}},required:['id']},examples:{Literal:{$ref:'./shared.'+format+'#/First'}}}}},responses:{204:{description:'None'}}}}}};
 const render=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);
 const resources=[{id:root,text:render(value),generation:1},{id:shared,text:render({First:{$ref:'#/Actual'},Actual:{value:'id=0'}}),generation:2}],before=resources.map(r=>r.text);
 const result=await evaluateSchemas({root,snapshot:'shared-literal',resources});assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.equal(result.serializedEvaluations.length,1);const proof=result.serializedEvaluations[0];assert.equal(proof.resource,shared);assert.equal(proof.pointer,'/Actual/value');assert.equal(proof.valid,true);assert.equal(proof.field,'value');assert.deepEqual(resources.map(r=>r.text),before);
});
for(const format of ['yaml','json'])for(const schema of [undefined,{type:'string'}])test(`unbound reusable literal ${format} remains incomplete schema=${!!schema}`,async()=>{
 const root='file:///p/unbound.'+format,value={openapi:'3.2.1',info:{title:'Keep',version:'1'},paths:{},components:{mediaTypes:{Shared:{...(schema?{schema}:{}),examples:{Value:{value:'id=0'}}}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),result=await evaluateSchemas({root,snapshot:'unbound-literal',resources:[{id:root,text,generation:1}]});
 assert.equal(result.complete,false);assert(!result.findings.some(f=>f.code==='example.schema.incompatible'));assert(result.findings.some(f=>f.code==='example.serialization.incomplete'));
});
