const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const base=process.env.BUSYAPI_FORM_DOWNGRADE_BASELINE||__dirname;
const {evaluateSchemas}=require(base+'/dist/schema_evaluation.cjs'),{requestOperation}=require(base+'/dist/execution.cjs');
for(const version of ['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['json','yaml'])for(const empty of [false,true])test(`${version} ${format} response ${empty?'empty':'absent'} content is captured through references`,async()=>{
 const root='file:///response/api.'+format,shared='file:///response/shared.'+format,response={description:'No content',...(version!=='2.0'&&empty?{content:{}}:{})};
 const document={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Response',version:'1'},paths:{'/items':{get:{responses:{200:{$ref:'./shared.'+format+'#/Empty'}}}}}};
 const serialize=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);
 const resources=[{id:root,text:serialize(document),generation:1},{id:shared,text:serialize({Empty:response}),generation:1}],before=JSON.stringify(resources);
 const request=requestOperation({root,resources,snapshot:'response',resource:root,pointer:'/paths/~1items/get'});
 assert.equal(request.complete,true,JSON.stringify(request.problems));assert.equal(request.responses[0].bodyAllowed,false);
 for(const bytes of [Buffer.alloc(0),Buffer.from([0,255,128]),Buffer.from('{"literal":{"$ref":"never-resolve"}}')]){
  const result=await evaluateSchemas({root,resources,snapshot:'response',runtimeInstances:[{subject:'response-body',location:'response',media:{resource:root,pointer:'/paths/~1items/get/responses/200'},mediaBase64:true,text:bytes.toString('base64')}]});
  assert.equal(result.complete,true,JSON.stringify(result));assert.equal(result.runtimeFindings.every(finding=>finding.severity!=='error'),bytes.length===0,JSON.stringify(result));
  assert.equal(result.runtimeEvaluations[0].syntax,'no-response-content');
  if(bytes.length)assert(result.runtimeFindings.some(p=>p.code==='runtime.response.body.forbidden'&&p.source.resource===shared&&p.source.pointer==='/Empty'&&p.range[1]>p.range[0]),JSON.stringify(result.problems));
 }
 assert.equal(JSON.stringify(resources),before);
});
for(const version of ['3.0.0','3.0.4','3.1.2','3.2.1'])for(const format of ['json','yaml'])test(`${version} ${format} a Media Type without schema permits content and cannot be replaced by its Response owner`,async()=>{
 const root='file:///response/content.'+format,response={description:'Any JSON payload',content:{'application/json':{}}};
 const document={openapi:version,info:{title:'Content',version:'1'},paths:{'/items':{get:{responses:{200:response}}}}};
 const resources=[{id:root,text:format==='json'?JSON.stringify(document):YAML.stringify(document),generation:1}],at='/paths/~1items/get/responses/200';
 const request=requestOperation({root,resources,snapshot:'content',resource:root,pointer:'/paths/~1items/get'});
 assert.equal(request.responses[0].bodyAllowed,true);
 const input={root,resources,snapshot:'content',runtimeInstances:[{subject:'response-body',location:'body',mediaType:'application/json',mediaBase64:true,text:Buffer.from('false').toString('base64'),media:{resource:root,pointer:at+'/content/application~1json'}}]};
 const valid=await evaluateSchemas(input);assert.equal(valid.complete,true,JSON.stringify(valid));assert.equal(valid.runtimeFindings.length,0);assert.equal(valid.runtimeEvaluations[0].valid,true);
 input.runtimeInstances[0].media.pointer=at;
 const forged=await evaluateSchemas(input);assert.equal(forged.complete,false);assert(forged.runtimeFindings.some(finding=>finding.code==='runtime.response.body.unchecked'&&finding.detailCode==='runtime.media.owner'));
});
