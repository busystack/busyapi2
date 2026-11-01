const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {createGraph}=require('./dist/model.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const versions=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const names=['id/~雪','__proto__',''];
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
function capture(version,format,flag,mode){
 const root='file:///approved/api.'+format,fields='file:///approved/fields.'+format;
 const scalar={type:'integer',minimum:'EXACT',[flag]:true};
 const property=mode==='direct'?scalar:mode==='composition'?{allOf:[scalar]}:
  mode==='sibling'?{$ref:'fields.'+format+'#/Plain',[flag]:true}:{$ref:'fields.'+format+'#/Alias'};
 const model={...(mode==='composition'?{}:{type:'object'}),required:names,properties:Object.fromEntries(names.map(name=>[name,property]))};
 model.properties.next={$ref:'#/components/schemas/Model'};
 const schema={$ref:'#/components/schemas/Model'};
 const document={openapi:version,info:{title:'Presence',version:'business'},servers:[{url:'https://api.invalid'}],paths:{'/value':{post:{requestBody:{content:{'application/json':{schema}}},responses:{200:{description:'Reply',content:{'application/json':{schema}}}}}}},components:{schemas:{Model:model}},'x-literal':{required:['unchanged'],readOnly:true,value:'EXACT'}};
 const render=value=>(format==='json'?JSON.stringify(value):'# Keep flags\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace(/"?EXACT"?/g,'9007199254740993.00');
 return {root,snapshot:'presence-'+version+format+flag+mode,targetVersion:'3.0.4',destination:'file:///reviewed/',resources:[{id:root,text:render(document),generation:3},
  ...(mode==='chain'||mode==='sibling'?[{id:fields,text:render({Alias:{$ref:'#/Flag'},Flag:scalar,Plain:{type:'integer',minimum:'EXACT'}}),generation:5}]:[])]};
}
async function outcomes(input,texts){
 const checked=await evaluateSchemas({...input,runtimeInstances:['request-body','response-body'].flatMap(subject=>texts.map(text=>({subject,location:'application/json',text,mediaType:'application/json',media:{resource:input.root,pointer:'/paths/~1value/post/'+(subject==='request-body'?'requestBody':'responses/200')+'/content/application~1json'}})))});
 assert.equal(checked.complete,true,JSON.stringify(checked.runtimeFindings));return checked.runtimeEvaluations.map(value=>value.valid);
}
const values=[
 '{}',
 '{"id/~雪":9007199254740993.00,"__proto__":9007199254740993,"":9007199254740994}',
 '{"id/~雪":9007199254740992,"__proto__":9007199254740993,"":9007199254740994}',
 '{"id/~雪":9007199254740993,"__proto__":9007199254740993}',
 '{"id/~雪":9007199254740993,"__proto__":9007199254740993,"":9007199254740994,"next":{}}',
 'null','0','false','[]','"café"',
];
for(const version of versions)for(const format of ['yaml','json'])for(const flag of ['readOnly','writeOnly'])for(const mode of ['direct','chain','composition','sibling'])
test(`${version} ${format} ${flag} ${mode} lowering keeps shared request/response presence without weakening values`,async()=>{
 const input=capture(version,format,flag,mode),before=input.resources.map(value=>value.text),source=await outcomes(input,values),plan=await planMigration(input);
 assert.equal(plan.complete,true,JSON.stringify(plan.problems));assert.equal(plan.producerVersion,'30');
 const output={root:plan.outputRoot,snapshot:'cold-presence',resources:plan.outputs.map(value=>({id:value.id,text:value.text,generation:0}))};
 assert.deepEqual(await outcomes(output,values),source);
 const graph=createGraph(output).graph,doc=graph.docs.get(output.root),model=doc.dataNode('/components/schemas/Model').value;
 assert.deepEqual(model.required,names);assert.equal(model.allOf.length,names.length);
 for(const name of names){
  const guards=model.allOf.filter(value=>value.not?.properties&&Object.hasOwn(value.not.properties,name));assert.equal(guards.length,1);
  assert.deepEqual(guards[0],{not:{type:'object',properties:{[name]:{not:{}}}}});
 }
 assert.equal(source[0],false);assert.equal(source[1],true);assert.equal(source[2],false);assert.equal(source[3],false);assert.equal(source[4],false);
 assert.equal(source[5],mode==='composition');
 assert(plan.outputs[0].text.includes('9007199254740993.00'));
 assert.deepEqual(input.resources.map(value=>value.text),before);
});

for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} an unrelated required schema keeps its exact source ownership`,async()=>{
 const input=capture(version,format,'readOnly','direct'),text=input.resources[0].text;
 const unrelated={type:'object',required:['plain'],properties:{plain:{type:'string'}}};
 input.resources[0].text=new SourceDocument(text,input.root).set('/components/schemas/Unrelated',unrelated);
 const plan=await planMigration(input);assert.equal(plan.complete,true,JSON.stringify(plan.problems));
 const output={root:plan.outputRoot,resources:plan.outputs.map(value=>({...value,generation:0}))},node=createGraph(output).graph.docs.get(output.root).dataNode('/components/schemas/Unrelated');
 assert.deepEqual(node.value,unrelated);assert.equal(node.value.allOf,undefined);
});

for(const format of ['yaml','json'])test(`${format} property access annotations survive static dynamic-reference lowering`,async()=>{
 const input=capture('3.1.2',format,'writeOnly','chain');
 for(const name of names)input.resources[0].text=new SourceDocument(input.resources[0].text,input.root).set('/components/schemas/Model/properties/'+escape(name),{$dynamicRef:'fields.'+format+'#/Flag'});
 const before=await outcomes(input,values),plan=await planMigration(input);assert.equal(plan.complete,true,JSON.stringify(plan.problems));
 assert.deepEqual(await outcomes({root:plan.outputRoot,snapshot:'cold-static',resources:plan.outputs.map(value=>({...value,generation:0}))},values),before);
});


for(const flag of ['readOnly','writeOnly'])for(const sharedOwner of [false,true])
test(`YAML ${flag} whole-owner-shared=${sharedOwner} preserves scalar aliases or refuses the actual shared edit`,async()=>{
 const root='file:///approved/api.yaml';
 const text='openapi: 3.1.2\ninfo: {title: Aliases, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model: '+(sharedOwner?'&model':'')+'\n'+
  '      type: object\n      required: [first, second] # keep required\n      properties:\n        first: &flag {type: string, '+flag+': true} # keep field\n        second: *flag\n'+
  'x-data: '+(sharedOwner?'*model':'*flag')+'\n';
 const input={root,snapshot:'presence-alias',targetVersion:'3.0.4',destination:'file:///reviewed/',resources:[{id:root,text,generation:1}]};
 const plan=await planMigration(input);
 if(sharedOwner){assert.equal(plan.complete,false);assert.deepEqual(plan.outputs,[]);assert(plan.problems.some(value=>value.code==='edit.shared'),JSON.stringify(plan.problems));}
 else{
  assert.equal(plan.complete,true,JSON.stringify(plan.problems));const output=plan.outputs.find(value=>value.id===plan.outputRoot);
  assert(output.text.includes('&flag {type: string, '+flag+': true} # keep field'));
  assert(output.text.includes('second: *flag\n'));assert(output.text.includes('x-data: *flag\n'));assert(output.text.includes('# keep required'));
  const resources=plan.outputs.map(value=>({...value,generation:0}));
  for(const subject of ['request-body','response-body']){
   const check=async(root,resources)=>evaluateSchemas({root,snapshot:'aliases',resources,runtimeInstances:['{}','{"first":"café","second":"雪"}','{"first":"café"}','{"first":false,"second":"雪"}'].map(text=>({subject,text,location:'application/json',schema:{resource:root,pointer:'/components/schemas/Model'}}))});
   const before=await check(input.root,input.resources),after=await check(plan.outputRoot,resources);
   assert.equal(after.complete,true);assert.deepEqual(after.runtimeEvaluations.map(value=>value.valid),before.runtimeEvaluations.map(value=>value.valid));
  }
 }
 assert.equal(input.resources[0].text,text);
});
