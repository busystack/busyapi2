const assert=require('node:assert/strict'),{test}=require('node:test');
const base=process.env.BUSYAPI_FORM_DOWNGRADE_BASELINE||__dirname;
const {planMigration}=require(base+'/dist/migration.cjs');
const {requestOperation}=require(base+'/dist/execution.cjs');
const YAML=require(base+'/node_modules/yaml');
for(const format of ['yaml','json'])for(const target of ['3.0.4','3.1.2','3.2.1'])for(const referenced of [false,true]){
 test(`bodyless Swagger ${format} → ${target} referenced=${referenced} cannot activate a response body`,async()=>{
  const root='file:///approved/api.'+format;
  const document={swagger:'2.0',info:{title:'No body',version:'1'},host:'api.invalid',schemes:['https'],produces:['application/json'],paths:{'/items':{get:{responses:{200:referenced?{$ref:'#/responses/Empty'}:{description:'No payload'}}}}},...(referenced?{responses:{Empty:{description:'No payload'}}}:{})};
  const text=format==='json'?JSON.stringify(document):YAML.stringify(document),resources=[{id:root,text,generation:1}];
  const before=requestOperation({root,resources,snapshot:'before',resource:root,pointer:'/paths/~1items/get'});
  assert.equal(before.responses[0].bodyAllowed,false);
  const plan=await planMigration({root,resources,snapshot:'bodyless',targetVersion:target,destination:'file:///output/review/'});
  assert.equal(plan.complete,true,JSON.stringify(plan.problems));assert.equal(resources[0].text,text);
  const after=requestOperation({root:plan.outputRoot,resources:plan.outputs.map(o=>({id:o.id,text:o.text,generation:0})),snapshot:'after',resource:plan.outputRoot,pointer:'/paths/~1items/get'});
  assert.equal(after.responses[0].content.length,0);
  const reverse=await planMigration({root:plan.outputRoot,resources:plan.outputs.map(o=>({id:o.id,text:o.text,generation:0})),snapshot:'reverse',targetVersion:'2.0',destination:'file:///reverse/review/'});
  assert.equal(reverse.complete,true,JSON.stringify(reverse.problems));
  const back=requestOperation({root:reverse.outputRoot,resources:reverse.outputs.map(o=>({id:o.id,text:o.text,generation:0})),snapshot:'back',resource:reverse.outputRoot,pointer:'/paths/~1items/get'});
  assert.equal(back.responses[0].bodyAllowed,false);
 });
}
for(const format of ['yaml','json'])test(`Swagger ${format} schema-less examples are not discarded or activated by migration`,async()=>{
 const root='file:///approved/api.'+format,document={swagger:'2.0',info:{title:'Keep metadata',version:'1'},host:'api.invalid',schemes:['https'],paths:{'/items':{get:{responses:{200:{description:'No payload',examples:{'application/json':{literal:'keep'}}}}}}}};
 const text=format==='json'?JSON.stringify(document):YAML.stringify(document),resources=[{id:root,text,generation:1}];
 const plan=await planMigration({root,resources,snapshot:'examples',targetVersion:'3.0.4',destination:'file:///output/review/'});
 assert.equal(plan.complete,false);assert.equal(plan.status,'blocked');assert.deepEqual(plan.outputs,[]);
 assert(plan.problems.some(p=>p.code==='migration.response.examples-without-schema'&&p.pointer==='/paths/~1items/get/responses/200/examples'));
 assert.equal(resources[0].text,text);
});
