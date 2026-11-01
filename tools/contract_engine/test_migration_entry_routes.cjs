const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs'),{analyse}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const versions=['2.0','3.0.4','3.1.2','3.2.1'];
function document(version,name){
 const defs=version==='2.0'?'/definitions':'/components/schemas',schema={$ref:'#'+defs+'/Model'};
 return {...(version==='2.0'?{swagger:version,host:name+'.example.invalid',schemes:['https'],basePath:'/v1',produces:['application/json']}:{openapi:version,servers:[{url:'https://'+name+'.example.invalid/v1'}]}),info:{title:name+' 雪',version:'api-version'},paths:{['/'+name]:{get:{operationId:'read_'+name,responses:{200:{description:'[Guide](/guide)',...(version==='2.0'?{schema}:{content:{'application/json':{schema}}})}}}}},...(version==='2.0'?{definitions:{Model:{type:'integer',minimum:'EXACT'}}}:{components:{schemas:{Model:{type:'integer',minimum:'EXACT'}}}}),'x-kept':{n:'EXACT',flag:false,empty:'',literal:{$ref:'not a contract reference'}}};
}
function fixture(primary,secondary,format,targetVersion){
 const root='file:///approved/primary.'+format,part='file:///approved/secondary.'+format;
 const encode=value=>(format==='json'?JSON.stringify(value):'# Keep comments 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
 return {root,snapshot:'entry-routes',targetVersion,destination:'file:///reviewed/output/',resources:[{id:root,text:encode(document(primary,'primary')),generation:1},{id:part,text:encode(document(secondary,'secondary')),generation:2}]};
}
for(const primary of versions)for(const secondary of versions)for(const targetVersion of versions)for(const format of ['yaml','json'])test(`${primary} + ${secondary} ${format} captured entries follow their own route to ${targetVersion}`,async()=>{
 const input=fixture(primary,secondary,format,targetVersion),before=input.resources.map(r=>r.text);
 assert.equal(analyse(input).status,'complete');const result=await planMigration(input);
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);assert.equal(result.manifest.roots.length,2);assert.equal(result.entryRoutes.length,2);
 for(const [index,entry]of result.entryRoutes.entries()){const source=input.resources.find(r=>r.id===entry.resource);assert(source);const declaration=new SourceDocument(source.text,source.id).root.value;assert.equal(entry.from.declaredVersion,declaration.swagger??declaration.openapi);assert.equal(entry.target.declaredVersion,targetVersion);assert(Array.isArray(entry.stages));}
 assert.equal(result.outputs.length,2);assert.deepEqual(input.resources.map(r=>r.text),before);
 const resources=result.outputs.map(o=>({id:o.id,text:o.text,generation:0,aliases:Object.entries(result.manifest.resourceMappings).filter(([,path])=>path===o.path).map(([uri])=>uri)}));
 for(const name of ['primary','secondary']){
  const output=result.outputs.find(o=>new SourceDocument(o.text,o.id).node('/info/title').value===name+' 雪');assert(output);
  const target=new SourceDocument(output.text,output.id);assert.equal(target.node(targetVersion==='2.0'?'/swagger':'/openapi').value,targetVersion);assert.equal(target.node('/info/version').value,'api-version');
  const original=input.resources.find(r=>new SourceDocument(r.text,r.id).node('/info/title').value===name+' 雪');assert.equal(target.dataJson('/x-kept'),new SourceDocument(original.text,original.id).dataJson('/x-kept'));
  assert.equal(analyse({root:output.id,snapshot:'cold-'+name,resources}).status,'complete');
  const pointer=targetVersion==='2.0'?'/definitions/Model':'/components/schemas/Model';
  const evaluated=await evaluateSchemas({root:output.id,snapshot:'exact-'+name,resources,runtimeInstances:['9007199254740993.00','9007199254740992.00'].map(text=>({subject:'response-body',text,location:'application/json',schema:{resource:output.id,pointer}}))});
  assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.deepEqual(evaluated.runtimeEvaluations.map(e=>e.valid),[true,false]);
  if(format==='yaml')assert(output.text.startsWith('# Keep comments 雪\r\n'));
 }
});
for(const primary of ['2.0','3.0.4'])for(const targetVersion of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${primary} ${format} ignored-body decision follows the original entry in composed routes to ${targetVersion}`,async()=>{
 const secondary=primary==='2.0'?'3.0.4':'2.0',input=fixture(primary,secondary,format,targetVersion),ignoredBodyEntry=input.resources.find((_,index)=>(index===0?primary:secondary)==='3.0.4');
 for(const [index,resource]of input.resources.entries()){
  const version=index===0?primary:secondary,name=index===0?'primary':'secondary',pointer='/paths/~1'+name+'/get',schema={$ref:'#'+(version==='2.0'?'/definitions':'/components/schemas')+'/Model'};
  let doc=new SourceDocument(resource.text,resource.id);
  resource.text=version==='2.0'?new SourceDocument(doc.set('/consumes',['application/json']),resource.id).set(pointer+'/parameters',[{name:'body',in:'body',schema}]):doc.set(pointer+'/requestBody',{content:{'application/json':{schema}}});
 }
 const before=input.resources.map(r=>r.text),review=await planMigration(input);
 assert.equal(review.status,'requires-decision',JSON.stringify(review.problems));assert.deepEqual(review.outputs,[]);
 const choices=review.problems.filter(p=>p.code==='migration.body.ignored-activation');assert.equal(choices.length,1);assert.equal(choices[0].resource,ignoredBodyEntry.id);
 const accepted=await planMigration({...input,decisions:{[choices[0].id]:'omit-ignored-body'}});assert.equal(accepted.complete,true,JSON.stringify(accepted.problems));
 for(const [index,name]of ['primary','secondary'].entries()){
  const output=accepted.outputs.find(o=>new SourceDocument(o.text,o.id).node('/info/title').value===name+' 雪'),doc=new SourceDocument(output.text,output.id);
  assert.equal(doc.dataNode('/paths/~1'+name+'/get').children.has('requestBody'),(index===0?primary:secondary)==='2.0');
 }
 assert.deepEqual(input.resources.map(r=>r.text),before);
});
for(const format of ['yaml','json'])test(`${format} a modern-only secondary operation blocks an unrepresentable target without output`,async()=>{
 const input=fixture('3.0.4','3.2.1',format,'3.0.4'),resource=input.resources[1],doc=new SourceDocument(resource.text,resource.id);
 resource.text=doc.set('/paths/~1secondary/query',{responses:{204:{description:'Query'}}});const before=input.resources.map(r=>r.text),result=await planMigration(input);
 assert.equal(result.complete,false);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);
 const issue=result.problems.find(p=>p.code==='migration.feature.newer');assert(issue,JSON.stringify(result.problems));assert.equal(issue.resource,resource.id);assert.equal(issue.pointer,'/paths/~1secondary/query');assert(issue.range[1]>issue.range[0]);assert.deepEqual(input.resources.map(r=>r.text),before);
});
