const {test}=require('node:test');
const assert=require('node:assert/strict');
const {analyse}=require('./dist/model.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {referencePage,referenceDocument}=require('./dist/reference_projection.cjs');
const {planMigration}=require('./dist/migration.cjs');
const {SourceDocument}=require('./dist/document.cjs');

const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function capture(version,method,yaml=false,reference=false) {
 const root='file:///method-body/api.'+(yaml?'yaml':'json');
 const body={required:true,content:{'application/json':{schema:{type:'object',required:['value'],properties:{value:{type:'string'}}},example:{value:'snow 雪'}}}};
 const value={openapi:version,info:{title:'Method body',version:'api-version'},servers:[{url:'https://api.invalid'}],paths:{'/payload':{[method]:{requestBody:reference?{$ref:'body.json'}:body,responses:{200:{description:'ok'}}}}}};
 const text=(yaml?'# Preserve original request-body declaration\r\n':'')+JSON.stringify(value)+(yaml?'\r\n':'');
 return {root,snapshot:version+method+yaml,resources:[{id:root,generation:3,text},...(reference?[{id:'file:///method-body/body.json',generation:7,text:JSON.stringify(body)}]:[])]};
}
for(const version of versions)for(const yaml of [false,true])for(const method of ['get','head','delete','options','trace','post','put','patch'])test(`${version} ${yaml?'YAML':'JSON'} ${method} consumes only applicable request-body declarations`,()=>{
 const input=capture(version,method,yaml),original=input.resources[0].text;
 const operation=analyse(input).operations[0],selection={...input,resource:input.root,pointer:operation.pointer,occurrence:operation.occurrence};
 const plan=requestOperation(selection),ignored=version.startsWith('3.0.')&&!['post','put','patch'].includes(method);
 assert.equal(!!plan.requestBody,!ignored);
 assert.equal(!!plan.ignoredRequestBody,ignored);
 if(ignored){assert.equal(plan.ignoredRequestBody.method,method.toUpperCase());assert.equal(plan.ignoredRequestBody.source.pointer,operation.pointer+'/requestBody');assert.ok(plan.ignoredRequestBody.source.range[1]>0);}
 const page=referencePage(selection),effective=page.effective.find(field=>field.name==='requestBody');
 assert.equal(effective?.ignored===true,ignored);
 assert.ok(page.previews.some(preview=>preview.label==='request-body'));
 const document=referenceDocument(input),section=document.sections.find(section=>section.source.pointer===operation.pointer);
 assert.equal(section.effective.some(field=>field.name==='requestBody'&&field.ignored===true),ignored);
 assert.equal(input.resources[0].text,original);
});
test('ignored 3.0 body does not make execution depend on an unresolved body reference',()=>{
 const input=capture('3.0.4','get',false,true);input.resources.pop();
 const operation=analyse(input).operations[0];
 const plan=requestOperation({...input,resource:input.root,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(plan.requestBody,undefined);assert.equal(plan.ignoredRequestBody.source.pointer,operation.pointer+'/requestBody');
 assert.equal(analyse(input).complete,false);
});
test('3.0 to modern migration reviews body activation and preserves referenced originals',async()=>{
 const input={...capture('3.0.4','get',true,true),targetVersion:'3.2.1',destination:'file:///migration-output/'};
 const originals=input.resources.map(resource=>resource.text),review=await planMigration(input);
 assert.equal(review.status,'requires-decision',JSON.stringify(review.problems));
 const problem=review.problems.find(problem=>problem.code==='migration.body.ignored-activation');assert.ok(problem);assert.equal(problem.pointer,'/paths/~1payload/get/requestBody');
 assert.deepEqual(problem.choices,['omit-ignored-body']);assert.deepEqual(review.outputs,[]);
 const result=await planMigration({...input,decisions:{[problem.id]:'omit-ignored-body'}});
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.outputs.length,2);
 const output=result.outputs.find(output=>output.id===result.outputRoot),doc=new SourceDocument(output.text,output.id);
 assert.equal(doc.dataNode('/paths/~1payload/get/requestBody'),undefined);
 assert.equal(result.outputs.find(output=>output.id!==result.outputRoot).text,originals[1]);
 assert.deepEqual(input.resources.map(resource=>resource.text),originals);
});
for(const version of ['3.1.2','3.2.1'])test(`${version} downgrade blocks loss of a required GET body`,async()=>{
 const input={...capture(version,'get'),targetVersion:'3.0.4',destination:'file:///migration-output/'};
 const result=await planMigration(input);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
 assert.ok(result.problems.some(problem=>problem.code==='migration.body.target-ignored'&&problem.reason==='target-representation'&&problem.pointer==='/paths/~1payload/get/requestBody'));
});
for(const targetVersion of ['3.0.4','3.1.2','3.2.1'])test(`Swagger GET body migration to ${targetVersion} checks the final family's actual semantics`,async()=>{
 const root='file:///method-body/swagger.json';
 const value={swagger:'2.0',info:{title:'Swagger GET body',version:'1'},host:'api.invalid',schemes:['https'],consumes:['application/json'],paths:{'/payload':{get:{parameters:[{name:'payload',in:'body',required:true,schema:{type:'string'}}],responses:{204:{description:'Empty'}}}}}};
 const text=JSON.stringify(value),input={root,snapshot:'swagger-get',resources:[{id:root,text,generation:1}],targetVersion,destination:'file:///migration-output/'};
 const result=await planMigration(input);
 if(targetVersion==='3.0.4'){
  assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
  assert.ok(result.problems.some(problem=>problem.code==='migration.body.target-ignored'&&problem.pointer==='/paths/~1payload/get/parameters/0'));
 }else{
  assert.equal(result.complete,true,JSON.stringify(result.problems));
  const resources=result.outputs.map(output=>({id:output.id,text:output.text,generation:0,aliases:Object.entries(result.manifest.resourceMappings).filter(([,path])=>path===output.path).map(([uri])=>uri)})),analysis=analyse({root:result.outputRoot,snapshot:'migrated',resources});
  assert.equal(analysis.complete,true);
  const operation=analysis.operations[0],plan=requestOperation({root:result.outputRoot,snapshot:'migrated',resources,resource:operation.resource,pointer:operation.pointer,occurrence:operation.occurrence});
  assert.equal(plan.requestBody.required,true);assert.equal(plan.ignoredRequestBody,undefined);assert.deepEqual(plan.requestBody.content.map(media=>media.mediaType),['application/json']);
 }
 assert.equal(input.resources[0].text,text);
});
for(const yaml of [false,true])test(`reviewed inline ignored body omission includes its examples and keeps ${yaml?'YAML':'JSON'} originals`,async()=>{
 const input={...capture('3.0.4','get',yaml),targetVersion:'3.1.2',destination:'file:///migration-output/'},original=input.resources[0].text;
 const review=await planMigration(input),problem=review.problems.find(problem=>problem.code==='migration.body.ignored-activation');
 assert.ok(problem);assert.deepEqual(review.outputs,[]);
 const result=await planMigration({...input,decisions:{[problem.id]:'omit-ignored-body'}});
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.deepEqual(result.acceptedDecisions,[problem.id]);
 const doc=new SourceDocument(result.outputs[0].text,result.outputRoot);assert.equal(doc.dataNode('/paths/~1payload/get/requestBody'),undefined);
 assert.equal(input.resources[0].text,original);
});
test('3.1 callback GET bodies cannot disappear into 3.0 ignored semantics',async()=>{
 const input={...capture('3.1.2','post'),targetVersion:'3.0.4',destination:'file:///migration-output/'};
 const value=JSON.parse(input.resources[0].text),callbackBody={content:{'application/json':{schema:{type:'string'}}}};
 value.paths['/payload'].post.callbacks={notify:{'{$request.query.callback}':{get:{requestBody:callbackBody,responses:{204:{description:'Empty'}}}}}};
 input.resources[0].text=JSON.stringify(value);
 const result=await planMigration(input);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
 assert.ok(result.problems.some(problem=>problem.code==='migration.body.target-ignored'&&problem.pointer.includes('/callbacks/notify/')&&problem.reason==='target-representation'));
});
