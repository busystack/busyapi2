const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const family=v=>v==='2.0'?'2.0':v.slice(0,3),versions=['2.0','3.0.4','3.1.2','3.2.1'];
const doc=(version,extra)=>({...version==='2.0'?{swagger:version}:{openapi:version},info:{title:'Keep 雪',version:'api-version'},paths:{},...extra});
function fixture(version,format,independent=true,bodyMode){
 const swagger=version==='2.0',root='file:///owners/api.'+format,other='file:///owners/other.'+format,models='file:///owners/models.'+format,alias='file:///owners/alias.'+format;
 const path=swagger?'/definitions/Node':'/components/schemas/Node';
 const api=(name,host)=>{
  const schema={$ref:'alias.'+format+'#/Node~1~0'};
  const response=swagger?{description:'Value',schema}:{description:'Value',content:{'application/json':{schema}}};
  const operation={parameters:[swagger?{name:'q',in:'query',type:'array',items:{type:'integer'},collectionFormat:'multi'}:{name:'q',in:'query',schema:{type:'array',items:{type:'integer'}}}],responses:{200:response}};
  const body={name:'payload',in:'body',required:true,schema};
  if(bodyMode)operation.parameters.push(bodyMode==='reusable'?{$ref:'#/parameters/Payload'}:body);
  const access={type:'apiKey',in:'header',name:'X-'+name+'-Key'};
  return doc(version,{...swagger?{host,basePath:'/v1',schemes:['https'],produces:['application/json'],...(bodyMode?{consumes:['application/json']}:{}),securityDefinitions:{Access:access}}:{servers:[{url:'https://'+host+'/v1'}],components:{securitySchemes:{Access:access}}},...(bodyMode==='reusable'?{parameters:{Payload:body}}:{}),security:[{Access:[]}],paths:{['/'+name]:{[bodyMode?'post':'get']:operation}},'x-literal':{$ref:'literal.json',value:0}});
 };
 const schema={type:'object',additionalProperties:false,required:['n'],properties:{n:{type:'integer',enum:['EXACT',0]},children:{type:'array',items:{$ref:'#'+path}}}};
 const access={type:'apiKey',in:'header',name:'X-Models-Key'};
 const objects=[api('items','a.example.invalid'),...(independent?[api('other','b.example.invalid')]:[]),doc(version,swagger?{host:'models.example.invalid',basePath:'/models',schemes:['https'],definitions:{Node:schema},securityDefinitions:{Access:access}}:{components:{schemas:{Node:schema},securitySchemes:{Access:access}}})];
 if(independent){
  const forward={$ref:'alias.'+format+'#/Node~1~0'};
  if(swagger)objects[1].definitions={Forward:forward};else objects[1].components.schemas={Forward:forward};
  const response=objects[0].paths['/items'][bodyMode?'post':'get'].responses[200];
  (swagger?response.schema:response.content['application/json'].schema).$ref='other.'+format+'#'+(swagger?'/definitions/Forward':'/components/schemas/Forward');
 }
 objects.push({'Node/~':{$ref:'models.'+format+'#'+path}});
 const ids=[root,...(independent?[other]:[]),models,alias];
 if(bodyMode==='fragment'){
  const fragments={};
  for(const [index,name]of ['items','other'].entries()){
   fragments[name]=objects[index].paths['/'+name];
   objects[index].paths['/'+name]={$ref:'path-items.'+format+'#/'+name};
  }
  objects.push(fragments);ids.push('file:///owners/path-items.'+format);
 }
 const resources=objects.map((value,index)=>({id:ids[index],generation:index+1,text:(format==='yaml'?'# Keep source organization 雪\r\n'+YAML.stringify(value,{aliasDuplicateObjects:false}).replaceAll('\n','\r\n'):JSON.stringify(value)).replaceAll('"EXACT"','9007199254740993.000').replaceAll('EXACT','9007199254740993.000')+'\r\n'}));
 return {root,resources,snapshot:'coordinated-documents',destination:'file:///converted/'};
}
for(const version of versions)for(const targetVersion of versions)for(const format of ['yaml','json'])for(const independent of [false,true])
test(`${version} -> ${targetVersion} ${format} migrates captured ${independent?'API and schema':'schema'} documents together`,async()=>{
 const input={...fixture(version,format,independent),targetVersion},before=input.resources.map(r=>r.text);
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.status,'faithfully-convertible');assert.equal(result.outputs.length,input.resources.length);
 const descriptions=input.resources.filter(r=>Object.hasOwn(YAML.parse(r.text),'openapi')||Object.hasOwn(YAML.parse(r.text),'swagger'));
 assert.equal(result.manifest.roots.length,descriptions.length);
 assert(result.manifest.roots.every(root=>!root.path.includes('/')),'Every complete API must reopen within the output directory boundary');
 const resources=result.outputs.map(o=>({id:o.id,text:o.text,generation:0}));
 for(const source of descriptions){
  const output=result.outputs.find(o=>o.id===result.changes.find(c=>c.resource===source.id).destination);assert(output);
  const oldGraph=createGraph({...input,root:source.id}).graph,newInput={root:output.id,resources,snapshot:'cold'},newGraph=createGraph(newInput).graph;
  const checked=analyse(newInput);assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.findings,[]);assert.equal(newGraph.specifications.get(output.id).declaredVersion,targetVersion);
  for(const operation of oldGraph.operations()){
   const original=requestOperation({...input,root:source.id,resource:operation.source.resource,pointer:operation.source.pointer,occurrence:operation.occurrence});
   const occurrence=newGraph.operations().find(o=>o.method===operation.method&&o.path===operation.path);assert(occurrence);
   const migrated=requestOperation({...newInput,resource:occurrence.source.resource,pointer:occurrence.source.pointer,occurrence:occurrence.occurrence});
   assert.equal(migrated.servers[0].url,original.servers[0].url);assert.deepEqual(migrated.responses.map(r=>r.content.map(m=>m.mediaType)),original.responses.map(r=>r.content.map(m=>m.mediaType)));
   assert.equal(migrated.security.schemes.Access.parameterName,original.security.schemes.Access.parameterName);
   assert.equal(migrated.parameters[0].explode,true);assert.equal(migrated.parameters[0].name,'q');
   for(const text of ['{"n":9007199254740993.000,"children":[{"n":0}]}','{"n":1}']){
    const checked=await evaluateSchemas({...newInput,runtimeInstances:[{subject:'response-body',location:'application/json',text,schema:migrated.responses[0].content[0].schema}]});
    assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.equal(checked.runtimeEvaluations[0].valid,text.includes('9007199254740993'));
   }
  }
  if(format==='yaml')assert(output.text.startsWith('# Keep source organization 雪\r\n'));
 }
 assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const version of ['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} coordinated patch update applies the reviewed declaration to every description`,async()=>{
 const targetVersion={'2.0':'2.0','3.0':'3.0.4','3.1':'3.1.2','3.2':'3.2.1'}[family(version)],input={...fixture(version,format),targetVersion};
 for(const resource of input.resources.slice(1)){
  const document=new SourceDocument(resource.text,resource.id);
  if(document.dataNode('/openapi'))resource.text=document.set('/openapi',targetVersion);
 }
 const before=input.resources.map(r=>r.text),result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));
 for(const output of result.outputs){const value=YAML.parse(output.text);if(value.openapi||value.swagger)assert.equal(value.openapi??value.swagger,targetVersion);}
 assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const format of ['yaml','json'])test(`${format} mixed modern shared resources retain incompatible context blockers`,async()=>{
 const input={...fixture('3.1.2',format),targetVersion:'3.2.1'},resource=input.resources[1];resource.text=new SourceDocument(resource.text,resource.id).set('/openapi','3.2.1');
 const before=input.resources.map(r=>r.text),result=await planMigration(input);assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
 const problem=result.problems.find(p=>p.code==='migration.documents.context');assert(problem,JSON.stringify(result.problems));assert.equal(problem.resource,input.resources[3].id);assert.equal(problem.pointer,'');assert(input.resources[3].text.slice(...problem.range).includes('Node/~'));assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const format of ['yaml','json'])test(`${format} one Swagger operation cannot silently collapse distinct inherited media`,async()=>{
 const input={...fixture('2.0',format),targetVersion:'3.0.4'};
 input.resources[0].text=new SourceDocument(input.resources[0].text,input.resources[0].id).set('/paths/~1items',{$ref:'other.'+format+'#/paths/~1other'});
 input.resources[1].text=new SourceDocument(input.resources[1].text,input.resources[1].id).set('/produces',['application/xml']);
 const before=input.resources.map(r=>r.text),result=await planMigration(input);assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.operation.multiple-contexts'&&p.resource===input.resources[1].id&&p.range[1]>p.range[0]),JSON.stringify(result.problems));assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const format of ['yaml','json'])test(`${format} incomplete secondary resources cannot produce a migrated copy`,async()=>{
 const input={...fixture('3.0.4',format),targetVersion:'3.2.1'};input.resources.pop();const before=input.resources.map(r=>r.text),result=await planMigration(input);
 assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.validation.incomplete'));assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const targetVersion of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const bodyMode of ['inline','reusable','fragment'])
test(`Swagger ${format} ${bodyMode} body owners survive coordinated upgrade to ${targetVersion}`,async()=>{
 const input={...fixture('2.0',format,true,bodyMode),targetVersion},before=input.resources.map(r=>r.text),result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.deepEqual(result.problems,[]);
 const resources=result.outputs.map(o=>({id:o.id,text:o.text,generation:0}));
 for(const source of input.resources.slice(0,2)){
  const outputRoot=result.changes.find(c=>c.resource===source.id).destination,after={root:outputRoot,snapshot:'body-owners',resources},graph=createGraph(after).graph;
  const operation=graph.operations().find(o=>o.role==='operation'),plan=requestOperation({...after,resource:operation.source.resource,pointer:operation.source.pointer,occurrence:operation.occurrence});
  assert.equal(plan.operation.method,'POST');assert.equal(plan.requestBody.required,true);assert.equal(plan.requestBody.content[0].mediaType,'application/json');
  for(const text of ['{"n":9007199254740993.000,"children":[{"n":0}]}','{"n":1}']){
   const evaluated=await evaluateSchemas({...after,runtimeInstances:[{subject:'request-body',location:'application/json',text,schema:plan.requestBody.content[0].schema}]});
   assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.equal(evaluated.runtimeEvaluations[0].valid,text.includes('9007199254740993'));
  }
 }
 assert.deepEqual(input.resources.map(r=>r.text),before);
});
