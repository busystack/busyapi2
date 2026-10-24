const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {planExtract,planInline,planMoveDefinition}=require('./dist/refactoring_copy.cjs');
const {createGraph}=require('./dist/model.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const pointer='/paths/~1items/get/responses/200/content/application~1json/schema';
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`inline response retains the reachable dynamic-scope refusal ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///project/dynamic.'+(json?'json':'yaml'),at='/paths/~1p/get/responses/200';
 const value={openapi:version,info:{title:'Dynamic scope',version:'1'},paths:{'/p':{get:{responses:{200:{$ref:'#/components/responses/Shared'}}}}},components:{responses:{Shared:{description:'Shared',content:{'application/json':{schema:{$ref:'#/components/schemas/Node'}}}}},schemas:{Node:{$id:'https://schemas.invalid/node',$dynamicAnchor:'node',type:'object',properties:{next:{$dynamicRef:'#node'}}}}}};
 const text=json?JSON.stringify(value):YAML.stringify(value),input={root,snapshot:'dynamic-inline',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:at}};
 assert.throws(()=>planInline(input),error=>error.code==='refactor.inline.schema-resource');assert.equal(input.resources[0].text,text);
});
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const json of [false,true])for(const external of [false,true])test(`inline response retains its unchanged recursive schema target ${version} ${json?'JSON':'YAML'} external=${external}`,async()=>{
 const legacy=version==='2.0',ext=json?'json':'yaml',root='file:///project/api.'+ext,shared='file:///project/responses.'+ext;
 const nodePointer=legacy?'/definitions/Node':'/components/schemas/Node',responsePointer=legacy?'/responses/Shared':'/components/responses/Shared',at='/paths/~1p/get/responses/200';
 const schema={$ref:(external?'api.'+ext:'')+'#'+nodePointer},example={value:'EXACT_NUMBER',$ref:'literal data'};
 const response={description:'Recursive response',...(legacy?{schema,examples:{'application/json':example}}:{content:{'application/json':{schema,example}}})};
 const node={type:'object',required:['value'],properties:{value:{type:'integer',minimum:'EXACT_NUMBER'},next:{$ref:'#'+nodePointer}}};
 const value={...(legacy?{swagger:version}:{openapi:version}),info:{title:'Recursive response',version:'1'},...(legacy?{produces:['application/json']}:{}),
  paths:{'/p':{get:{responses:{200:{$ref:external?'responses.'+ext+'#/Shared':'#'+responsePointer}}}}},
  ...(legacy?{definitions:{Node:node},...(!external?{responses:{Shared:response}}:{})}:{components:{schemas:{Node:node},...(!external?{responses:{Shared:response}}:{})}})};
 const encode=value=>(json?JSON.stringify(value):'# Keep 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll('"EXACT_NUMBER"','9007199254740993.00').replaceAll('EXACT_NUMBER','9007199254740993.00');
 const resources=[{id:root,text:encode(value),generation:1},...(external?[{id:shared,text:encode({Shared:response}),generation:2}]:[])];
 const input={root,snapshot:'recursive-response',resources,contexts:[{root,resources:resources.map(r=>r.id)}],target:{root,resource:root,generation:1,pointer:at}};
 const before=new SourceDocument(resources[0].text,root),plan=planInline(input),after=apply(input,plan),doc=new SourceDocument(after[0].text,root);
 assert.equal(plan.changes.length,1);assert.equal(plan.changes[0].resource,root);
 assert.equal(doc.text.slice(...doc.node(nodePointer).range),before.text.slice(...before.node(nodePointer).range));
 if(external)assert.equal(after[1].text,resources[1].text);
 else assert.equal(doc.text.slice(...doc.node(responsePointer).range),before.text.slice(...before.node(responsePointer).range));
 const graph=createGraph({root,resources:after}).graph,schemaPointer=at+(legacy?'/schema':'/content/application~1json/schema');
 const reference=graph.references.find(r=>r.resource===root&&r.pointer===schemaPointer&&r.keyword==='$ref');
 assert.equal(reference.targetResource,root);assert.equal(reference.targetPointer,nodePointer);assert.equal(graph.issues.length,0);
 const raw=doc.dataJson(at);assert(raw.includes('9007199254740993.00'));assert(raw.includes('literal data'));
 const instances=['{"value":9007199254740993}','{"value":9007199254740993,"next":{"value":9007199254740994}}','{"value":9007199254740992}'];
 for(const [capture,resource,pointer]of [[resources,external?shared:root,(external?'/Shared':responsePointer)+(legacy?'/schema':'/content/application~1json/schema')],[after,root,schemaPointer]]){
  const evaluated=await evaluateSchemas({root,snapshot:'inline-invariants',resources:capture,runtimeInstances:instances.map(text=>({subject:'response-body',location:'application/json',text,schema:{resource,pointer}}))});
  assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.deepEqual(evaluated.runtimeEvaluations.map(e=>e.valid),[true,true,false]);
 }
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`inlining a selected literal value cannot silently change its data meaning ${version} ${json}`,()=>{
 const root='file:///project/root.'+(json?'json':'yaml'),value={openapi:version,info:{title:'Selected data',version:'1'},paths:{},components:{schemas:{Value:{type:'string'},Literal:{const:{$ref:'#/components/schemas/Value'}},Use:{$ref:'#/components/schemas/Literal/const'}}}},text=json?JSON.stringify(value):YAML.stringify(value),input={snapshot:'inline-selected-data',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:'/components/schemas/Literal/const'}};
 assert.throws(()=>planInline(input),error=>error.code==='refactor.literal.ownership');assert.equal(input.resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const identified of [false,true])test(`inline keeps a copied payload distinct from its separate schema consumer ${version} ${json} identified=${identified}`,async()=>{
 const ext=json?'json':'yaml',root='file:///project/source/root.'+ext,destination='file:///project/destination/root.'+ext,other=(identified?'https://identities.invalid/':'file:///project/source/')+'other.'+ext,api=components=>({openapi:version,info:{title:'Occurrence ownership',version:'1'},paths:{},components});
 const payload={...(identified?{$id:'https://identities.invalid/data',$dynamicAnchor:'data'}:{}),$ref:'other.'+ext+'#/Thing',description:'Literal [link](../not-loaded)','x-number':111},source=api({schemas:{Model:{const:payload,examples:[{...payload},{...payload,'x-number':222}]},Inner:{$ref:'#/components/schemas/Model/const'}}}),target=api({schemas:{Use:{$ref:'../source/root.'+ext+'#/components/schemas/Model'}}});
 const render=value=>(json?JSON.stringify(value):'# preserved 雪😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll('111','9007199254740993.00').replaceAll('222','9007199254740992'),resources=[{id:root,text:render(source),generation:1},{id:destination,text:render(target),generation:2},{id:other,text:render({Thing:{type:'string'}}),generation:3}],input={snapshot:'inline-data-occurrence',resources,contexts:[{root,resources:resources.map(value=>value.id)},{root:destination,resources:resources.map(value=>value.id)}],target:{root:destination,resource:destination,generation:2,pointer:'/components/schemas/Use'}},frozen=resources.map(value=>value.text);
 const evaluated=await evaluateSchemas({root:destination,snapshot:'inline-original',resources});assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.deepEqual(evaluated.evaluations.map(value=>value.valid),[true,false]);
 const plan=planInline(input),after=apply(input,plan),before=new SourceDocument(resources[0].text,root),copied=new SourceDocument(after[1].text,destination);
 assert.equal(copied.dataJson('/components/schemas/Use/const'),before.dataJson('/components/schemas/Model/const'));assert.equal(copied.dataJson('/components/schemas/Use/examples'),before.dataJson('/components/schemas/Model/examples'));
 assert.equal(after[0].text,resources[0].text);assert.equal(after[2].text,resources[2].text);assert.equal(plan.changes.length,1);
 assert.equal(createGraph({root:destination,resources:after}).graph.references.some(ref=>ref.pointer==='/components/schemas/Use/const'),false,'An external schema interpretation must not be invented in a copied literal payload');
 const checked=await evaluateSchemas({root:destination,snapshot:'inline-copied',resources:after});assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.evaluations.map(value=>value.valid),[true,false,true,false]);
 if(identified){const graph=createGraph({root:destination,resources:after}).graph;assert.equal(graph.identities.get('https://identities.invalid/data').length,1);assert.equal(graph.dynamicAnchors.get('data').length,1);}
 assert.deepEqual(resources.map(value=>value.text),frozen);
});
function fixture(version,json=false){
 const root='file:///project/root.'+(json?'json':'yaml'),part='file:///project/part.'+(json?'json':'yaml');
 const schema={type:'object',properties:{value:{type:['integer','null'],minimum:0},other:{$ref:'#/components/schemas/Other'}},required:['value'],description:'Line one\n😀 Line two\n',examples:[{value:123,$ref:'payload data'}],'x-kept':{$ref:'not a dependency'}};
 const data={openapi:version,info:{title:'Copy',version:'1'},paths:{'/items':{get:{responses:{'200':{description:'OK',content:{'application/json':{schema,example:{$ref:'payload data'}}}},'204':{description:'No body'}}}}},components:{schemas:{Other:{type:'string'},Use:{$ref:'part.'+(json?'json':'yaml')+'#/Use'}}},'x-value':{$ref:'#'+pointer}};
 let text=json?JSON.stringify(data,null,2):'# retained\r\n'+YAML.stringify(data).replaceAll('\n','\r\n').replace('          schema:', '          schema:');
 text=text.replace('minimum: 0','minimum: 0 # exact comment').replace(json?'"value": 123':'value: 123',json?'"value": 900719925474099312345':'value: 900719925474099312345');
 const external={Use:{$ref:'root.'+(json?'json':'yaml')+'#'+pointer+'/properties/value'}};
 return {snapshot:'copy',root,resources:[{id:root,text,generation:4,identity:'root'},{id:part,text:json?JSON.stringify(external,null,2):YAML.stringify(external),generation:7,identity:'part'}],contexts:[{root,resources:[root,part]}],target:{root,resource:root,generation:4,pointer}};
}
function apply(input,plan){return input.resources.map(r=>{let text=r.text;for(const edit of plan.edits.filter(e=>e.buffer===r.id).sort((a,b)=>b.start-a.start)){assert.equal(text.slice(edit.start,edit.end),edit.expected);text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);}return {...r,text};});}
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const external of [false,true])test(`inline preserves acyclic internal references without expanding their shared targets ${version} ${json} external=${external}`,async()=>{
 const ext=json?'json':'yaml',source='file:///project/source/root.'+ext,destination=external?'file:///project/destination/root.'+ext:source;
 const model={type:'object',$defs:{'a/b~1':{type:'integer',minimum:111}},properties:{value:{$ref:'#/components/schemas/Model/$defs/a~1b~01'}},required:['value'],unevaluatedProperties:false};
 const samples=[{value:111},{value:222},{value:'not an integer'}],use={$ref:(external?'../source/root.'+ext:'')+'#/components/schemas/Model',examples:samples};
 const api=schemas=>({openapi:version,info:{title:'Acyclic inline',version:'1'},paths:{},components:{schemas}}),render=value=>(json?JSON.stringify(value):'# retain 雪😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll('111','9007199254740993').replaceAll('222','9007199254740992');
 const resources=[{id:source,text:render(api({Model:model,...(external?{}:{Use:use})})),generation:1},...(external?[{id:destination,text:render(api({Use:use})),generation:2}]:[])],input={snapshot:'acyclic-inline',resources,contexts:[{root:destination,resources:resources.map(value=>value.id)},...(external?[{root:source,resources:[source]}]:[])],target:{root:destination,resource:destination,pointer:'/components/schemas/Use',generation:external?2:1}},original=resources.map(value=>value.text);
 const before=await evaluateSchemas({root:destination,snapshot:'acyclic-original',resources});assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(value=>value.valid),[true,false,false]);
 const plan=planInline(input),after=apply(input,plan),copied=new SourceDocument(after.at(-1).text,destination),graph=createGraph({root:destination,resources:after}).graph;
 assert.equal(graph.issues.length,0);const consumer=graph.references.find(value=>value.resource===destination&&value.pointer==='/components/schemas/Use/allOf/0/properties/value');assert(consumer);assert.equal(consumer.targetResource,source);assert.equal(consumer.targetPointer,'/components/schemas/Model/$defs/a~1b~01');
 assert.equal(copied.dataJson('/components/schemas/Use/allOf/0/$defs/a~1b~01'),new SourceDocument(resources[0].text,source).dataJson('/components/schemas/Model/$defs/a~1b~01'));
 assert(plan.usages.some(value=>value.effect==='retained-inline-target'&&value.resource===source&&value.pointer==='/components/schemas/Model/properties/value/$ref'&&value.target.pointer==='/components/schemas/Model/$defs/a~1b~01'));
 if(external)assert.equal(after[0].text,resources[0].text);assert.deepEqual(resources.map(value=>value.text),original);
 const checked=await evaluateSchemas({root:destination,snapshot:'acyclic-copied',resources:after});assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.evaluations.map(value=>value.valid),[true,false,false]);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`cross-file extraction and inline retain passive URI and Server meanings ${version} ${json?'JSON':'YAML'}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/source/root.'+ext,destination='file:///project/destination/models.'+ext;
 const sourceSelf='file:///project/source-identity/entry',destinationSelf='file:///project/destination-identity/entry';
 const response={description:'Response 雪😀',content:{'application/json':{schema:false,examples:{External:{externalValue:'./payload.txt#opaque%7E%2Fdata'},Literal:{value:{externalValue:'literal payload',$ref:'literal ref',number:111}},Ignored:{$ref:'#/components/examples/Payload',externalValue:'ignored-relative-data'}}}},links:{Follow:{operationId:'readItems',server:{url:'../{region}/../service',variables:{region:{default:'a/b'}}}}},'x-extra':{externalValue:'extension data',url:'extension url'}};
 const api={openapi:version,...(version.startsWith('3.2')?{$self:sourceSelf}:{}),info:{title:'Copy URI',version:'1'},paths:{'/items':{get:{operationId:'readItems',responses:{200:response}}}},components:{examples:{Payload:{value:{$ref:'literal payload'}}}}};
 const target={openapi:version,...(version.startsWith('3.2')?{$self:destinationSelf}:{}),info:{title:'Destination',version:'1'},paths:{}};
 const encode=value=>(json?JSON.stringify(value,null,2):YAML.stringify(value)).replace('111','900719925474099312345678901');
 const resources=[{id:root,generation:1,text:encode(api),aliases:[root,...(version.startsWith('3.2')?[sourceSelf]:[])]},{id:destination,generation:2,text:encode(target),aliases:[destination,...(version.startsWith('3.2')?[destinationSelf]:[])]}];
 const from='/paths/~1items/get/responses/200',to='/components/responses/Stored';
 const input={root,snapshot:'copy-uri',resources,contexts:[{root,resources:[root,destination]},{root:destination,resources:[destination]}],target:{root,resource:root,pointer:from,generation:1},name:'Stored',destinationResource:destination};
 const frozen=resources.map(resource=>resource.text),plan=planExtract(input),after=apply(input,plan),definition=new SourceDocument(after[1].text,destination);
 const external='/content/application~1json/examples/External/externalValue',literal='/content/application~1json/examples/Literal/value',ignored='/content/application~1json/examples/Ignored/externalValue';
 const expected=new URL(response.content['application/json'].examples.External.externalValue,version.startsWith('3.2')?sourceSelf:root).href;
 assert.equal(definition.node(to+external).value,expected);assert.equal(definition.node(to+ignored).value,'ignored-relative-data');
 const oldDoc=new SourceDocument(resources[0].text,root);assert.equal(definition.dataJson(to+literal),oldDoc.dataJson(from+literal));assert(definition.dataJson(to+literal).includes('900719925474099312345678901'));
 assert.equal(definition.dataJson(to+'/x-extra'),oldDoc.dataJson(from+'/x-extra'));
 const server=definition.node(to+'/links/Follow/server/url').value;
 for(const region of ['a/b','x/../../z','{literal}'])assert.equal(new URL(server.replace('{region}',region),destination).href,new URL(response.links.Follow.server.url.replace('{region}',region),root).href);
 const inlineInput={...input,resources:after,contexts:input.contexts.map(context=>({...context,resources:[root,destination]}))},inline=planInline(inlineInput),inlined=apply(inlineInput,inline),local=new SourceDocument(inlined[0].text,root);
 assert.equal(inlined[1].text,after[1].text,'Inlining must not edit the shared definition');
 assert.equal(new URL(local.node(from+external).value,version.startsWith('3.2')?sourceSelf:root).href,expected);
 assert.equal(local.dataJson(from+literal),oldDoc.dataJson(from+literal));assert.equal(local.node(from+ignored).value,'ignored-relative-data');
 for(const region of ['a/b','../z'])assert.equal(new URL(local.node(from+'/links/Follow/server/url').value.replace('{region}',region),root).href,new URL(response.links.Follow.server.url.replace('{region}',region),root).href);
 assert.deepEqual(resources.map(resource=>resource.text),frozen);assert.equal(createGraph({...input,resources:inlined}).graph.issues.length,0);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`move a component definition, preserve its public binding and repair descendant consumers ${version} ${json?'JSON':'YAML'}`,()=>{
 const input=fixture(version,json),extracted=apply(input,planExtract({...input,name:'Public'}));
 const destination='file:///project/models.'+(json?'json':'yaml');
 const output={openapi:version,info:{title:'Models',version:'1'},paths:{}};
 const original={...input,resources:[...extracted,{id:destination,text:json?JSON.stringify(output,null,2):YAML.stringify(output),generation:2,identity:'models'}],
  contexts:[{root:input.root,resources:[input.root,input.resources[1].id,destination]},{root:destination,resources:[destination]}],
  target:{...input.target,pointer:'/components/schemas/Public'},destinationResource:destination,name:'Stored'};
 const plan=planMoveDefinition(original),resources=apply(original,plan),doc=new SourceDocument(resources[0].text,input.root),target=new SourceDocument(resources[2].text,destination);
 assert.equal(plan.kind,'component-move');assert.equal(plan.preservedBinding.pointer,'/components/schemas/Public');
 assert.equal(doc.node(pointer+'/$ref').value,'#/components/schemas/Public');
 assert.equal(doc.node('/components/schemas/Public/$ref').value,'models.'+(json?'json':'yaml')+'#/components/schemas/Stored');
 assert(target.dataJson('/components/schemas/Stored').includes('900719925474099312345'));
 assert.equal(target.node('/components/schemas/Stored/properties/other/$ref').value,'root.'+(json?'json':'yaml')+'#/components/schemas/Other');
 assert.equal(new SourceDocument(resources[1].text,resources[1].id).node('/Use/$ref').value,'models.'+(json?'json':'yaml')+'#/components/schemas/Stored/properties/value');
 assert(plan.usages.some(u=>u.bindingRetained===true));
 assert.equal(createGraph({...input,resources}).graph.issues.length,0);
 assert(!original.resources[0].text.includes('Stored'));
 const noOp=planMoveDefinition({...original,destinationResource:input.root,name:'Public'});
 assert.deepEqual(noOp.edits,[]);assert.deepEqual(noOp.changes,[]);
});
for(const version of ['3.1.2','3.2.1'])test(`security component definition move preserves alternatives and combined implicit bindings ${version}`,()=>{
 const root='file:///project/root.json',destination='file:///project/models.json';
 const doc={openapi:version,info:{title:'Security',version:'1'},paths:{},security:[{Key:[],Basic:[]},{}],components:{securitySchemes:{Key:{type:'apiKey',in:'header',name:'X-Key'},Basic:{type:'http',scheme:'basic'}}}};
 const input={root,snapshot:'move-security',resources:[{id:root,text:JSON.stringify(doc),generation:2},{id:destination,text:JSON.stringify({openapi:version,info:{title:'Models',version:'1'},paths:{}}),generation:3}],contexts:[{root,resources:[root,destination]},{root:destination,resources:[destination]}],target:{root,resource:root,pointer:'/components/securitySchemes/Key',generation:2},destinationResource:destination,name:'StoredKey'};
 const plan=planMoveDefinition(input),resources=apply(input,plan),after=JSON.parse(resources[0].text);
 assert.deepEqual(after.security,doc.security);assert.deepEqual(after.components.securitySchemes.Key,{$ref:'models.json#/components/securitySchemes/StoredKey'});
 assert.deepEqual(JSON.parse(resources[1].text).components.securitySchemes.StoredKey,doc.components.securitySchemes.Key);
 assert(plan.usages.some(u=>u.connection==='security'&&u.bindingRetained));
 assert.equal(createGraph({...input,resources}).graph.issues.length,0);
});
test('a moved allOf definition retains its discriminator wire mapping without normalizing existing mappings',()=>{
 const root='file:///project/root.yaml',destination='file:///project/models.yaml';
 const text='openapi: 3.2.1\ninfo: {title: Move, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Parent:\n      type: object\n      discriminator:\n        propertyName: kind\n        mapping:\n          Other: "#/components/schemas/Other" # retain quote/comment\n    Other: false\n    Public:\n      allOf:\n        - $ref: "#/components/schemas/Parent"\n        - type: object\n';
 const input={root,snapshot:'move-wire',resources:[{id:root,text,generation:1},{id:destination,text:'openapi: 3.2.1\ninfo: {title: Models, version: "1"}\npaths: {}\n',generation:2}],contexts:[{root,resources:[root,destination]},{root:destination,resources:[destination]}],target:{root,resource:root,pointer:'/components/schemas/Public',generation:1},destinationResource:destination,name:'Stored'};
 const plan=planMoveDefinition(input),resources=apply(input,plan),after=new SourceDocument(resources[0].text,root);
 assert.equal(after.node('/components/schemas/Parent/discriminator/mapping/Public').value,'#/components/schemas/Public');
 assert(resources[0].text.includes('Other: "#/components/schemas/Other" # retain quote/comment'));
 assert.equal(createGraph({...input,resources}).graph.issues.length,0);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`definition moves retain each legal component family ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///project/root.'+(json?'json':'yaml'),destination='file:///project/models.'+(json?'json':'yaml');
 const families={schemas:false,parameters:{name:'q',in:'query',schema:false},headers:{description:'Header',schema:{type:'string'}},responses:{description:'Bodyless'},requestBodies:{content:{'application/json':{schema:false}}},examples:{value:{$ref:'payload data',empty:null}},links:{operationId:'getItems'},callbacks:{'{$request.query.callback}':{post:{responses:{204:{description:'Callback'}}}}},pathItems:{get:{responses:{204:{description:'None'}}}},securitySchemes:{type:'oauth2',flows:{clientCredentials:{tokenUrl:'../token',scopes:{read:'Read'}}}},...(version.startsWith('3.2')?{mediaTypes:{schema:false,example:{$ref:'data'}}}:{})};
 for(const [family,value]of Object.entries(families)){
  const document={openapi:version,info:{title:'Family',version:'1'},paths:{'/items':{get:{operationId:'getItems',responses:{204:{description:'No body'}}}}},components:{[family]:{Public:value}}};
  const output={openapi:version,info:{title:'Models',version:'1'},paths:{}};
  const input={root,snapshot:'families',resources:[{id:root,text:json?JSON.stringify(document,null,2):YAML.stringify(document),generation:1},{id:destination,text:json?JSON.stringify(output,null,2):YAML.stringify(output),generation:2}],contexts:[{root,resources:[root,destination]},{root:destination,resources:[destination]}],target:{root,resource:root,pointer:'/components/'+family+'/Public',generation:1},destinationResource:destination,name:'Stored'};
  let plan;try{plan=planMoveDefinition(input);}catch(error){error.message=family+': '+error.message;throw error;}
  const resources=apply(input,plan),source=new SourceDocument(resources[0].text,root),target=new SourceDocument(resources[1].text,destination);
  if(family==='links'){
   assert.equal(target.nodes.has('/components/links/Stored/operationId'),false);
   assert.equal(target.node('/components/links/Stored/operationRef').value,'root.'+(json?'json':'yaml')+'#/paths/~1items/get');
  }else assert.equal(target.dataJson('/components/'+family+'/Stored'),new SourceDocument(input.resources[0].text,root).dataJson(input.target.pointer),family);
  assert.equal(source.node(input.target.pointer+'/$ref').value,'models.'+(json?'json':'yaml')+'#/components/'+family+'/Stored',family);
  assert.equal(createGraph({...input,resources}).graph.issues.length,0,family);
 }
});
for(const version of ['3.1.2','3.2.1'])test(`moving an owned recursive dynamic resource retains exact positive and negative instance outcomes ${version}`,async()=>{
 const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
 const root='file:///project/root.json',destination='file:///project/models.json';
 const schema={$id:'https://models.test/node',$dynamicAnchor:'node',type:'object',properties:{n:{type:'integer'},child:{$dynamicRef:'#node'}},required:['n'],unevaluatedProperties:false};
 const media={schema:{$ref:'#/components/schemas/Public'},examples:{valid:{value:{n:'EXACT',child:{n:'EXACT'}}},invalid:{value:{n:'not an integer'}}}};
 const value={openapi:version,info:{title:'Dynamic',version:'1'},paths:{'/items':{get:{responses:{200:{description:'OK',content:{'application/json':media}}}}}},components:{schemas:{Public:schema}}};
 const input={root,snapshot:'dynamic-move',resources:[{id:root,text:JSON.stringify(value).replaceAll('"EXACT"','900719925474099312345'),generation:1},{id:destination,text:JSON.stringify({openapi:version,info:{title:'Models',version:'1'},paths:{}}),generation:2}],contexts:[{root,resources:[root,destination]},{root:destination,resources:[destination]}],target:{root,resource:root,pointer:'/components/schemas/Public',generation:1},destinationResource:destination,name:'Stored'};
 const before=await evaluateSchemas(input),resources=apply(input,planMoveDefinition(input)),after=await evaluateSchemas({...input,resources});
 assert.equal(before.complete,true);assert.equal(after.complete,true);
 assert.equal(before.findings.filter(f=>f.code==='example.schema.incompatible').length,1);
 assert.equal(after.findings.filter(f=>f.code==='example.schema.incompatible').length,1);
 assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false]);
 assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false]);
 assert(resources[0].text.includes('900719925474099312345'));
 assert.equal(new SourceDocument(resources[1].text,destination).node('/components/schemas/Stored/$id').value,'https://models.test/node');
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`extract exact schema and all known consumers ${version} ${json?'JSON':'YAML'}`,()=>{
 const input=fixture(version,json),before=new SourceDocument(input.resources[0].text,input.root),plan=planExtract({...input,name:'Reusable'}),resources=apply(input,plan),doc=new SourceDocument(resources[0].text,input.root),parse=json?JSON.parse:YAML.parse;
 assert.equal(plan.kind,'component-extract');assert.equal(plan.edits.length,2);assert.equal(plan.usages.length,2);
 assert.equal(doc.node(pointer+'/$ref').value,'#/components/schemas/Reusable');
 assert(doc.dataJson('/components/schemas/Reusable').includes('900719925474099312345'));
 assert.equal(doc.node('/components/schemas/Reusable/description').value,before.node(pointer+'/description').value);
 assert.equal(parse(resources[1].text).Use.$ref,'root.'+(json?'json':'yaml')+'#/components/schemas/Reusable/properties/value');
 assert.equal(doc.node('/x-value/$ref').value,'#'+pointer);assert.equal(doc.node('/components/schemas/Reusable/examples/0/$ref').value,'payload data');
 assert.equal(doc.node('/paths/~1items/get/responses/204').value.content,undefined);
 assert.equal(createGraph({...input,resources}).graph.issues.length,0);
 assert.deepEqual(plan.transitions,[{resource:input.root,from:pointer,to:'/components/schemas/Reusable'}]);
 if(!json){assert(resources[0].text.startsWith('# retained\r\n'));assert(resources[0].text.includes('minimum: 0 # exact comment'));}
 assert(!input.resources[0].text.includes('Reusable'));
 assert.throws(()=>planExtract({...input,name:'Other'}),e=>e.code==='edit.collision');
 assert.throws(()=>planExtract({...input,name:'bad/name'}),e=>e.code==='refactor.copy.context');
 assert.throws(()=>planExtract({...input,name:'Reusable',target:{...input.target,generation:3}}),e=>e.code==='edit.stale');
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`extract bodyless response, boolean schema and legal component collections ${version} ${json?'JSON':'YAML'}`,()=>{
 const input=fixture(version,json),target={...input.target,pointer:'/paths/~1items/get/responses/204'};
 const plan=planExtract({...input,target,name:'Empty'}),resources=apply(input,plan),doc=new SourceDocument(resources[0].text,input.root);
 assert.deepEqual(JSON.parse(doc.dataJson('/components/responses/Empty')),{description:'No body'});
 assert.deepEqual(JSON.parse(doc.dataJson(target.pointer)),{$ref:'#/components/responses/Empty'});
 const base={openapi:version,info:{title:'Boolean',version:'1'},paths:{},components:{schemas:{Container:{properties:{no:false}}}}};
 const simple={...input,resources:[{...input.resources[0],text:json?JSON.stringify(base):YAML.stringify(base)}],contexts:[{root:input.root,resources:[input.root]}],target:{...input.target,pointer:'/components/schemas/Container/properties/no'}};
 const next=new SourceDocument(apply(simple,planExtract({...simple,name:'Never'}))[0].text,input.root);
 assert.equal(next.node('/components/schemas/Never').value,false);
});
test('YAML block replacement keeps following siblings and last-newline state',()=>{
 for(const ending of ['', '\n','\r\n']){
  const root='file:///project/root.yaml',text='openapi: 3.2.1\ninfo: {title: Copy, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Container:\n      properties:\n        before:\n          description: |\n            exact\n          type: string # kept\n        after: false\n    Last: true'+ending;
  const input={snapshot:'captured',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:'/components/schemas/Container/properties/before'},name:'Extracted'};
  const result=apply(input,planExtract(input))[0].text,doc=new SourceDocument(result,root);
  assert.equal(doc.node('/components/schemas/Container/properties/after').value,false);
  assert.equal(doc.node('/components/schemas/Extracted/description').value,'exact\n');assert(result.includes('type: string # kept'));
  assert.equal(/[\r\n]$/.test(result),!!ending);
 }
});
test('empty explicit flow component collection can receive an authored block',()=>{
 const input=fixture('3.2.1');input.resources=[input.resources[0]];input.contexts[0].resources=[input.root];
 input.resources[0].text=input.resources[0].text.slice(0,input.resources[0].text.indexOf('components:')).replace('$ref: "#/components/schemas/Other"','type: string')+'components: {}\r\n';
 const resources=apply(input,planExtract({...input,name:'Model'}));
 assert(new SourceDocument(resources[0].text,input.root).node('/components/schemas/Model').value.properties);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`inline one occurrence preserves definition, exact values and reference siblings ${version} ${json?'JSON':'YAML'}`,()=>{
 const input=fixture(version,json),extraction=planExtract({...input,name:'Reusable'}),resources=apply(input,extraction);
 // The inline definition's external same-root schema ref must stay shared.
 const next={...input,resources},plan=planInline(next),after=apply(next,plan),doc=new SourceDocument(after[0].text,input.root),before=new SourceDocument(resources[0].text,input.root);
 assert.equal(plan.kind,'reference-inline');assert.equal(plan.edits.length,1);
 assert.equal(doc.dataJson('/components/schemas/Reusable'),before.dataJson('/components/schemas/Reusable'));
 assert.equal(doc.node(pointer+'/properties/other/$ref').value,'#/components/schemas/Other');
 assert(doc.dataJson(pointer).includes('900719925474099312345'));assert.equal(doc.node(pointer+'/description').value,'Line one\n😀 Line two\n');
 assert.equal(createGraph({...input,resources:after}).graph.issues.length,0);
 // Schema siblings remain conjunctive, not last-key-wins object merging.
 const parsed=json?JSON.parse(resources[0].text):YAML.parse(resources[0].text);
 parsed.paths['/items'].get.responses['200'].content['application/json'].schema.maxProperties=1;
 const withSibling={...next,resources:[{...resources[0],text:json?JSON.stringify(parsed,null,2):YAML.stringify(parsed)},resources[1]]};
 const result=new SourceDocument(apply(withSibling,planInline(withSibling))[0].text,input.root);
 assert.equal(result.node(pointer+'/maxProperties').value,1);assert.equal(result.node(pointer+'/allOf/0/type').value,'object');
});
test('Reference Object description override does not merge ignored siblings',()=>{
 const root='file:///project/root.yaml',text='openapi: 3.2.1\ninfo: {title: Test, version: "1"}\npaths:\n  /:\n    get:\n      responses:\n        "204":\n          $ref: "#/components/responses/Empty"\n          description: Local\ncomponents:\n  responses:\n    Empty:\n      description: Shared # retained\n';
 const input={snapshot:'captured',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:'/paths/~1/get/responses/204'}};
 const doc=new SourceDocument(apply(input,planInline(input))[0].text,root);
 assert.deepEqual(doc.node(input.target.pointer).value,{description:'Local'});assert.equal(doc.node('/components/responses/Empty/description').value,'Shared');
 const unsafe={...input,resources:[{...input.resources[0],text:text.replace('description: Local','description: Local\n          x-ignored: true')}]};
 assert.throws(()=>planInline(unsafe),e=>e.code==='refactor.inline.ignored');
});
test('identified, dynamic and recursive definitions need explicit ownership, never silent duplication',()=>{
 for(const schema of [{$id:'https://models.test/A',type:'string'},{$anchor:'named',type:'string'},{$dynamicAnchor:'node',type:'object'},{$schema:'https://json-schema.org/draft/2020-12/schema',type:'string'},{type:'object',properties:{self:{$ref:'#/components/schemas/A'}}}]){
  const root='file:///project/root.json',data={openapi:'3.2.1',info:{title:'Test',version:'1'},paths:{},components:{schemas:{A:schema,B:{$ref:'#/components/schemas/A'}}}};
  const input={snapshot:'current',resources:[{id:root,text:JSON.stringify(data),generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:'/components/schemas/B'}};
  assert.throws(()=>planInline(input),e=>['refactor.inline.schema-resource','refactor.inline.recursive'].includes(e.code));
 }
});
test('extracting out of an inherited embedded schema resource fails precisely',()=>{
 const root='file:///project/root.json',data={openapi:'3.2.1',info:{title:'Test',version:'1'},paths:{},components:{schemas:{Owner:{$id:'https://models.test/A',properties:{child:{type:'string'}}}}}};
 const input={snapshot:'current',resources:[{id:root,text:JSON.stringify(data),generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:'/components/schemas/Owner/properties/child'},name:'Child'};
 assert.throws(()=>planExtract(input),e=>e.code==='refactor.copy.schema-resource');
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`independent instance oracles survive extraction and sibling inlining ${version} ${json?'JSON':'YAML'}`,async()=>{
 const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
 const root='file:///project/oracle.'+(json?'json':'yaml');
 const schema={type:'object',properties:{n:{type:'integer',minimum:9007199254740992}},required:['n'],unevaluatedProperties:false};
 const samples=[{n:9007199254740992},{n:9007199254740991},{n:9007199254740992,extra:true},{}];
 const media={schema,examples:Object.fromEntries(samples.map((value,i)=>['case'+i,{value}]))};
 const data={openapi:version,info:{title:'Exact copy oracle',version:'1'},paths:{'/':{get:{responses:{200:{description:'Read',content:{'application/json':media}}}}}}};
 const text=(json?JSON.stringify(data,null,2):YAML.stringify(data)).replaceAll('9007199254740992','9007199254740993').replaceAll('9007199254740991','9007199254740992');
 const at='/paths/~1/get/responses/200/content/application~1json/schema';
 let input={root,snapshot:'oracles',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:at}};
 const evaluated=await evaluateSchemas(input);assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,false,false,false]);
 const extracted=planExtract({...input,name:'Exact'});input={...input,resources:apply(input,extracted)};
 const checked=await evaluateSchemas(input);assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.evaluations.map(e=>e.valid),[true,false,false,false]);
 let doc=new SourceDocument(input.resources[0].text,root);
 doc=new SourceDocument(doc.set(at+'/allOf',[{minProperties:1}]),root);
 doc=new SourceDocument(doc.set(at+'/description','Authored local annotation'),root);
 input={...input,resources:[{...input.resources[0],text:doc.text}]};
 const originalBranches=doc.text.slice(...doc.node(at+'/allOf/0').range);
 const inline=planInline(input),resources=apply(input,inline),after=new SourceDocument(resources[0].text,root);
 assert.equal(after.text.slice(...after.node(at+'/allOf/0').range),originalBranches);
 assert.equal(after.node(at+'/allOf/1/type').value,'object');
 assert.equal(after.node(at+'/description').value,'Authored local annotation');
 const result=await evaluateSchemas({...input,resources});assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false,false,false]);
});
test('external inline repairs relative reference addresses but leaves the shared definition byte-identical',()=>{
 const root='file:///project/root.json',definition='file:///project/models/value.json',other='file:///project/models/other.json';
 const source='{"openapi":"3.2.1","info":{"title":"Inline","version":"1"},"paths":{},"components":{"schemas":{"Use":{"$ref":"models/value.json#/Value"}}}}';
 const valueText='{ "Value": { "type": "object", "properties": { "item": { "$ref": "other.json#/Other" } }, "examples": [{"n":900719925474099312345,"$ref":"literal"}] } }\r\n';
 const input={snapshot:'cross-file',resources:[{id:root,text:source,generation:1},{id:definition,text:valueText,generation:2},{id:other,text:'{"Other":false}',generation:3}],contexts:[{root,resources:[root,definition,other]}],target:{root,resource:root,generation:1,pointer:'/components/schemas/Use'}};
 const plan=planInline(input),resources=apply(input,plan),doc=new SourceDocument(resources[0].text,root);
 assert.equal(plan.edits.length,1);assert.equal(resources[1].text,valueText);
 assert.equal(doc.node('/components/schemas/Use/properties/item/$ref').value,'models/other.json#/Other');
 assert(doc.dataJson('/components/schemas/Use/examples').includes('900719925474099312345'));
 assert.equal(createGraph({root,resources}).graph.issues.length,0);
});
test('transitive recursion, ignored summary and conflicting Path Item siblings are explicit non-success',()=>{
 const root='file:///project/root.json';
 const data={openapi:'3.1.2',info:{title:'Blocked',version:'1'},paths:{'/':{$ref:'#/components/pathItems/Shared'}},components:{pathItems:{Shared:{summary:'Shared'}},responses:{Empty:{description:'No body'},Use:{$ref:'#/components/responses/Empty',summary:'Ignored'}},schemas:{A:{properties:{b:{$ref:'#/components/schemas/B'}}},B:{properties:{a:{$ref:'#/components/schemas/A'}}},Use:{$ref:'#/components/schemas/A'}}}};
 const input={snapshot:'blocked',resources:[{id:root,text:JSON.stringify(data),generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:'/components/schemas/Use'}};
 assert.throws(()=>planInline(input),e=>e.code==='refactor.inline.recursive');
 assert.throws(()=>planInline({...input,target:{...input.target,pointer:'/components/responses/Use'}}),e=>e.code==='refactor.inline.ignored');
 // Overlap is now a source-located graph ambiguity before any refactoring
 // plan, not only a late inlining check. Keep the two independent refusals
 // above reachable instead of letting this fixture mask them.
 data.paths['/'].summary='Local';
 const conflict={...input,resources:[{...input.resources[0],text:JSON.stringify(data)}]};
 const overlaps=createGraph({root,resources:conflict.resources}).graph.issues.filter(issue=>issue.code==='path.reference.overlap');
 assert.deepEqual(overlaps.map(issue=>issue.pointer).sort(),['/components/pathItems/Shared/summary','/paths/~1/summary']);
 assert.throws(()=>planInline({...conflict,target:{...input.target,pointer:'/paths/~1'}}),e=>e.code==='refactor.graph');
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`extraction retains owned nested identifiers and recursive dynamic anchors ${version} ${json?'JSON':'YAML'}`,async()=>{
 const {evaluateSchemas}=require('./dist/schema_evaluation.cjs'),root='file:///project/root.'+(json?'json':'yaml');
 const schema={$id:'models/node',$dynamicAnchor:'node',type:'object',properties:{value:{type:'integer'},child:{$dynamicRef:'#node'}},required:['value'],unevaluatedProperties:false};
 const media={schema,examples:{valid:{value:{value:1,child:{value:2}}},invalid:{value:{value:1,child:{value:'not integer'}}}}};
 const data={openapi:version,info:{title:'Identity extraction',version:'1'},paths:{'/':{get:{responses:{200:{description:'Read',content:{'application/json':media}}}}}}};
 const at='/paths/~1/get/responses/200/content/application~1json/schema',text=json?JSON.stringify(data,null,2):YAML.stringify(data);
 const input={root,snapshot:'owned-scope',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:at}};
 const before=await evaluateSchemas(input);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false]);
 const plan=planExtract({...input,name:'Node'}),resources=apply(input,plan),graph=createGraph({root,resources}).graph;
 assert.equal(graph.scope(root,'/components/schemas/Node').base,'file:///project/models/node');
 assert.equal(graph.references.find(ref=>ref.pointer==='/components/schemas/Node/properties/child').targetPointer,'/components/schemas/Node');
 const after=await evaluateSchemas({...input,resources});assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false]);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`all reusable inline object families use typed destination collections ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///project/families.'+(json?'json':'yaml');
 const media={schema:false,examples:{named:{value:{n:'EXACT_NUMBER',$ref:'payload'}}}};
 const response={description:'Bodyless',headers:{'X-Count':{schema:{type:'integer'}}},links:{next:{operationId:'read'}}};
 const operation={operationId:'read',parameters:[{name:'count',in:'query',schema:{type:'integer'}}],requestBody:{content:{'application/json':media}},responses:{204:response},callbacks:{changed:{'{$request.query.callback}':{post:{responses:{204:{description:'Done'}}}}}}};
 const data={openapi:version,info:{title:'Families',version:'1'},paths:{'/':{get:operation}}};
 const at='/paths/~1/get',cases=[
  [at+'/parameters/0','parameters'],[at+'/requestBody','requestBodies'],[at+'/responses/204','responses'],
  [at+'/responses/204/headers/X-Count','headers'],[at+'/responses/204/links/next','links'],
  [at+'/requestBody/content/application~1json/examples/named','examples'],[at+'/callbacks/changed','callbacks'],
  ['/paths/~1','pathItems'],...(version.startsWith('3.2')?[[at+'/requestBody/content/application~1json','mediaTypes']]:[]),
 ];
 for(const [pointer,collection]of cases){
  const text=(json?JSON.stringify(data,null,2):YAML.stringify(data)).replaceAll('"EXACT_NUMBER"','900719925474099312345').replaceAll('EXACT_NUMBER','900719925474099312345');
  const input={snapshot:'families',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer}};
  const plan=planExtract({...input,name:'Reusable'}),resources=apply(input,plan),doc=new SourceDocument(resources[0].text,root);
  assert.equal(plan.to.pointer,'/components/'+collection+'/Reusable');
  assert(doc.nodes.has(plan.to.pointer));assert.equal(createGraph({root,resources}).graph.issues.length,0);
  assert.equal(doc.node(pointer+'/$ref').value,'#/components/'+collection+'/Reusable');
 }
});
test('inlining retains removed reference comments without interpreting comment-looking strings',()=>{
 const root='file:///project/comments.yaml';
 for(const siblings of ['', '      maxLength: 10 # local constraint\n']){
  const text='openapi: 3.2.1\ninfo: {title: Comments, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Use:\n      $ref: "#/components/schemas/Value" # why this use\n'+siblings+'    Value:\n      type: string # shared comment\n      description: |\n        # ordinary string, not a source comment\n';
  const input={snapshot:'comments',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:'/components/schemas/Use'}};
  const before=new SourceDocument(text,root);
  assert(!before.comments('/components/schemas/Value').map(range=>text.slice(...range)).includes('# ordinary string, not a source comment'));
  const plan=planInline(input),after=apply(input,plan)[0].text,doc=new SourceDocument(after,root);
  assert.equal(after.split('# why this use').length,2);
  assert.equal(after.split('# local constraint').length,siblings?2:1);
  assert.equal(doc.dataJson('/components/schemas/Value'),before.dataJson('/components/schemas/Value'));
  assert.equal(doc.node('/components/schemas/Use'+(siblings?'/allOf/0':'')+'/description').value,'# ordinary string, not a source comment\n');
 }
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`cross-resource extraction reopens with exact targets and owned dynamic identities ${version} ${json?'JSON':'YAML'}`,async()=>{
 const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
 for(const identified of [false,true]){
  const ext=json?'json':'yaml',root='file:///project/a.'+ext,destination='file:///project/b.'+ext,consumer='file:///project/consumer.'+ext;
  const schema={...(identified?{$id:'schemas/node',$dynamicAnchor:'node'}:{}),type:'object',properties:{value:{$ref:'#/components/schemas/Number'},...(identified?{child:{$dynamicRef:'#node'}}:{})},required:['value'],examples:[{value:'EXACT_NUMBER',$ref:'literal payload'}]};
  // References inside an identified resource must explicitly retain the
  // entry document's address rather than borrowing that resource's base.
  if(identified)schema.properties.value.$ref='../a.'+ext+'#/components/schemas/Number';
  const media={schema,examples:{valid:{value:{value:2,...(identified?{child:{value:3}}:{})}},invalid:{value:{value:'wrong'}}}};
  const a={openapi:version,info:{title:'A',version:'1'},paths:{'/':{get:{responses:{200:{description:'Read',content:{'application/json':media}}}}}},components:{schemas:{Number:{type:'integer'},External:{$ref:'consumer.'+ext+'#/Use'}}}};
  const b={openapi:version,info:{title:'B',version:'1'},paths:{}};
  const at='/paths/~1/get/responses/200/content/application~1json/schema';
  const render=value=>(json?JSON.stringify(value,null,2):YAML.stringify(value)).replaceAll('"EXACT_NUMBER"','900719925474099312345').replaceAll('EXACT_NUMBER','900719925474099312345');
  const input={root,snapshot:'cross',resources:[{id:root,text:render(a),generation:1},{id:destination,text:render(b),generation:2},{id:consumer,text:render({Use:{$ref:'a.'+ext+'#'+at+'/properties/value'}}),generation:3}],contexts:[{root,resources:[root,consumer]},{root:destination,resources:[destination]}],target:{root,resource:root,generation:1,pointer:at},destinationResource:destination,name:'Node'};
  const errors=[];
  const before=await evaluateSchemas({...input,resources:input.resources.filter(r=>r.id!==destination)},error=>{
   const chain=[];for(let at=error;at;at=at.cause)chain.push(String(at));errors.push(chain);
  });
  assert.equal(before.complete,true,JSON.stringify({identified,findings:before.findings,errors}));
  assert.deepEqual(before.evaluations.filter(e=>e.interpretation!=='schema-annotation').map(e=>e.valid),[true,false]);
  const plan=planExtract(input),resources=apply(input,plan);
  assert.equal(plan.edits.length,3);assert.equal(plan.to.resource,destination);assert.equal(plan.transitions[0].toResource,destination);
  const graph=createGraph({root,resources}).graph;
  assert.equal(graph.references.find(ref=>ref.resource===root&&ref.pointer===at).targetResource,destination);
  assert.equal(graph.references.find(ref=>ref.resource===consumer).targetPointer,'/components/schemas/Node/properties/value');
  const copied=new SourceDocument(resources.find(r=>r.id===destination).text,destination);
  assert(copied.dataJson('/components/schemas/Node/examples').includes('900719925474099312345'));
  if(identified)assert.equal(copied.node('/components/schemas/Node/$id').value,'file:///project/schemas/node');
  const after=await evaluateSchemas({...input,resources});assert.equal(after.complete,true,JSON.stringify(after.findings));
  assert.deepEqual(after.evaluations.filter(e=>e.interpretation!=='schema-annotation').map(e=>e.valid),[true,false]);
  assert.equal(input.resources[1].text,render(b));
 }
});
test('cross-resource extraction requires a cold retrieval route for a declared OpenAPI identity',()=>{
 const root='file:///project/a.json',destination='file:///project/b.json';
 const input={root,snapshot:'mapping',resources:[{id:root,text:'{"openapi":"3.2.1","info":{"title":"A","version":"1"},"paths":{},"components":{"schemas":{"Owner":{"properties":{"child":false}}}}}',generation:1},{id:destination,text:'{"openapi":"3.2.1","$self":"https://identity.invalid/b","info":{"title":"B","version":"1"},"paths":{}}',generation:2}],contexts:[{root,resources:[root]},{root:destination,resources:[destination]}],target:{root,resource:root,generation:1,pointer:'/components/schemas/Owner/properties/child'},destinationResource:destination,name:'Child'};
 assert.throws(()=>planExtract(input),e=>e.code==='refactor.copy.retrieval');
 const mapped={...input,resources:[input.resources[0],{...input.resources[1],aliases:['https://identity.invalid/b']}]};
 const plan=planExtract(mapped),resources=apply(mapped,plan);
 assert.equal(createGraph({root,resources}).graph.issues.length,0);
 assert.equal(new SourceDocument(resources[0].text,root).node(input.target.pointer+'/$ref').value,'https://identity.invalid/b#/components/schemas/Child');
});
for(const version of ['3.1.2','3.2.1'])test(`cross-file scheme inlining keeps OAuth URLs Server-relative ${version}`,()=>{
 const root='file:///project/api.json',part='file:///project/security/schemes.json';
 const scheme={type:'oauth2',flows:{clientCredentials:{tokenUrl:'token',refreshUrl:'../refresh',scopes:{read:'Read'}}},...(version.startsWith('3.2')?{oauth2MetadataUrl:'oauth-metadata'}:{})};
 const api={openapi:version,info:{title:'OAuth declarations',version:'1'},paths:{},servers:[{url:'https://api.invalid/v1/'}],security:[{Use:['read']}],components:{securitySchemes:{Use:{$ref:'security/schemes.json#/OAuth'}}}};
 const input={snapshot:'server-relative',resources:[{id:root,text:JSON.stringify(api),generation:1},{id:part,text:JSON.stringify({OAuth:scheme}),generation:2}],contexts:[{root,resources:[root,part]}],target:{root,resource:root,generation:1,pointer:'/components/securitySchemes/Use'}};
 const plan=planInline(input),resources=apply(input,plan),value=JSON.parse(resources[0].text);
 assert.deepEqual(value.components.securitySchemes.Use,scheme);assert.deepEqual(value.security,[{Use:['read']}]);
 assert.equal(new URL(value.components.securitySchemes.Use.flows.clientCredentials.tokenUrl,value.servers[0].url).href,'https://api.invalid/v1/token');
 assert.equal(resources[1].text,input.resources[1].text);
});
test('a dual OpenAPI/schema root cannot be extracted into itself or replaced by an inline occurrence',()=>{
 const root='file:///project/root.json',text='{"openapi":"3.2.1","info":{"title":"Root","version":"1"},"paths":{},"components":{"schemas":{"Root":{"$ref":"#"}}}}';
 const input={snapshot:'root',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,generation:1,pointer:''},name:'NestedRoot'};
 assert.throws(()=>planExtract(input),e=>e.code==='refactor.copy.context');
 assert.throws(()=>planInline(input),e=>e.code==='refactor.copy.context');assert.equal(input.resources[0].text,text);
});
