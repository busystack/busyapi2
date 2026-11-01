const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');

for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['json','yaml'])test(`${version} ${format} multipart input schema requirements stay in their family and context`,()=>{
 const document={openapi:version,info:{title:'Multipart schema',version:'1'},paths:{'/form':{post:{
  requestBody:{$ref:'#/components/requestBodies/Body'},responses:{200:{description:'Optional output schema',content:{'multipart/form-data':{}}}},
 }}},components:{requestBodies:{Body:{content:{'multipart/form-data':{}}}}},'x-payload':{requestBody:{content:{'multipart/form-data':{}}}}};
 const root='file:///form-schema/api.'+format;
 const run=()=>analyse({root,snapshot:version+format,resources:[{id:root,text:format==='json'?JSON.stringify(document):YAML.stringify(document),generation:1}]});
 const initial=run(),issues=initial.findings.filter(finding=>finding.code==='media.multipart.schema.required');
 assert.equal(issues.length,version.startsWith('3.0.')?1:0,JSON.stringify(initial.findings));
 if(issues.length){assert.equal(issues[0].pointer,'/components/requestBodies/Body/content/multipart~1form-data');assert.ok(issues[0].range[1]>issues[0].range[0]);}
 document.components.requestBodies.Body.content['multipart/form-data'].schema={};
 assert.equal(run().findings.filter(finding=>finding.severity==='error').length,0);
 document.components.requestBodies.Body.content={'application/x-www-form-urlencoded':{}};
 assert.equal(run().findings.filter(finding=>finding.severity==='error').length,0);
});
