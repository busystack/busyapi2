const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {createGraph,analyse,inspect}=require('./dist/model.cjs');
const {planRename,planSchemaDefinitionRename}=require('./dist/refactoring.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
const versions=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];

function fixture(version,format){
 const root='file:///definitions/api.'+format,model='file:///definitions/parts/model.'+format;
 const pointer='/Envelope/$defs/Container/$defs/Old';
 const address='#/$defs/Container/$defs/Old';
 const value={type:'object',required:['n'],properties:{n:{type:'integer',enum:['EXACT']},next:{$ref:address}},additionalProperties:false,$anchor:'value'};
 const document={openapi:version,info:{title:'Definitions 雪😀',version:'1'},paths:{},components:{schemas:{
  Envelope:{$ref:'parts/model.'+format+'#/Envelope'},Direct:{$ref:'parts/model.'+format+'#'+pointer},
  Anchored:{$ref:'https://schemas.invalid/envelope#value'}}},
  'x-payload':{$defs:{Old:'literal'},$ref:'literal reference',number:'EXACT'}};
 const fragment={Envelope:{$id:'https://schemas.invalid/envelope',type:'object',properties:{value:{$ref:address}},$defs:{Container:{$defs:{Old:value}}}},
  'x-unrelated':{Old:'unrelated',number:'EXACT'}};
 const encode=value=>(format==='json'?JSON.stringify(value,null,2):'# retained unrelated comment 雪😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'))
  .replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 const resources=[{id:root,text:encode(document),generation:2},{id:model,text:encode(fragment),generation:4}];
 const input={root,snapshot:version+format,resources,contexts:[{root,resources:[root,model]}]};
 const doc=createGraph(input).docs.get(model),range=doc.node(pointer).range;
 return {...input,model,pointer,target:{root,resource:model,pointer,generation:4,range,expected:doc.text.slice(...range)}};
}
function apply(input,plan){
 return input.resources.map(resource=>{
  let text=resource.text;
  for(const edit of plan.edits.filter(edit=>edit.buffer===resource.id).sort((a,b)=>b.start-a.start)){
   assert.equal(text.slice(edit.start,edit.end),edit.expected);
   text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
  }
  return {...resource,text};
 });
}
async function behavior(input){
 const result=await evaluateSchemas({...input,runtimeInstances:['9007199254740993.00','9007199254740992.00'].map((number,index)=>({
  subject:'response-body',location:'definition-'+index,schema:{resource:input.model,pointer:'/Envelope'},text:'{"value":{"n":'+number+'}}'}))});
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.deepEqual(result.runtimeEvaluations.map(value=>[value.complete,value.valid]),[[true,true],[true,false]]);
}

for(const version of versions)for(const format of ['yaml','json'])for(const name of ['New','clé/雪 ~😀 #?%','','__proto__'])
test(`native $defs rename ${version} ${format} ${JSON.stringify(name)}`,async()=>{
 const input=fixture(version,format),before=input.resources.map(resource=>resource.text);
 assert.deepEqual(analyse(input).findings,[]);
 const metadata=inspect({...input,resource:input.model,pointer:input.pointer});
 assert.equal(metadata.componentDefinition,false);
 assert.deepEqual(metadata.schemaDefinitionNamePolicy,{allowEmpty:true,maxLength:4096});
 assert.deepEqual(inspect({...input,resource:input.model,pointer:input.pointer.slice(0,-4)}).memberNamePolicy,
  {allowEmpty:true,maxLength:4096});
 assert.throws(()=>planRename({...input,name}),error=>error.code==='refactor.name');
 const plan=planSchemaDefinitionRename({...input,name}),resources=apply(input,plan),after={...input,resources};
 assert.equal(plan.kind,'schema-definition-rename');
 const destination=input.pointer.slice(0,-3)+escape(name),graph=createGraph(after).graph;
 assert.equal(plan.to.pointer,destination);assert(plan.edits.length>0);assert(plan.usages.length>=3);
 assert.equal(graph.issues.length,0,JSON.stringify(graph.issues));assert.deepEqual(analyse(after).findings,[]);
 const doc=graph.docs.get(input.model);
 assert(!doc.nodes.has(input.pointer));assert(doc.nodes.has(destination));
 assert.equal(doc.dataJson('/x-unrelated'),createGraph(input).docs.get(input.model).dataJson('/x-unrelated'));
 assert.equal(graph.docs.get(input.root).dataJson('/x-payload'),createGraph(input).docs.get(input.root).dataJson('/x-payload'));
 for(const resource of resources)assert(resource.text.includes('9007199254740993.00'));
 if(format==='yaml')for(const resource of resources)assert(resource.text.startsWith('# retained unrelated comment 雪😀\r\n'));
 const anchored=graph.references.find(reference=>reference.pointer==='/components/schemas/Anchored');
 assert.equal(anchored.value,'https://schemas.invalid/envelope#value');assert.equal(anchored.targetPointer,destination);
 await behavior(input);await behavior(after);
 assert.deepEqual(input.resources.map(resource=>resource.text),before);
 const same=planSchemaDefinitionRename({...after,target:{...input.target,pointer:destination,range:doc.node(destination).range,expected:doc.text.slice(...doc.node(destination).range)},name});
 assert.deepEqual(same.edits,[]);
 assert.equal(same.kind,'schema-definition-rename');
});

for(const version of versions)for(const format of ['yaml','json'])test(`$defs ownership and collision refusals ${version} ${format}`,()=>{
 const input=fixture(version,format),original=input.resources.map(resource=>resource.text);
 for(const pointer of ['/x-payload/$defs/Old','/Envelope/properties/value','/Envelope/$defs'])
  assert.throws(()=>planSchemaDefinitionRename({...input,target:{...input.target,pointer,range:undefined,expected:undefined},name:'New'}),error=>['refactor.name','refactor.definition','refactor.schema-definition.context'].includes(error.code));
 assert.throws(()=>planSchemaDefinitionRename({...input,name:'x'.repeat(4097)}),error=>error.code==='refactor.name');
 const doc=createGraph(input).docs.get(input.model),text=doc.set('/Envelope/$defs/Container/$defs/New',false);
 const collision={...input,resources:input.resources.map(resource=>resource.id===input.model?{...resource,text}:resource)};
 assert.throws(()=>planSchemaDefinitionRename({...collision,target:{...input.target,range:undefined,expected:undefined},name:'New'}),error=>error.code==='edit.collision');
 assert.deepEqual(input.resources.map(resource=>resource.text),original);
});

for(const version of ['2.0','3.0.4'])for(const format of ['yaml','json'])test(`$defs is not a native older-family definition ${version} ${format}`,()=>{
 const input=fixture('3.1.2',format),root=input.resources[0];
 const value=YAML.parse(root.text);delete value.openapi;value[version==='2.0'?'swagger':'openapi']=version;
 if(version==='2.0'){value.definitions=value.components.schemas;delete value.components;}
 root.text=format==='json'?JSON.stringify(value):YAML.stringify(value);
 assert.throws(()=>planSchemaDefinitionRename({...input,target:{...input.target,range:undefined,expected:undefined},name:'New'}),error=>{
  assert.equal(error.code,'refactor.schema-definition.context');assert.deepEqual(error.source.range,input.target.range);return true;
 });
});

for(const version of versions)test(`aliased $defs retains physical ownership ${version}`,()=>{
 const input=fixture(version,'yaml'),resource=input.resources[1],doc=YAML.parseDocument(resource.text);
 const value=doc.getIn(['Envelope','$defs','Container','$defs','Old'],true);
 value.anchor='shared';doc.set('x-shared',doc.createAlias(value));resource.text=doc.toString();
 const original=resource.text;
 assert.throws(()=>planSchemaDefinitionRename({...input,target:{...input.target,range:undefined,expected:undefined},name:'New'}),
  error=>error.code==='refactor.definition');
 assert.equal(resource.text,original);
});

for(const version of versions)test(`unsupported $defs dialect is not silently reinterpreted ${version}`,()=>{
 const input=fixture(version,'json'),resource=input.resources[0],value=JSON.parse(resource.text);
 value.jsonSchemaDialect='https://unsupported.invalid/schema';resource.text=JSON.stringify(value);
 const original=resource.text;
 const metadata=inspect({...input,resource:input.root,pointer:'/components/schemas/Envelope'});
 assert.equal(metadata.schemaDefinitionNamePolicy,undefined);
 assert.throws(()=>inspect({...input,resource:input.model,pointer:input.pointer}),error=>error.code==='inspect.context');
 assert.throws(()=>planSchemaDefinitionRename({...input,name:'New'}),error=>error.code==='refactor.schema-definition.context');
 assert.equal(resource.text,original);
});

for(const format of ['yaml','json'])test(`mixed modern roots coalesce shared $defs repairs ${format}`,()=>{
 const input=fixture('3.1.2',format),root='file:///definitions/other.'+format;
 const value={openapi:'3.2.1',info:{title:'Other root',version:'1'},paths:{},components:{schemas:{
  Envelope:{$ref:'parts/model.'+format+'#/Envelope'},Direct:{$ref:'parts/model.'+format+'#'+input.pointer}}}};
 input.resources.push({id:root,text:format==='json'?JSON.stringify(value):YAML.stringify(value),generation:6});
 input.contexts.push({root,resources:[root,input.model]});
 for(const context of input.contexts)
  assert.equal(createGraph({...input,root:context.root,resources:input.resources.filter(resource=>context.resources.includes(resource.id))}).graph.issues.length,0);
 const plan=planSchemaDefinitionRename({...input,name:'New'}),resources=apply(input,plan);
 assert.deepEqual(plan.checkedRoots,[input.root,root]);
 for(const context of input.contexts){
  const checked={...input,root:context.root,resources:resources.filter(resource=>context.resources.includes(resource.id))};
  assert.equal(createGraph(checked).graph.issues.length,0);assert.deepEqual(analyse(checked).findings,[]);
 }
});
