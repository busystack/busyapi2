const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {planMigration}=require('./dist/migration.cjs');
const {SourceDocument}=require('./dist/document.cjs');

function capture(version,method,format,referenced=false) {
 const root='file:///ignored-body/api.'+format,bodyId='file:///ignored-body/body.'+format;
 const body={description:'[Guide](/guide)',required:true,content:{'application/json':{schema:{type:'string'},example:'snow 雪'}}};
 const value={openapi:version,info:{title:'Ignored body 雪',version:'api-version'},servers:[{url:'https://api.invalid/v1'}],paths:{'/payload':{[method]:{requestBody:referenced?{$ref:'body.'+format}:body,responses:{204:{description:'Empty'}}}}},'x-kept':{empty:'',flag:false,zero:0,exact:'EXACT'}};
 const encode=value=>(format==='yaml'?'# Preserve comments 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)).replace(/"?EXACT"?/g,'9007199254740993.00');
 return {root,snapshot:'ignored-body-'+version+method+format+referenced,targetVersion:'2.0',destination:'file:///reviewed/converted/',resources:[{id:root,generation:3,text:encode(value)},...(referenced?[{id:bodyId,generation:7,text:encode(body)}]:[])]};
}
function outputs(result){return result.outputs.map(output=>({id:output.id,text:output.text,generation:0,aliases:Object.entries(result.manifest.resourceMappings).filter(([,path])=>path===output.path).map(([uri])=>uri)}));}
function operation(input){const found=analyse(input).operations[0];return requestOperation({...input,resource:found.resource,pointer:found.pointer,occurrence:found.occurrence});}

for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])for(const referenced of [false,true])for(const method of ['get','head','delete','options'])test(`${version} ${format} ${method} ${referenced?'referenced':'inline'} ignored body needs explicit omission before Swagger publication`,async()=>{
 const input=capture(version,method,format,referenced),before=input.resources.map(r=>r.text),pointer='/paths/~1payload/'+method+'/requestBody';
 assert.equal(analyse(input).status,'complete');assert.equal(operation(input).requestBody,undefined);
 const review=await planMigration(input);assert.equal(review.status,'requires-decision',JSON.stringify(review.problems));assert.deepEqual(review.outputs,[]);assert.deepEqual(review.changes,[]);
 const problem=review.problems.find(p=>p.code==='migration.body.ignored-activation');assert(problem);assert.equal(review.problems.length,1);assert.equal(problem.resource,input.root);assert.equal(problem.pointer,pointer);assert(problem.range[1]>problem.range[0]);assert.deepEqual(problem.choices,['omit-ignored-body']);
 const result=await planMigration({...input,decisions:{[problem.id]:'omit-ignored-body'}});assert.equal(result.complete,true,JSON.stringify(result.problems));assert.deepEqual(result.acceptedDecisions,[problem.id]);
 const resources=outputs(result),target={root:result.outputRoot,snapshot:'cold-swagger',resources};assert.equal(analyse(target).status,'complete');
 const doc=new SourceDocument(resources.find(r=>r.id===target.root).text,target.root),source=new SourceDocument(before[0],input.root);assert.equal(doc.node('/swagger').value,'2.0');assert.equal(doc.node('/info/version').value,'api-version');assert.equal(doc.dataNode(pointer),undefined);assert.equal(doc.dataJson('/x-kept'),source.dataJson('/x-kept'));
 const plan=operation(target);assert.equal(plan.operation.method,method.toUpperCase());assert.equal(plan.requestBody,undefined);assert.equal(plan.ignoredRequestBody,undefined);
 if(referenced)assert.equal(result.outputs.find(o=>o.id!==result.outputRoot).text,before[1]);
 if(format==='yaml')assert(doc.text.startsWith('# Preserve comments 雪\r\n'));
 assert.deepEqual(input.resources.map(r=>r.text),before);
 const changed={...input,resources:input.resources.map((r,i)=>i? r:{...r,generation:r.generation+1,text:r.text.replace('Ignored body 雪','Changed 雪')})};
 await assert.rejects(planMigration({...changed,decisions:{[problem.id]:'omit-ignored-body'}}),{code:'migration.decisions.stale'});assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const format of ['yaml','json'])for(const referenced of [false,true])for(const method of ['post','put','patch'])test(`${format} ${method} ${referenced?'referenced':'inline'} active 3.0 body stays active in Swagger`,async()=>{
 const input=capture('3.0.4',method,format,referenced),index=referenced?1:0,doc=new SourceDocument(input.resources[index].text,input.resources[index].id);
 input.resources[index].text=doc.remove((referenced?'':'/paths/~1payload/'+method+'/requestBody')+'/content/application~1json/example');const before=input.resources.map(r=>r.text);
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.deepEqual(result.acceptedDecisions,[]);
 const plan=operation({root:result.outputRoot,snapshot:'active-swagger',resources:outputs(result)});assert.equal(plan.requestBody.required,true);assert.equal(plan.ignoredRequestBody,undefined);assert.equal(plan.operation.method,method.toUpperCase());assert.deepEqual(plan.requestBody.content.map(m=>m.mediaType),['application/json']);assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const format of ['yaml','json'])test(`${format} missing ignored-body dependencies remain incomplete and cannot publish`,async()=>{
 const input=capture('3.0.4','get',format,true);input.resources.pop();const before=input.resources[0].text,result=await planMigration(input);
 assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.reason==='source-incomplete'));assert.equal(input.resources[0].text,before);
});

for(const version of ['3.1.2','3.2.1'])for(const ignoredPrimary of [false,true])for(const format of ['yaml','json'])test(`${version} + 3.0 ${format} Swagger downgrade only omits the original ignored entry body (root ${ignoredPrimary?'3.0':version})`,async()=>{
 const ignored=capture('3.0.4','get',format),active=capture(version,'get',format),modernId='file:///ignored-body/modern.'+format;
 const modernDoc=new SourceDocument(active.resources[0].text,modernId);active.resources[0]={...active.resources[0],id:modernId,text:modernDoc.remove('/paths/~1payload/get/requestBody/content/application~1json/example')};
 const input={...ignored,root:ignoredPrimary?ignored.root:modernId,resources:ignoredPrimary?[...ignored.resources,...active.resources]:[...active.resources,...ignored.resources]},before=input.resources.map(r=>r.text),review=await planMigration(input);
 assert.equal(review.status,'requires-decision',JSON.stringify(review.problems));const problem=review.problems.find(p=>p.code==='migration.body.ignored-activation');assert(problem);assert.equal(problem.resource,ignored.root);
 const result=await planMigration({...input,decisions:{[problem.id]:'omit-ignored-body'}});assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.entryRoutes.length,2);
 const resources=outputs(result);for(const original of input.resources){const route=result.changes.find(change=>change.resource===original.id),output=result.outputs.find(o=>o.id===route.destination);assert(output);const plan=operation({root:output.id,snapshot:original.id,resources});assert.equal(!!plan.requestBody,original.id===modernId);}
 assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} TRACE cannot be represented by Swagger and never offers an omission decision`,async()=>{
 const input=capture(version,'trace',format),before=input.resources.map(r=>r.text),result=await planMigration(input);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);assert.deepEqual(result.acceptedDecisions,[]);const problem=result.problems.find(p=>p.code==='migration.operation.method');assert(problem,JSON.stringify(result.problems));assert.equal(problem.pointer,'/paths/~1payload/trace');assert.equal(problem.reason,'target-representation');assert(problem.range[1]>problem.range[0]);assert(!result.problems.some(p=>p.reason==='decision'));assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const format of ['yaml','json'])for(const metadata of ['schema','example','relative-description'])test(`${format} shared ignored/active body keeps the active owner's ${metadata} conversion proof`,async()=>{
 const input=capture('3.0.4','get',format,true),root=input.resources[0],fragment=input.resources[1];
 root.text=new SourceDocument(root.text,root.id).set('/paths/~1payload/post',{requestBody:{$ref:'body.'+format},responses:{204:{description:'Empty'}}});
 if(metadata!=='example')fragment.text=new SourceDocument(fragment.text,fragment.id).remove('/content/application~1json/example');
 if(metadata==='relative-description')fragment.text=new SourceDocument(fragment.text,fragment.id).set('/description','[Guide](guide.md)');
 const before=input.resources.map(r=>r.text),review=await planMigration(input);assert.equal(review.status,'requires-decision',JSON.stringify(review.problems));const problem=review.problems.find(p=>p.code==='migration.body.ignored-activation');assert(problem);
 const result=await planMigration({...input,decisions:{[problem.id]:'omit-ignored-body'}});
 if(metadata==='schema'){
  assert.equal(result.complete,true,JSON.stringify(result.problems));const resources=outputs(result),analysis=analyse({root:result.outputRoot,snapshot:'shared-swagger',resources});assert.equal(analysis.status,'complete');
  for(const op of analysis.operations){const plan=requestOperation({root:result.outputRoot,snapshot:'shared-swagger',resources,resource:op.resource,pointer:op.pointer,occurrence:op.occurrence});assert.equal(!!plan.requestBody,op.method==='post');}
 }else{
  assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code===(metadata==='example'?'migration.body.media-metadata':'migration.description.relative-links')),JSON.stringify(result.problems));
 }
 assert.deepEqual(input.resources.map(r=>r.text),before);
});

test('an ignored body anchor shared by an active operation still needs ownership-preserving edits',async()=>{
 const input=capture('3.0.4','get','yaml');input.resources[0].text='openapi: 3.0.4\ninfo: {title: Shared, version: "1"}\nservers: [{url: https://api.invalid}]\npaths:\n  /payload:\n    get:\n      requestBody: &body\n        content:\n          application/json:\n            schema: {type: string}\n      responses: {204: {description: Empty}}\n    post:\n      requestBody: *body\n      responses: {204: {description: Empty}}\n';
 const before=input.resources[0].text,review=await planMigration(input),problem=review.problems.find(p=>p.code==='migration.body.ignored-activation');assert(problem);
 const result=await planMigration({...input,decisions:{[problem.id]:'omit-ignored-body'}});
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.deepEqual(result.acceptedDecisions,[problem.id]);
 const target={root:result.outputRoot,snapshot:'cold-shared-body',resources:outputs(result)},analysis=analyse(target);
 assert.equal(analysis.status,'complete',JSON.stringify(analysis.findings));
 for(const method of ['get','post']){
  const source=analysis.operations.find(operation=>operation.method===method);assert(source);
  const description=requestOperation({...target,resource:source.resource,pointer:source.pointer,occurrence:source.occurrence});
  assert.equal(description.requestBody!==undefined,method==='post');
  if(method==='post')assert.deepEqual(description.requestBody.content.map(media=>media.mediaType),['application/json']);
 }
 assert.equal(input.resources[0].text,before);
});
