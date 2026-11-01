const {test}=require('node:test');
const assert=require('node:assert/strict');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} enum aliases retain exact scalar and nested numeric provenance`,async()=>{
 const schemas=version==='2.0'?'definitions':'components/schemas',prefix='/'+schemas,root='file:///enum-provenance/api.'+format;
 const enumText='[9007199254740993.00, {"n":9007199254740993.00,"$ref":"./literal-data.json"}]';
 const text=format==='json'?'{"'+(version==='2.0'?'swagger':'openapi')+'":"'+version+'","info":{"title":"Exact aliases","version":"1"},"paths":{},"'+(version==='2.0'?'definitions':'components')+'":'+(version==='2.0'?'':'{"schemas":')+'{"A":{"enum":'+enumText+'},"B":{"enum":'+enumText+'}}'+(version==='2.0'?'':'}')+'}':
  (version==='2.0'?'swagger':'openapi')+': "'+version+'"\ninfo: {title: Exact aliases, version: "1"}\npaths: {}\n'+(version==='2.0'?'definitions:\n':'components:\n  schemas:\n')+(version==='2.0'?'  ':'    ')+'A:\n'+(version==='2.0'?'    ':'      ')+'enum: &values '+enumText+'\n'+(version==='2.0'?'  ':'    ')+'B:\n'+(version==='2.0'?'    ':'      ')+'enum: *values\n';
 const runtimeInstances=['A','B'].flatMap(name=>[
  ['9007199254740993',true],['9007199254740992',false],
  ['{"n":9007199254740993,"$ref":"./literal-data.json"}',true],['{"n":9007199254740992,"$ref":"./literal-data.json"}',false],
 ].map(([text,valid],index)=>({subject:'request-parameter',location:name+index,text,schema:{resource:root,pointer:prefix+'/'+name},valid})));
 const result=await evaluateSchemas({root,snapshot:'enum-provenance',resources:[{id:root,text,generation:1}],runtimeInstances});
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.deepEqual(result.runtimeEvaluations.map(value=>value.valid),runtimeInstances.map(value=>value.valid),JSON.stringify(result.runtimeFindings));
});
