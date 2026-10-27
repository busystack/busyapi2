const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {analyse}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');

const routes=[...['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'].flatMap(from=>['3.1.2','3.2.1'].map(to=>[from,to])),...['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'].map(from=>[from,'3.0.4'])];
function capture(from,to,flag,format,mode){
 const root='file:///access/api.'+format,leaf={type:'string',[flag]:true},required=mode==='required'||mode==='shared-required',referenced=['chain','shared-required'].includes(mode);
 const model={type:'object',...(mode==='required'?{required:['value']}:{}),properties:{value:referenced?{$ref:'#/components/schemas/Alias'}:leaf}},schema={$ref:'#/components/schemas/Model'};
 const schemas={Model:model,...(referenced?{Flag:leaf,Alias:{$ref:'#/components/schemas/Flag'}}:{})};
 if(mode==='shared-required')schemas.Other={type:'object',required:['value'],properties:{value:{$ref:'#/components/schemas/Flag'}}};
 const value={openapi:from,info:{title:'Access 雪',version:'api-version'},servers:[{url:'https://api.invalid'}],paths:{'/value':{post:{requestBody:{content:{'application/json':{schema}}},responses:{200:{description:'Value',content:{'application/json':{schema}}}}}}},components:{schemas},'x-kept':{n:'EXACT',flag:false,empty:''}};
 if(mode==='root-use')value.paths['/value'].post.requestBody.content['application/json'].schema={$ref:'#/components/schemas/Model/properties/value'};
 const text=(format==='yaml'?'# Keep comments 雪\r\n'+YAML.stringify(JSON.parse(JSON.stringify(value))).replaceAll('\n','\r\n'):JSON.stringify(value)).replace(/"?EXACT"?/g,'9007199254740993.00');
 return {root,snapshot:'access-'+from+to+flag+format+mode,targetVersion:to,destination:'file:///reviewed/copy/',resources:[{id:root,generation:4,text}]};
}
async function evaluations(input,pointer){
 const result=await evaluateSchemas({...input,runtimeInstances:['request-body','response-body'].flatMap(subject=>['{}','{"value":"snow 雪"}','{"value":false}','{"value":null}'].map(text=>({subject,text,location:'application/json',schema:{resource:input.root,pointer}})))});
 assert.equal(result.complete,true,JSON.stringify(result.findings));return result.runtimeEvaluations.map(e=>e.valid);
}
for(const [from,to]of routes)for(const flag of ['readOnly','writeOnly'])for(const format of ['yaml','json'])for(const mode of ['optional','chain','required','shared-required','root-use'])test(`${from} to ${to} ${format} ${flag} ${mode} retains access evaluation or refuses before publication`,async()=>{
 const input=capture(from,to,flag,format,mode),before=input.resources[0].text;assert.equal(analyse(input).status,'complete');const source=await evaluations(input,'/components/schemas/Model'),result=await planMigration(input);
 if(['required','shared-required','root-use'].includes(mode)){
  assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);const problem=result.problems.find(p=>p.code==='migration.schema.direction');assert(problem,JSON.stringify(result.problems));assert.equal(problem.resource,input.root);assert(problem.range[1]>problem.range[0]);
 }else{
  assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);const resources=result.outputs.map(o=>({id:o.id,generation:0,text:o.text})),target={root:result.outputRoot,snapshot:'cold-access',resources};assert.equal(analyse(target).status,'complete');assert.deepEqual(await evaluations(target,'/components/schemas/Model'),source);
  const doc=new SourceDocument(resources.find(r=>r.id===target.root).text,target.root);assert.equal(doc.node('/openapi').value,to);assert.equal(doc.dataJson('/x-kept'),new SourceDocument(before,input.root).dataJson('/x-kept'));assert.equal(doc.node('/info/version').value,'api-version');
  if(format==='yaml')assert(doc.text.startsWith('# Keep comments 雪\r\n'));
 }
 assert.equal(input.resources[0].text,before);
});

for(const from of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const required of [false,true])test(`${from} ${format} readOnly required=${required} cannot silently acquire Swagger's request exclusion`,async()=>{
 const input=capture(from,'2.0','readOnly',format,required?'required':'optional'),before=input.resources[0].text,result=await planMigration(input);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);assert(result.problems.some(p=>p.code==='migration.schema.direction'),JSON.stringify(result.problems));assert.equal(input.resources[0].text,before);
});

for(const from of ['3.1.2','3.2.1'])for(const to of ['3.1.2','3.2.1'])for(const flag of ['readOnly','writeOnly'])test(`${from} to ${to} modern required ${flag} retains annotation semantics`,async()=>{
 const input=capture(from,to,flag,'yaml','required'),before=await evaluations(input,'/components/schemas/Model'),result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.deepEqual(await evaluations({root:result.outputRoot,snapshot:'modern-access',resources:result.outputs.map(o=>({id:o.id,generation:0,text:o.text}))},'/components/schemas/Model'),before);
});

for(const name of ['id/~雪','__proto__'])for(const flag of ['readOnly','writeOnly'])for(const required of [false,true])test(`${name} ${flag} required=${required} uses decoded property ownership`,async()=>{
 const input=capture('3.0.4','3.2.1',flag,'json','optional'),source=input.resources[0],doc=new SourceDocument(source.text,source.id),schema={type:'object',...(required?{required:[name]}:{}),properties:{[name]:{type:'string',[flag]:true}}};source.text=doc.set('/components/schemas/Model',schema);const before=source.text,result=await planMigration(input);
 assert.equal(result.complete,!required,JSON.stringify(result.problems));if(required){assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.schema.direction'));}else{const resources=result.outputs.map(o=>({id:o.id,text:o.text,generation:0}));assert.equal(analyse({root:result.outputRoot,snapshot:'escaped',resources}).status,'complete');}
 assert.equal(source.text,before);
});

for(const flag of ['readOnly','writeOnly'])for(const required of [false,true])test(`YAML aliased ${flag} required=${required} retains logical owners and shared syntax`,async()=>{
 const input=capture('3.0.4','3.1.2',flag,'yaml','optional'),source=input.resources[0];source.text=`# Keep shared source\r\nopenapi: 3.0.4\r\ninfo: {title: Shared, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Model:\r\n      type: object\r\n${required?'      required: [second]\r\n':''}      properties:\r\n        first: &value {type: string, ${flag}: true}\r\n        second: *value\r\n`;const before=source.text,result=await planMigration(input);assert.equal(result.complete,!required,JSON.stringify(result.problems));
 if(required){assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.schema.direction'));}else{const output=result.outputs[0].text;assert(output.includes('&value {type: string, '+flag+': true}'));assert(output.includes('second: *value\r\n'));assert(output.startsWith('# Keep shared source\r\n'));}
 assert.equal(source.text,before);
});

for(const flag of ['readOnly','writeOnly'])for(const format of ['yaml','json'])test(`${format} ignored legacy ${flag} reference sibling remains an explicit discard decision`,async()=>{
 const input=capture('3.0.4','3.1.2',flag,format,'required'),source=input.resources[0];let doc=new SourceDocument(source.text,source.id);source.text=doc.set('/components/schemas/Model/properties/value',{$ref:'#/components/schemas/Plain',[flag]:true});doc=new SourceDocument(source.text,source.id);source.text=doc.set('/components/schemas/Plain',{type:'string'});const before=source.text,values=await evaluations(input,'/components/schemas/Model'),review=await planMigration(input);
 assert.equal(review.status,'requires-decision',JSON.stringify(review.problems));assert.deepEqual(review.outputs,[]);const problem=review.problems.find(p=>p.code==='migration.reference.ignored-siblings');assert(problem);assert.deepEqual(problem.choices,['discard-ignored-siblings']);
 const result=await planMigration({...input,decisions:{[problem.id]:'discard-ignored-siblings'}});assert.equal(result.complete,true,JSON.stringify(result.problems));assert.deepEqual(await evaluations({root:result.outputRoot,snapshot:'siblings',resources:result.outputs.map(o=>({id:o.id,text:o.text,generation:0}))},'/components/schemas/Model'),values);assert.equal(source.text,before);
});
