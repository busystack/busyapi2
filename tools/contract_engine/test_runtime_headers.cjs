const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const patches=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','2.0','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function input(version,format,headers,shared){
 const root='file:///runtime-headers/api.'+format,fragment='file:///runtime-headers/shared.'+format;
 const document={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Captured header wire',version:'api-version'},paths:{'/data':{get:{responses:{204:{description:'Header values',headers}}}}}};
 const encode=value=>(format==='yaml'?YAML.stringify(value):JSON.stringify(value)).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 const resources=[{id:root,text:encode(document),generation:7},...(shared?[{id:fragment,text:encode(shared),generation:5}]:[])];
 const wire=(name,values,location=name)=>({subject:'response-header',location,text:'',header:{resource:root,pointer:'/paths/~1data/get/responses/204/headers/'+name.replaceAll('~','~0').replaceAll('/','~1'),name,values}});
 return {root,snapshot:'captured-native-header',resources,wire};
}
for(const version of patches)for(const format of ['yaml','json'])test(`${version} ${format} response header wire uses original native schema and exact values`,async()=>{
 const schema={type:'array',minItems:2,maxItems:2,items:{type:'integer',enum:[0,'EXACT']}},fixture=input(version,format,{'X-Values':version==='2.0'?{...schema,collectionFormat:'csv'}:{schema}});
 const original=JSON.stringify(fixture.resources),result=await evaluateSchemas({...fixture,runtimeInstances:[fixture.wire('X-Values',['0,9007199254740993'],'good'),fixture.wire('X-Values',['0,9007199254740992'],'bad')]});
 assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert.deepEqual(result.runtimeEvaluations.map(value=>[value.location,value.complete,value.valid]),[['good',true,true],['bad',true,false]]);
 assert.ok(result.runtimeFindings.some(value=>value.code==='runtime.schema.incompatible'&&value.location==='bad'&&value.schema.resource===fixture.root&&value.schema.range[1]>value.schema.range[0]));
 assert.equal(JSON.stringify(fixture.resources),original);
});
for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} boolean header schemas retain assertion and unconstrained ownership`,async()=>{
 const fixture=input(version,format,{'X-False':{schema:false},'X-True':{schema:true}}),result=await evaluateSchemas({...fixture,runtimeInstances:[fixture.wire('X-False',['literal,false'],'false'),fixture.wire('X-True',['literal,false'],'true')]});
 assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert.deepEqual(result.runtimeEvaluations.map(value=>[value.location,value.complete,value.valid]),[['false',true,false],['true',true,true]]);
 assert.ok(result.runtimeFindings.some(value=>value.code==='runtime.schema.incompatible'&&value.location==='false'&&value.schema.pointer.endsWith('/X-False/schema')));
 assert.equal(result.runtimeFindings.some(value=>value.location==='true'),false);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const representation of ['schema','content'])test(`${version} ${format} native ${representation} Set-Cookie keeps full lines and commas`,async()=>{
 const lines=['lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT','foo=bar'];
 const header=representation==='content'?{content:{'text/plain':{schema:{type:'string',enum:[lines.join('\n')]}}}}:{explode:true,schema:{type:'object',required:['lang','foo'],properties:{lang:{type:'string',enum:[lines[0].slice(5)]},foo:{type:'string',enum:['bar']}}}};
 const fixture=input(version,format,{'Set-Cookie':header}),result=await evaluateSchemas({...fixture,runtimeInstances:[fixture.wire('Set-Cookie',lines,'good'),fixture.wire('Set-Cookie',[lines[0],'foo=wrong'],'bad')]});
 assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert.deepEqual(result.runtimeEvaluations.map(value=>[value.location,value.complete,value.valid]),[['good',true,true],['bad',true,false]]);
 assert.ok(result.runtimeFindings.some(value=>value.code==='runtime.schema.incompatible'&&value.location==='bad'));
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} header references retain captured occurrence and external schema ownership`,async()=>{
 const shared={Header:{content:{'application/json':{schema:{type:'integer',enum:['EXACT']}}}}},fixture=input(version,format,{'X-Ref':{$ref:'shared.'+format+'#/Header'}},shared);
 const result=await evaluateSchemas({...fixture,runtimeInstances:[fixture.wire('X-Ref',['9007199254740993'],'good'),fixture.wire('X-Ref',['9007199254740992'],'bad')]});
 assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert.deepEqual(result.runtimeEvaluations.map(value=>value.valid),[true,false]);
 const finding=result.runtimeFindings.find(value=>value.location==='bad');assert.equal(finding.code,'runtime.schema.incompatible');assert.equal(finding.schema.resource,fixture.resources[1].id);assert.equal(finding.schema.pointer,'/Header/content/application~1json/schema');assert.ok(finding.schema.range[1]>finding.schema.range[0]);
});
test('header wire cannot replace captured context, field identity or evaluator inputs',async()=>{
 const fixture=input('3.2.1','json',{'X-Value':{schema:{type:'integer'}}}),original=fixture.wire('X-Value',['0']);
 for(const mutation of [
  {...original,header:{...original.header,pointer:'/info'}},
  {...original,header:{...original.header,name:'Set-Cookie'}},
  {...original,header:{...original.header,values:[]}},
  {...original,header:{...original.header,values:Array(2049).fill('0')}},
  {...original,text:'0'},
  {...original,schema:{resource:fixture.root,pointer:'/paths/~1data/get/responses/204/headers/X-Value/schema'}},
  {...original,mediaType:'application/json'},
  {...original,alternatives:['0']},
  {...original,subject:'request-parameter'},
 ])await assert.rejects(evaluateSchemas({...fixture,runtimeInstances:[mutation]}),{code:'runtime.instance'});
 const clean=await evaluateSchemas({...fixture,runtimeInstances:[original]});assert.equal(clean.complete,true);assert.equal(clean.runtimeEvaluations[0].valid,true);
});
