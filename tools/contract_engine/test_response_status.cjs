const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {analyse,inspect,createGraph}=require('./dist/model.cjs');

function fixture(version,format,status){
 const root='file:///project/status.'+format,legacy=version==='2.0';
 const reusable={description:'Named response'},data={...(legacy?{swagger:version}:{openapi:version}),info:{title:'Status keys',version:'1'},paths:{'/items':{get:{responses:{[status]:{description:'Current'}}}}},
  ...(legacy?{responses:{'600':reusable}}:{components:{responses:{'600':reusable}}}),'x-payload':{responses:{'099':{$ref:'literal'}}}};
 return {root,snapshot:'response-status',resources:[{id:root,text:format==='json'?JSON.stringify(data,null,2):YAML.stringify(data),generation:1}]};
}
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json']){
 test(`response status range validation is contextual ${version} ${format}`,()=>{
  for(const status of ['099','600','999']){
   const input=fixture(version,format,status),result=analyse(input);
   assert.equal(result.status,'invalid',status);assert(result.findings.some(finding=>finding.severity==='error'));
   if(version==='2.0'){
    const finding=result.findings.find(finding=>finding.code==='response.status.invalid');
    assert(finding);assert.equal(finding.pointer,'/paths/~1items/get/responses/'+status);assert.equal(finding.resource,input.root);
    assert(finding.range[1]>finding.range[0]);assert.equal(finding.category,'openapi');
   }
  }
  for(const status of ['100','200','599','default',...(version==='2.0'?[]:['2XX'])]){
   const input=fixture(version,format,status),result=analyse(input);
   assert.equal(result.status,'complete',JSON.stringify(result.findings));assert.equal(createGraph(input).graph.issues.length,0);
  }
 });
 test(`response status maintenance metadata retains the actual occurrence ${version} ${format}`,()=>{
  const input=fixture(version,format,'200'),target=inspect({...input,resource:input.root,pointer:'/paths/~1items/get/responses/200'});
  assert.equal(target.componentDefinition,false);assert(target.responseStatusNamePolicy);
  assert.equal(new RegExp(target.responseStatusNamePolicy.pattern).test('2XX'),version!=='2.0');
  assert.equal(new RegExp(target.responseStatusNamePolicy.pattern).test('099'),false);
  const reusable=inspect({...input,resource:input.root,pointer:version==='2.0'?'/responses/600':'/components/responses/600'});
  assert.equal(reusable.componentDefinition,true);assert.equal(reusable.responseStatusNamePolicy,undefined);
 });
}
