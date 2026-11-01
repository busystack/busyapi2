const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} bounded wire alternatives require an independent native schema proof`,async()=>{
 const root='file:///runtime-alternatives/api.'+format,container=version==='2.0'?'definitions':'components',schema={type:'array',minItems:2,maxItems:2,items:{type:'array',minItems:2,maxItems:2,items:{type:'integer',enum:[0,'EXACT_VALUE']}}};
 const document={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Wire proof',version:'api-version'},paths:{},[container]:version==='2.0'?{Value:schema}:{schemas:{Value:schema}}};
 const rendered=format==='yaml'?YAML.stringify(document):JSON.stringify(document),text=rendered.replaceAll(format==='json'?'"EXACT_VALUE"':'EXACT_VALUE','9007199254740993.00');
 const schemaLocation={resource:root,pointer:(version==='2.0'?'/definitions':'/components/schemas')+'/Value'};
 const good='[[0,9007199254740993],[9007199254740993,0]]',bad='[[0,9007199254740992],[9007199254740993,0]]';
 const input={root,snapshot:'wire-proof',resources:[{id:root,text,generation:3}],runtimeInstances:[
  {subject:'response-header',location:'good',text:bad,alternatives:[good],schema:schemaLocation},
  {subject:'response-header',location:'bad',text:bad,alternatives:[bad.replace('0992','0994')],schema:schemaLocation},
 ]};
 const result=await evaluateSchemas(input);
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.deepEqual(result.runtimeEvaluations.map(value=>[value.location,value.complete,value.valid]),[['good',true,true],['bad',true,false]],JSON.stringify(result.runtimeFindings));
 assert.ok(result.runtimeFindings.length>0);
 assert.ok(result.runtimeFindings.every(finding=>finding.location==='bad'&&finding.code==='runtime.schema.incompatible'&&finding.schema.resource===root));
 assert.equal(input.resources[0].text,text);
});

for(const subject of ['request-parameter','response-header'])test(`${subject} alternative exhaustion retains its own diagnostic and source`,async()=>{
 const root='file:///runtime-alternatives/bounded.json',pointer='/components/schemas/Value';
 const text=JSON.stringify({openapi:'3.0.4',info:{title:'Bounded proof',version:'1'},paths:{},components:{schemas:{Value:{type:'integer'}}}});
 const alternatives=Array(255).fill('0');
 const runtimeInstances=Array.from({length:9},(_,index)=>({subject,location:'field-'+index,text:'0',alternatives,schema:{resource:root,pointer}}));
 const result=await evaluateSchemas({root,snapshot:'bounded-wire-proof',resources:[{id:root,text,generation:1}],runtimeInstances});
 assert.equal(result.complete,false);
 const overflow=result.runtimeEvaluations.find(value=>value.location==='field-8');
 assert.equal(overflow.complete,false);assert.equal(overflow.valid,false);
 const finding=result.runtimeFindings.find(value=>value.location==='field-8');
 assert.equal(finding.code,'runtime.schema.alternatives.unchecked');assert.equal(finding.subject,subject);
 assert.equal(finding.schema.resource,root);assert.equal(finding.schema.pointer,pointer);
 assert.ok(finding.schema.range[1]>finding.schema.range[0]);
 assert.equal(runtimeInstances[8].location,'field-8');
});
