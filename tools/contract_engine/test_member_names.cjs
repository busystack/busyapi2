const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {createGraph,analyse,inspect}=require('./dist/model.cjs');
const {planRename,planResponseRename}=require('./dist/refactoring.cjs');
const {planExtract,planExtractToFile,planMoveDefinition}=require('./dist/refactoring_copy.cjs');
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');

function fixture(version,format,oldName='Old'){
 const root='file:///project/api.'+format,legacy=version==='2.0';
 const pointer=group=>(legacy?'/'+({schemas:'definitions',parameters:'parameters',responses:'responses',securitySchemes:'securityDefinitions'})[group]:'/components/'+group)+'/'+escape(oldName);
 const schema={type:'string'},parameter={name:'q',in:'query',...(legacy?{type:'string'}:{schema})},response={description:'Stored',...(legacy?{schema:{$ref:'#'+pointer('schemas')}}:{content:{'application/json':{schema:{$ref:'#'+pointer('schemas')}}}})};
 const groups={schemas:{[oldName]:schema},parameters:{[oldName]:parameter},responses:{[oldName]:response},securitySchemes:{[oldName]:{type:'apiKey',in:'header',name:'X-Key'}}};
 const data={...(legacy?{swagger:version}:{openapi:version}),info:{title:'Names 雪😀',version:'1'},paths:{'/items':{get:{parameters:[{$ref:'#'+pointer('parameters')},{...parameter,name:'inline'}],responses:{200:{$ref:'#'+pointer('responses')},201:{description:'Inline',...(legacy?{schema}:{content:{'application/json':{schema}}})}}}}},security:[{[oldName]:[]}],
  ...(legacy?{definitions:groups.schemas,parameters:groups.parameters,responses:groups.responses,securityDefinitions:groups.securitySchemes}:{components:groups}),'x-payload':{Old:'literal','number':'EXACT'}};
 const encode=data=>(format==='json'?JSON.stringify(data,null,2):'# kept binding names 雪😀\r\n'+YAML.stringify(JSON.parse(JSON.stringify(data))).replaceAll('\n','\r\n')).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 const input={root,snapshot:'member-names',resources:[{id:root,text:encode(data),generation:3}],contexts:[{root,resources:[root]}]};
 return {...input,pointer,data,encode};
}
function capture(input,pointer){
 const doc=createGraph(input).docs.get(input.root),range=doc.node(pointer).range;
 return {root:input.root,resource:input.root,pointer,generation:input.resources[0].generation,range,expected:input.resources[0].text.slice(...range)};
}
function apply(input,plan){
 return input.resources.map(resource=>{
  let text=resource.text;
  for(const edit of plan.edits.filter(edit=>edit.buffer===resource.id).sort((a,b)=>b.start-a.start)){
   assert.equal(text.slice(edit.start,edit.end),edit.expected);text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
  }
  return {...resource,text};
 });
}
for(const format of ['yaml','json'])for(const name of ['clé/雪 ~😀 #?%',''])for(const group of ['schemas','parameters','responses','securitySchemes']){
 test(`Swagger reusable names retain native syntax through rename ${format} ${group} ${JSON.stringify(name)}`,()=>{
  const input=fixture('2.0',format),before=input.resources[0].text;
  assert.deepEqual(analyse(input).findings,[]);
  const plan=planRename({...input,target:capture(input,input.pointer(group)),name}),resources=apply(input,plan),after={...input,resources};
  const graph=createGraph(after).graph,destination=input.pointer(group).replace(/Old$/,escape(name));
  assert.equal(graph.issues.length,0);assert.deepEqual(analyse(after).findings,[]);
  assert(!createGraph(after).docs.get(input.root).nodes.has(input.pointer(group)));
  assert(createGraph(after).docs.get(input.root).nodes.has(destination));
  assert(graph.references.some(ref=>ref.targetPointer===destination));
  assert(resources[0].text.includes('9007199254740993.00'));
  assert(resources[0].text.includes(format==='json'?'"Old": "literal"':'Old: literal'));
  assert.equal(input.resources[0].text,before);
  const metadata=inspect({...after,resource:input.root,pointer:destination});
  assert.equal(metadata.componentDefinition,true);assert.equal(metadata.componentNamePolicy.allowEmpty,true);assert.equal(metadata.componentNamePolicy.pattern,undefined);
 });
}
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`modern component restrictions remain owned metadata ${version} ${format}`,()=>{
 const input=fixture(version,format),pointer=input.pointer('schemas'),map=pointer.slice(0,pointer.lastIndexOf('/'));
 const policy=inspect({...input,resource:input.root,pointer:map}).memberNamePolicy;
 assert.equal(policy.allowEmpty,false);assert(policy.pattern);
 const fragment=input.resources[0].text;
 for(const name of ['clé/雪 ~😀 #?%',''])assert.throws(()=>planRename({...input,target:capture(input,pointer),name}),e=>e.code==='refactor.name');
 assert.equal(fragment,input.resources[0].text);
});
for(const format of ['yaml','json'])for(const name of ['clé/雪 ~😀 #?%',''])for(const kind of ['schema','parameter','response'])test(`Swagger extraction supports native reusable names ${format} ${kind} ${JSON.stringify(name)}`,()=>{
 const input=fixture('2.0',format),pointer=kind==='schema'?'/paths/~1items/get/responses/201/schema':kind==='parameter'?'/paths/~1items/get/parameters/1':'/paths/~1items/get/responses/201';
 const plan=planExtract({...input,target:capture(input,pointer),name}),after={...input,resources:apply(input,plan)};
 assert.equal(createGraph(after).graph.issues.length,0);assert.deepEqual(analyse(after).findings,[]);
 assert(createGraph(after).docs.get(input.root).nodes.has('/'+({schema:'definitions',parameter:'parameters',response:'responses'})[kind]+'/'+escape(name)));
 assert.equal(input.resources[0].text,input.encode(input.data));
});
for(const format of ['yaml','json'])test(`Swagger existing empty reusable names remain maintainable ${format}`,()=>{
 const input=fixture('2.0',format,''),target=capture(input,input.pointer('responses'));
 assert.deepEqual(analyse(input).findings,[]);
 const renamed=planRename({...input,target,name:'Réponse 雪'});
 assert.equal(createGraph({...input,resources:apply(input,renamed)}).graph.issues.length,0);
 const moved=planMoveDefinition({...input,target,name:'Other'});
 assert.equal(createGraph({...input,resources:apply(input,moved)}).graph.issues.length,0);
});
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`response status naming belongs to its family ${version} ${format}`,()=>{
 const input=fixture(version,format),pointer='/paths/~1items/get/responses';
 const policy=inspect({...input,resource:input.root,pointer}).memberNamePolicy;
 assert.equal(new RegExp(policy.pattern).test('2XX'),version!=='2.0');
 assert(new RegExp(policy.pattern).test('200'));assert(new RegExp(policy.pattern).test('default'));
 const rename=()=>planResponseRename({...input,target:capture(input,pointer+'/201'),name:'2XX'});
 if(version==='2.0')assert.throws(rename,e=>e.code==='refactor.name');else assert(rename().edits.length>0);
});
for(const format of ['yaml','json'])for(const name of ['clé/雪 ~😀 #?%',''])for(const kind of ['parameter','response'])test(`Swagger named file extraction separates names from retrieval paths ${format} ${kind} ${JSON.stringify(name)}`,()=>{
 const input=fixture('2.0',format),pointer=kind==='parameter'?'/paths/~1items/get/parameters/1':'/paths/~1items/get/responses/201',destination='file:///project/parts/target.'+format;
 const plan=planExtractToFile({...input,target:capture(input,pointer),name,destinationResource:destination});
 const resources=[...apply(input,plan),...plan.creations.map(created=>({id:created.resource,text:created.text,generation:0,identity:created.identity}))];
 const after={...input,resources},graph=createGraph(after).graph;
 assert.equal(graph.issues.length,0);assert.deepEqual(analyse(after).findings,[]);
 const reference=graph.references.find(ref=>ref.resource===input.root&&ref.pointer===pointer);
 assert.equal(reference.targetResource,destination);assert.equal(reference.targetPointer,'/'+escape(name));
 assert(resources[0].text.includes('9007199254740993.00'));
 assert.equal(input.resources[0].text,input.encode(input.data));
});
