const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas,schemaProducer}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {pointerFragment}=require('./dist/reference_graph.cjs');
const targets=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
const render=(value,format)=>(format==='json'?JSON.stringify(value):'# Keep exact model organization 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace(/"?EXACT"?/g,'9007199254740993.00');
function fixture(format,mode,targetVersion){
 const root='file:///approved/root/api.'+format,shared='file:///approved/shared/model.'+format,external=mode==='external';
 const cat=mode==='names'?'Cat/~雪':'Cat',catPointer='/definitions/'+escape(cat),ref=pointer=>({$ref:pointerFragment(pointer)});
 const base={...(mode==='permissive'?{}:{type:'object'}),discriminator:'kind',required:['kind'],properties:{kind:{type:'string'},next:{$ref:external?'#/Base':'#/definitions/Base'}},description:'[Base guide](./guide.md)',externalDocs:{url:'./model-guide.md'}};
 const catModel={description:'Cat model',allOf:[{$ref:external?'../shared/model.'+format+'#/Base':'#/definitions/Base'},{type:'object',required:['value'],properties:{value:{type:'integer',minimum:'EXACT'}}}]};
 if(mode==='multi'){catModel.discriminator='subkind';catModel.required=['subkind'];catModel.properties={subkind:{type:'string'}};}
 const definitions=Object.fromEntries([
  ['Base',external?{$ref:'../shared/model.'+format+'#/Base'}:base],
  [cat,catModel],
  ['Dog',{allOf:[{$ref:external?'../shared/model.'+format+'#/Base':'#/definitions/Base'},{type:'object',required:['flag'],properties:{flag:{type:'boolean'}}}]}],
  ['Alias',ref(catPointer)],
  ['__proto__',ref(catPointer)],
  ...(mode==='multi'?[['Grand',{allOf:[ref(catPointer),{type:'object',required:['extra'],properties:{extra:{type:'boolean'}}}]}]]:[]),
 ]);
 const document={swagger:'2.0',info:{title:'Original models',version:'business'},host:'api.invalid',schemes:['https'],produces:['application/json'],paths:{'/model':{get:{responses:{200:{description:'Model',schema:ref('/definitions/Base')}}}}},definitions,'x-exact':'EXACT','x-payload':{discriminator:'do-not-interpret',$ref:'missing-payload-only',kind:cat}};
 return {input:{root,snapshot:'swagger-discriminator',targetVersion,destination:'file:///reviewed/api/',resources:[{id:root,text:render(document,format),generation:3},...(external?[{id:shared,text:render({Base:base},format),generation:5}]:[])]},cat,catPointer};
}
function samples(cat,multi){
 const encode=value=>JSON.stringify(value).replaceAll('"EXACT"','9007199254740993.00').replaceAll('"LOW"','9007199254740992');
 const selected=(kind,value='EXACT',extra={})=>({kind,value,...(multi?{subkind:'Cat'}:{}),...extra});
 return [
  encode({kind:'Base'}),encode(selected(cat)),encode(selected(cat,'LOW')),encode({kind:cat}),
  encode({kind:'Dog',flag:true}),encode({kind:'Dog',flag:0}),encode({kind:'Unknown',value:'EXACT'}),
  '{}',encode({kind:0}),encode(selected('Alias')),encode(selected('__proto__')),
  encode(selected(cat,'EXACT',{next:{kind:'Dog',flag:true}})),
  encode(selected(cat,'EXACT',{next:{kind:'Unknown',value:'EXACT'}})),
  encode(selected(cat,'EXACT',{next:selected(cat,'LOW')})),
  'null','false','0','[]','"雪"',
  ...(multi?[encode(selected('Cat','EXACT',{subkind:'Grand',extra:true})),encode(selected('Cat','EXACT',{subkind:'Grand'}))]:[]),
 ];
}
async function evaluate(input,pointer,texts){
 const result=await evaluateSchemas({...input,runtimeInstances:['request-body','response-body'].flatMap(subject=>texts.map(text=>({subject,text,location:'application/json',schema:{resource:input.root,pointer}})))});
 assert.equal(result.complete,true,JSON.stringify(result.findings));return result.runtimeEvaluations.map(value=>value.valid);
}
for(const targetVersion of targets)for(const format of ['yaml','json'])for(const mode of ['plain','external','names','multi','permissive'])
test(`Swagger ${format} ${mode} -> ${targetVersion} specializes dispatch without flattening accepted values`,async()=>{
 const {input,cat,catPointer}=fixture(format,mode,targetVersion),original=input.resources.map(value=>value.text),texts=samples(cat,mode==='multi');
 const before=await evaluate(input,'/definitions/Base',texts),plan=await planMigration(input);
 assert.equal(plan.complete,true,JSON.stringify(plan.problems));assert.equal(plan.status,'faithfully-convertible');assert.equal(plan.producerVersion,'33');
 const output={root:plan.outputRoot,snapshot:'cold-dispatch',resources:plan.outputs.map(value=>({id:value.id,text:value.text,generation:0,aliases:Object.entries(plan.manifest.resourceMappings).filter(([,path])=>path===value.path).map(([uri])=>uri)}))};
 assert.equal(analyse(output).status,'complete',JSON.stringify(analyse(output).findings));
 assert.deepEqual(await evaluate(output,'/components/schemas/Base',texts),before);
 assert.equal(before[0],true);assert.equal(before[1],true);assert.equal(before[2],false);assert.equal(before[3],false);assert.equal(before[4],true);assert.equal(before[5],false);assert.equal(before[6],false);assert.equal(before[11],true);assert.equal(before[12],false);assert.equal(before[13],false);
 assert.equal(before[14],mode==='permissive');
 const graph=createGraph(output).graph,schemas=graph.docs.get(output.root).dataNode('/components/schemas').value;
 assert(Object.keys(schemas).some(name=>name.startsWith('_migrated_selection_')));
 assert(graph.references.every(value=>value.resolution==='resolved'));assert(plan.outputs.some(value=>value.text.includes('9007199254740993.00')));
 for(const scope of graph.scopesFor('schema')){
  const value=graph.docs.get(scope.resource).dataNode(scope.pointer).value;
  if(value?.discriminator)assert(value.anyOf.every(branch=>typeof branch.$ref==='string'),'Every target discriminator choice must be listed as an explicit named schema');
 }
 if(mode!=='names'){
  const sibling=JSON.stringify({kind:'Dog',flag:true,value:'EXACT',...(mode==='multi'?{subkind:'Cat'}:{})}).replace('"EXACT"','9007199254740993.00');
  const source=await evaluate(input,catPointer,[sibling]),target=await evaluate(output,'/components/schemas/Cat',[sibling]);
  assert(source.every(Boolean));assert.deepEqual(target,source,'A direct Cat must still apply Base dispatch and its own constraints');
 }
 if(mode==='names')assert(Object.keys(schemas).every(name=>/^[A-Za-z0-9._-]+$/.test(name)));
 if(mode==='external'){
  assert(plan.outputs.some(value=>value.text.includes('file:///approved/shared/model-guide.md')));
  assert(plan.outputs.some(value=>value.text.includes('file:///approved/shared/guide.md')));
 }
 assert.deepEqual(input.resources.map(value=>value.text),original);
 const repeated=await planMigration(input);assert.equal(repeated.identity,plan.identity);assert.deepEqual(repeated.outputs,plan.outputs);
});

for(const format of ['yaml','json'])test(`${format} shared entry namespaces need their own specialization instead of choosing one table`,async()=>{
 const root='file:///approved/a.'+format,other='file:///approved/b.'+format,shared='file:///approved/model.'+format;
 const doc=name=>({swagger:'2.0',info:{title:name,version:'1'},paths:{},definitions:{Base:{$ref:'./model.'+format+'#/Base'},[name]:{allOf:[{$ref:'./model.'+format+'#/Base'}]}}});
 const resources=[{id:root,text:render(doc('Cat'),format),generation:1},{id:other,text:render(doc('Dog'),format),generation:1},{id:shared,text:render({Base:{type:'object',discriminator:'kind',required:['kind'],properties:{kind:{type:'string'}}}},format),generation:1}],before=resources.map(value=>value.text);
 const result=await planMigration({root,snapshot:'shared-dispatch',resources,targetVersion:'3.0.4',destination:'file:///reviewed/'});
 assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(value=>value.code==='migration.discriminator.shared-context'&&value.reason==='implementation'),JSON.stringify(result.problems));
 assert.deepEqual(resources.map(value=>value.text),before);
});

for(const format of ['yaml','json'])test(`${format} incomplete named-model selection cannot validate or publish a partial table`,async()=>{
 const {input}=fixture(format,'plain','3.0.4'),doc=new SourceDocument(input.resources[0].text,input.root);
 input.resources[0].text=doc.set('/definitions/Missing',{$ref:'./unavailable.'+format});const before=input.resources[0].text;
 const result=await planMigration(input);assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(value=>value.code==='migration.validation.incomplete'));
 assert.equal(input.resources[0].text,before);
});

test('bounded model selection is incomplete rather than silently omitting an inherited name',async()=>{
 const {input}=fixture('json','plain','3.0.4');let doc=new SourceDocument(input.resources[0].text,input.root);
 for(let index=0;index<130;index++)doc=new SourceDocument(doc.set('/definitions/Chain'+index,{$ref:index===129?'#/definitions/Base':'#/definitions/Chain'+(index+1)}),input.root);
 input.resources[0].text=doc.text;
 const result=await evaluateSchemas(input);assert.equal(result.complete,false);assert(result.findings.some(value=>value.code==='limit.schema.discriminator'));
 const plan=await planMigration(input);assert.equal(plan.complete,false);assert.deepEqual(plan.outputs,[]);
});
test('model completeness identifies the current evaluator rules and excludes obsolete rules',()=>{
 assert.equal(schemaProducer.version,'1.18.0+46');
 const configuration=schemaProducer.configuration.split(':');
 assert.equal(configuration.filter(value=>value==='discriminator-models-v2').length,1);
 assert(!configuration.includes('swagger-discriminator-models-v1'));
 assert(!configuration.includes('discriminator-models-v1'));
});

test('native mock admission rejects a complete proof with only obsolete discriminator rules',{timeout:20000},async t=>{
 const fs=require('node:fs/promises'),os=require('node:os'),path=require('node:path');
 const {mockStart,startMock}=require('./mock_test_capture.cjs');
 const input=mockStart({openapi:'3.0.4',info:{title:'Discriminator proof',version:'1'},paths:{'/value':{post:{responses:{204:{description:'Empty'}}}}}});
 const proof=await evaluateSchemas(input.capture);
 assert.equal(proof.complete,true,JSON.stringify(proof.findings));
 assert.equal(proof.configuration,schemaProducer.configuration);
 assert(!proof.findings.some(finding=>finding.severity==='error'));
 const obsolete={...proof,configuration:proof.configuration.replace('discriminator-models-v2','swagger-discriminator-models-v1')};
 assert.notEqual(obsolete.configuration,proof.configuration);
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'busyapi-discriminator-proof-'));
 t.after(()=>fs.rm(directory,{recursive:true,force:true}));
 // The unmodified BusyAPI mock consumes a controlled old wire proof. The real
 // current evaluator above supplies every other field, including the capture.
 const worker=`const {parentPort}=require('node:worker_threads');
const assert=require('node:assert/strict');
const capture=${JSON.stringify(input.capture)};
const proof=${JSON.stringify(obsolete)};
parentPort.on('message',request=>{
 assert.equal(request.method,'evaluateSchemas');assert.deepEqual(request.params,capture);
 const payload=new TextEncoder().encode(JSON.stringify({protocol:1,id:request.id,ok:true,result:proof}));
 parentPort.postMessage(payload,[payload.buffer]);
});\n`;
 await fs.writeFile(path.join(directory,'engine.cjs'),worker);
 const helper=path.join(directory,'mock-server.cjs');
 await fs.copyFile(path.join(__dirname,'dist/mock-server.cjs'),helper);
 const before=JSON.stringify(input),result=await startMock(t,input,{helper,failure:true});
 assert.equal(result.event,'failed');assert.equal(result.failure.code,'mock.validation.revision');
 assert.equal(JSON.stringify(input),before);
});


for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} an existing discriminator URI mapping survives changed output retrieval`,async()=>{
 const root='file:///approved/mapped.'+format,targetVersion=version==='3.2.1'?'3.1.2':'3.2.1';
 const value={openapi:version,info:{title:'Mapping',version:'1'},paths:{},components:{schemas:{Base:{type:'object',required:['kind'],properties:{kind:{type:'string'}},anyOf:[{$ref:'#/components/schemas/Model'}],discriminator:{propertyName:'kind',mapping:{Model:root+'#/components/schemas/Model'}}},Model:{type:'object',properties:{kind:{enum:['Model']}}}}}};
 const text=render(value,format),input={root,snapshot:'mapping-uri',resources:[{id:root,text,generation:1}],targetVersion,destination:'file:///reviewed/map/'};
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));
 const output={root:result.outputRoot,snapshot:'cold-map',resources:result.outputs.map(value=>({id:value.id,text:value.text,generation:0}))},graph=createGraph(output).graph;
 const mapping=graph.references.find(value=>value.connection==='discriminator');assert(mapping);assert.equal(mapping.resolution,'resolved');assert.equal(mapping.targetResource,output.root);assert.equal(mapping.targetPointer,'/components/schemas/Model');assert(!mapping.value.startsWith(root));
 assert.equal(input.resources[0].text,text);
});


for(const format of ['yaml','json'])test(`${format} specialized CST copies retain converted type unions and exact enum/default payload provenance`,async()=>{
 const {input}=fixture(format,'plain','3.2.1');let doc=new SourceDocument(input.resources[0].text,input.root);
 doc=new SourceDocument(doc.set('/definitions/Base/type',['object','string']),input.root);
 doc=new SourceDocument(doc.set('/definitions/Base/default','text'),input.root);
 doc=new SourceDocument(doc.set('/definitions/Base/enum',[{kind:'Base',n:'EXACT',flag:false,zero:0,empty:'',$ref:'payload-only',discriminator:'literal'},'text']),input.root);
 input.resources[0].text=doc.text.replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
 const before=input.resources[0].text,texts=['"text"','"other"','{"kind":"Base","n":9007199254740993.00,"flag":false,"zero":0,"empty":"","$ref":"payload-only","discriminator":"literal"}','{"kind":"Base","n":9007199254740992,"flag":false,"zero":0,"empty":"","$ref":"payload-only","discriminator":"literal"}'];
 const source=await evaluate(input,'/definitions/Base',texts),plan=await planMigration(input);assert.equal(plan.complete,true,JSON.stringify(plan.problems));
 const output={root:plan.outputRoot,snapshot:'copy-provenance',resources:plan.outputs.map(value=>({...value,generation:0}))};
 assert.deepEqual(await evaluate(output,'/components/schemas/Base',texts),source);assert.deepEqual(source.slice(0,4),[true,false,true,false]);
 const target=createGraph(output).graph;
 for(const scope of target.scopesFor('schema')){
  const resource=target.docs.get(scope.resource),node=resource.dataNode(scope.pointer+'/enum');
  if(node?.value?.[0]?.$ref==='payload-only')assert(resource.dataJson(node.pointer).includes('9007199254740993.00'));
 }
 assert(!target.references.some(value=>value.value==='payload-only'));assert.equal(input.resources[0].text,before);
});


for(const format of ['yaml','json'])test(`${format} an ordinary non-discriminator Swagger model also receives a legal preserving key`,async()=>{
 const root='file:///approved/names.'+format,name='値/~雪',pointer='/definitions/'+escape(name),value={swagger:'2.0',info:{title:'Names',version:'1'},paths:{},definitions:{[name]:{type:'integer',minimum:'EXACT'},Use:{$ref:pointerFragment(pointer)}}};
 const text=render(value,format),input={root,snapshot:'ordinary-schema-name',resources:[{id:root,text,generation:1}],targetVersion:'3.0.4',destination:'file:///reviewed/names/'};
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));
 const output={root:result.outputRoot,snapshot:'cold-names',resources:result.outputs.map(value=>({...value,generation:0}))},graph=createGraph(output).graph,schemas=graph.docs.get(output.root).dataNode('/components/schemas');
 assert([...schemas.children.keys()].every(name=>/^[A-Za-z0-9._-]+$/.test(name)));
 const ref=graph.references.find(value=>value.pointer==='/components/schemas/Use');assert(ref);assert.equal(ref.resolution,'resolved');
 const samples=['9007199254740993.00','9007199254740992'];
 assert.deepEqual(await evaluate(output,'/components/schemas/Use',samples),await evaluate(input,'/definitions/Use',samples));
 assert.equal(input.resources[0].text,text);
});
