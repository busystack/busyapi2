const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {planExtractToFile}=require('./dist/refactoring_copy.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {createGraph,inspect,analyse}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
function apply(input,plan){
 return [...input.resources.map(resource=>{let text=resource.text;for(const edit of plan.edits.filter(edit=>edit.buffer===resource.id).sort((a,b)=>b.start-a.start)){assert.equal(text.slice(edit.start,edit.end),edit.expected);text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);}return {...resource,text};}),...plan.creations.map(created=>({id:created.resource,text:created.text,generation:0}))];
}
const pointer='/paths/~1items/get/responses/200/content/application~1json/schema';
for(const json of [false,true])for(const kind of ['response','body','query'])for(const external of [false,true])test(`Swagger named fragment extraction preserves native ${kind} semantics ${json?'JSON':'YAML'} external=${external}`,async()=>{
 const ext=json?'json':'yaml',root='file:///project/api.'+ext,part='file:///project/part.'+ext,destination='file:///project/shared%20%E9%9B%AA.'+ext;
 const at=kind==='response'?'/paths/~1items/get/responses/200':'/paths/~1items/get/parameters/0',schema={$ref:(external?'api.'+ext:'')+'#/definitions/Model'};
 const authored=kind==='response'?{description:'Recursive 雪 response',schema,examples:{'application/json':{value:'EXACT_NUMBER',$ref:'literal payload'}}}:kind==='body'?{name:'payload',in:'body',schema}:{name:'q',in:'query',type:'array',items:{type:'integer',minimum:'EXACT_NUMBER'},collectionFormat:'multi'};
 const operation=kind==='response'?{responses:{200:external?{$ref:'part.'+ext+'#/Inline'}:authored}}:{parameters:[external?{$ref:'part.'+ext+'#/Inline'}:authored],responses:{204:{description:'Empty'}}};
 const document={swagger:'2.0',info:{title:'Named fragments',version:'1'},produces:['application/json'],paths:{'/items':{get:operation}},definitions:{Model:{type:'object',required:['value'],properties:{value:{type:'integer',minimum:'EXACT_NUMBER'},next:{$ref:'#/definitions/Model'}}}},'x-preserved':{$ref:'literal extension'}};
 const encode=value=>(json?JSON.stringify(value,null,2):'# preserve 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll('"EXACT_NUMBER"','9007199254740993.00').replaceAll('EXACT_NUMBER','9007199254740993.00');
 const resources=[{id:root,text:encode(document),generation:3},...(external?[{id:part,text:encode({Inline:authored}),generation:4}]:[])];
 const input={root,snapshot:'swagger-file',resources,contexts:[{root,resources:resources.map(r=>r.id)}],target:{root,resource:external?part:root,pointer:external?'/Inline':at,generation:external?4:3},name:'Stored',destinationResource:destination};
 const frozen=JSON.stringify(resources),before=new SourceDocument(resources[0].text,root),plan=planExtractToFile(input),after=apply(input,plan),api=new SourceDocument(after[0].text,root),created=new SourceDocument(after.at(-1).text,destination);
 assert.deepEqual(plan.binding,{resource:destination,pointer:'/Stored'});assert.deepEqual(plan.to,{resource:destination,pointer:'/Stored'});
 assert(!api.nodes.has('/responses/Stored'));assert(!api.nodes.has('/parameters/Stored'));
 assert.equal(created.nodes.has('/swagger'),false);assert.equal(created.nodes.has('/components'),false);
 assert.equal(api.text.slice(...api.node('/definitions/Model').range),before.text.slice(...before.node('/definitions/Model').range));
 const replaced=new SourceDocument(after.find(r=>r.id===input.target.resource).text,input.target.resource);
 assert.equal(replaced.node(input.target.pointer+'/$ref').value,'shared%20%E9%9B%AA.'+ext+'#/Stored');
 assert(created.text.includes('9007199254740993.00')||kind==='body');
 if(kind!=='query')assert.equal(created.node('/Stored/schema/$ref').value,'api.'+ext+'#/definitions/Model');
 const graph=createGraph({root,resources:after}).graph;assert.deepEqual(graph.issues,[]);assert(graph.references.every(ref=>ref.resolution==='resolved'));
 const analysis=analyse({root,resources:after});assert.equal(analysis.status,'complete',JSON.stringify(analysis.findings));
 assert.equal(JSON.stringify(resources),frozen);assert.equal(plan.creations.length,1);assert(!plan.edits.some(edit=>edit.buffer===destination));
 if(kind!=='query')for(const [captured,resource,pointer]of [[resources,input.target.resource,input.target.pointer+'/schema'],[after,destination,'/Stored/schema']]){
  const evaluated=await evaluateSchemas({root,snapshot:'extraction-invariants',resources:captured,runtimeInstances:['{"value":9007199254740993}','{"value":9007199254740994,"next":{"value":9007199254740993}}','{"value":9007199254740992}'].map(text=>({subject:'response-body',location:'application/json',text,schema:{resource,pointer}}))});
  assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.deepEqual(evaluated.runtimeEvaluations.map(e=>e.valid),[true,true,false]);
 }
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const boolean of [false,true])test(`new fragment extraction composes proved edits without API scaffolding ${version} ${json?'JSON':'YAML'} boolean=${boolean}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,destination='file:///project/model%20%E9%9B%AA.'+ext;
 const schema=boolean?false:{type:'object',properties:{value:{type:'integer'}},examples:[{value:111,$ref:'literal payload'}],'x-data':{$ref:'literal extension'}};
 const document={openapi:version,info:{title:'New fragment 雪😀',version:'1'},paths:{'/items':{get:{responses:{200:{description:'OK',content:{'application/json':{schema}}},204:{description:'Bodyless'}}}}}};
 const source=(json?JSON.stringify(document,null,2):'# preserve\r\n'+YAML.stringify(document)).replace('111','900719925474099312345678901');
 const input={snapshot:'extract-file',resources:[{id:root,text:source,generation:3}],contexts:[{root,resources:[root]}],target:{root,resource:root,pointer,generation:3},name:'Stored',destinationResource:destination};
 const plan=planExtractToFile(input),resources=apply(input,plan),created=new SourceDocument(resources[1].text,destination),api=new SourceDocument(resources[0].text,root);
 assert.equal(plan.kind,'component-extract-file');assert.equal(plan.creations.length,1);assert.equal(plan.creations[0].resource,destination);
 assert.equal(created.nodes.has('/openapi'),false);assert.equal(created.nodes.has('/components'),false);assert.equal(created.dataJson(''),new SourceDocument(source,root).dataJson(pointer));
 assert.equal(api.node(pointer+'/$ref').value,'#/components/schemas/Stored');
 assert.equal(api.node('/components/schemas/Stored/$ref').value,'model%20%E9%9B%AA.'+ext+'#');
 assert.equal(api.nodes.has('/paths/~1items/get/responses/204/content'),false);
 assert.equal(plan.changes.find(change=>change.resource===destination).fileAction,'create');assert.equal(plan.transitions[0].toResource,destination);assert.equal(plan.transitions[0].to,'');
 assert.equal(input.resources[0].text,source);assert(!plan.edits.some(edit=>edit.buffer===destination));
 const graph=createGraph({root,resources}).graph;assert.deepEqual(graph.issues,[]);assert(graph.references.every(ref=>ref.resolution==='resolved'));
 const page=inspect({root,resources,resource:destination,pointer:'',snapshot:'new-definition'});assert.equal(page.sharedTarget,true);assert.equal(page.componentDestination,false);
 assert.throws(()=>planExtractToFile({...input,resources:[...input.resources,{id:destination,text:'not replaceable',generation:4}]}),error=>error.code==='edit.collision');
 assert.throws(()=>planExtractToFile({...input,destinationResource:'file:///project/busyapi.yaml'}),error=>error.code==='refactor.extract.destination');
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`new fragment destinations retain reusable object-family meanings ${version} ${json?'JSON':'YAML'}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,destination='file:///project/shared.'+ext;
 const parameter={name:'q',in:'query',schema:{type:'string'}},header={description:'Header',schema:false},response={description:'Bodyless'},body={content:{'application/json':{schema:false}}},example={value:{$ref:'payload data',openapi:'payload only',number:111}},link={operationId:'getItems',requestBody:'$request.body#/id'},callback={'{$request.query.callback}':{post:{responses:{204:response}}}},pathItem={get:{responses:{204:response}}};
 const examples={Payload:example},media={schema:false,examples};
 const cases=[['parameters','/paths/~1items/get/parameters/0',parameter],['headers','/paths/~1items/get/responses/200/headers/X',header],['responses','/paths/~1items/get/responses/204',response],['requestBodies','/paths/~1items/get/requestBody',body],['examples','/paths/~1items/get/responses/200/content/application~1json/examples/Payload',example],['links','/paths/~1items/get/responses/200/links/Follow',link],['callbacks','/paths/~1items/get/callbacks/Report',callback],['pathItems','/paths/~1hooks',pathItem],...(version.startsWith('3.2')?[['mediaTypes','/paths/~1items/get/responses/200/content/application~1json',media]]:[])];
 for(const [family,at,authored]of cases){
  const document={openapi:version,info:{title:'Family',version:'1'},paths:{'/items':{get:{operationId:'getItems',parameters:[parameter],requestBody:body,callbacks:{Report:callback},responses:{200:{description:'OK',headers:{X:header},links:{Follow:link},content:{'application/json':media}},204:response}}},'/hooks':pathItem}};
  // Each authored occurrence is independent. YAML.stringify otherwise turns
  // this fixture's reused JS objects into aliases, which correctly require a
  // different, explicit ownership decision before source refactoring.
  const text=(json?JSON.stringify(document,null,2):YAML.stringify(JSON.parse(JSON.stringify(document)))).replaceAll('111','900719925474099312345678901'),input={root,snapshot:'family-file',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,pointer:at,generation:1},name:'Stored',destinationResource:destination};
  let plan;try{plan=planExtractToFile(input);}catch(error){error.message=family+': '+error.message;throw error;}
  const resources=apply(input,plan),definition=new SourceDocument(resources[1].text,destination),api=new SourceDocument(resources[0].text,root);
  assert.equal(api.node('/components/'+family+'/Stored/$ref').value,'shared.'+ext+'#',family);
  if(family==='links'){assert.equal(definition.nodes.has('/operationId'),false);assert.equal(definition.node('/operationRef').value,'root.'+ext+'#/paths/~1items/get');assert.equal(definition.node('/requestBody').value,authored.requestBody);}
  else assert.equal(definition.dataJson(''),new SourceDocument(text,root).dataJson(at),family);
  if(family==='headers'){assert.equal(definition.nodes.has('/name'),false);assert.equal(definition.nodes.has('/in'),false);}
  if(family==='responses')assert.equal(definition.nodes.has('/content'),false);
  assert.deepEqual(createGraph({root,resources}).graph.issues,[],family);assert.equal(input.resources[0].text,text);
 }
});
for(const json of [false,true])test(`a schema authored inside a referenced parameter extracts through the entry binding ${json?'JSON':'YAML'}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,part='file:///project/parameter.'+ext,destination='file:///project/schema.'+ext;
 const api={openapi:'3.2.1',info:{title:'External source',version:'1'},paths:{'/items':{get:{parameters:[{$ref:'parameter.'+ext}],responses:{204:{description:'Bodyless'}}}}}};
 const parameter={name:'q',in:'query',schema:{type:'array',items:{type:'integer'},examples:[[111]]}},encode=value=>(json?JSON.stringify(value,null,2):YAML.stringify(value)).replaceAll('111','900719925474099312345678901');
 const resources=[{id:root,text:encode(api),generation:1},{id:part,text:encode(parameter),generation:2}],input={root,snapshot:'external-inline',resources,contexts:[{root,resources:[root,part]}],target:{root,resource:part,pointer:'/schema',generation:2},name:'Query',destinationResource:destination};
 const plan=planExtractToFile(input),after=apply(input,plan),graph=createGraph({root,resources:after}).graph;
 assert.deepEqual(plan.binding,{resource:root,pointer:'/components/schemas/Query'});assert.equal(graph.issues.length,0);assert.equal(new SourceDocument(after[2].text,destination).dataJson(''),new SourceDocument(resources[1].text,part).dataJson('/schema'));
 assert.equal(graph.references.find(ref=>ref.resource===part&&ref.pointer==='/schema').targetResource,root);assert.equal(plan.transitions[0].resource,part);assert.equal(plan.transitions[0].toResource,destination);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`new fragment keeps owned recursive identities and actual instance outcomes ${version} ${json?'JSON':'YAML'}`,async()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,destination='file:///project/node.'+ext;
 const schema={$id:'node-resource',$dynamicAnchor:'node',type:'object',properties:{value:{type:'integer'},child:{$dynamicRef:'#node'}},required:['value'],unevaluatedProperties:false,examples:[{value:1,child:{value:2}},{value:1,child:{value:'invalid'}}]};
 const document={openapi:version,info:{title:'Owned resource',version:'1'},paths:{'/items':{get:{responses:{200:{description:'OK',content:{'application/json':{schema}}}}}}}};
 const text=json?JSON.stringify(document,null,2):YAML.stringify(document),input={root,snapshot:'owned-extract',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,pointer,generation:1},name:'Node',destinationResource:destination};
 const before=await evaluateSchemas(input),plan=planExtractToFile(input),resources=apply(input,plan),after=await evaluateSchemas({...input,resources});
 assert.equal(before.complete,true);assert.equal(after.complete,true);assert.deepEqual(before.evaluations.map(value=>value.valid),[true,false]);assert.deepEqual(after.evaluations.map(value=>value.valid),[true,false]);
 assert.equal(new SourceDocument(resources[1].text,destination).node('/$id').value,'file:///project/node-resource');
 assert.equal(new SourceDocument(resources[1].text,destination).node('/properties/child/$dynamicRef').value,'#node');
});
test('unknown schema keywords cannot acquire OpenAPI operations merely by moving to a file root',()=>{
 const root='file:///project/root.json',schema={type:'string',openapi:'3.2.1',paths:{'/fake':{get:{operationId:'mustNotIndex'}}}};
 const document={openapi:'3.2.1',info:{title:'Opaque keywords',version:'1'},paths:{'/items':{get:{responses:{200:{description:'OK',content:{'application/json':{schema}}}}}}}};
 const text=JSON.stringify(document),input={root,snapshot:'schema-keywords',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,pointer,generation:1},name:'Stored',destinationResource:'file:///project/new.json'};
 assert.throws(()=>planExtractToFile(input),error=>error.code==='refactor.copy.resource-context');
 assert.equal(input.resources[0].text,text);assert(![...createGraph(input).graph.scopes.values()].some(scope=>scope.pointer.includes('/fake')));
});
for(const version of ['3.1.2','3.2.1'])test(`new binding remains reachable through every original root ${version}`,()=>{
 const first='file:///project/first.json',second='file:///project/second.json',shared='file:///project/shared.json',destination='file:///project/child.json';
 const text=JSON.stringify({openapi:version,info:{title:'Shared',version:'1'},paths:{},components:{schemas:{Model:{$ref:'shared.json#/Model'}}}});
 const resources=[{id:first,text,generation:1},{id:second,text,generation:1},{id:shared,text:'{"Model":{"properties":{"child":{"type":"integer","examples":[900719925474099312345678901]}}}}',generation:4}];
 const contexts=[{root:first,resources:[first,shared]},{root:second,resources:[second,shared]}],input={snapshot:'shared-extraction',resources,contexts,target:{root:first,resource:shared,pointer:'/Model/properties/child',generation:4},name:'Child',destinationResource:destination};
 const plan=planExtractToFile(input),after=apply(input,plan);
 assert.deepEqual(plan.checkedRoots,[first,second]);assert.deepEqual(plan.binding,{resource:first,pointer:'/components/schemas/Child'});
 for(const root of [first,second]){
  const graph=createGraph({root,resources:after}).graph;
  assert.deepEqual(graph.issues,[]);assert(graph.references.every(ref=>ref.resolution==='resolved'));
  assert.equal(graph.references.find(ref=>ref.resource===shared&&ref.pointer==='/Model/properties/child').targetResource,first);
 }
 assert.equal(after.find(resource=>resource.id===second).text,text);
 assert.equal(new SourceDocument(after.at(-1).text,destination).dataJson('/examples/0'),'900719925474099312345678901');
});
