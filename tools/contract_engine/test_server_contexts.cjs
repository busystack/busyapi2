const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const dist=process.env.BUSYAPI_SERVER_CONTEXT_DIST||require('node:path').join(__dirname,'dist');
const {analyse}=require(dist+'/model.cjs'),{requestOperation}=require(dist+'/execution.cjs'),{referencePage,referenceDocument}=require(dist+'/reference_projection.cjs');
const patches=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function capture(version,format,placement,servers){
 const root='file:///approved/api.'+format,operation={responses:{200:{description:'OK'}}};
 const value={openapi:version,info:{title:'Server contexts 雪',version:'API-1'},servers:[{url:'https://root.example.invalid/v1'}],paths:{'/items':{get:operation}},'x-exact':'EXACT','x-data':{servers:[{url:'literal invalid %zz'}],host:'user@literal.invalid'}};
 if(placement==='root')value.servers=servers;else if(placement==='path')value.paths['/items'].servers=servers;else operation.servers=servers;
 const text=(format==='json'?JSON.stringify(value,null,2):'# Keep server context and exact numbers\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
 return {root,snapshot:version+'-'+format+'-'+placement,resources:[{id:root,text,generation:7}]};
}
for(const version of patches)for(const format of ['yaml','json'])for(const placement of ['root','path','operation'])for(const fallback of ['', '雪'])test(`${version} ${format} ${placement} empty enum keeps the declared default ${JSON.stringify(fallback)} and family rule`,()=>{
 const input=capture(version,format,placement,[{url:'https://api.example.invalid/v{suffix}',variables:{suffix:{default:fallback,enum:[]}}}]),before=input.resources[0].text;
 if(version.startsWith('3.0')){assert.equal(analyse(input).status,'complete');const variable=requestOperation(selected(input)).servers[0].variables.suffix;assert.equal(variable.default,fallback);assert.deepEqual(variable.enum,[]);assert.equal(variable.defaultOutsideEnumAllowed,true);assert.equal(referencePage(selected(input)).complete,true);}
 else {assert.equal(analyse(input).status,'invalid');assert.equal(assertInvalid(input).code,'server.structure');}
 assert.equal(input.resources[0].text,before);
});
function selected(input){return {...input,resource:input.root,pointer:'/paths/~1items/get'};}
function assertInvalid(input,unsupported=false){
 const before=input.resources[0].text;let failure;
 assert.throws(()=>requestOperation(selected(input)),error=>{
  failure=error;return error.kind===(unsupported?'unsupported':'specification')&&error.source?.resource===input.root&&error.source.range[1]>error.source.range[0];
 });
 const page=referencePage(selected(input)),server=page.effective.find(field=>field.name==='servers');
 assert.equal(page.complete,false);assert.equal(server.complete,false);assert.equal(server.invalid,!unsupported);assert.equal(server.default,undefined);assert.equal(server.issues[0].code,failure.code);assert.equal(server.source.pointer,failure.source.pointer);assert.equal(server.source.generation,7);assert.equal(referenceDocument(input).complete,false);assert.equal(input.resources[0].text,before);
 return failure;
}
for(const version of patches)for(const format of ['yaml','json'])for(const placement of ['root','path','operation']){
 for(const [url,unsupported]of [['https://api.example.invalid/%zz',false],['https://api.example.invalid/bad space',false],['https://api.example.invalid/{unfinished',false],['https://[v1.future]/v1',true]])test(`${version} ${format} ${placement} invalid/unsupported URL ${url} cannot become a complete request or Reference context`,()=>{
  const input=capture(version,format,placement,[{url}]);assert.equal(analyse(input).status,unsupported?'incomplete':'invalid');const problem=assertInvalid(input,unsupported);assert(problem.source.pointer.endsWith('/url'));
 });
 test(`${version} ${format} ${placement} query URL retains its own family meaning`,()=>{
  const input=capture(version,format,placement,[{url:'https://api.example.invalid/v1?selected=1'}]),before=input.resources[0].text;
  if(version.startsWith('3.0')){assert.equal(analyse(input).status,'complete');assert.equal(requestOperation(selected(input)).servers[0].url,'https://api.example.invalid/v1?selected=1');assert.equal(referencePage(selected(input)).complete,true);}
  else {assert.equal(analyse(input).status,'invalid');assert.equal(assertInvalid(input).code,'server.url.query-fragment');}
  assert.equal(input.resources[0].text,before);
 });
 test(`${version} ${format} ${placement} variable default SHOULD/MUST distinction reaches request preparation`,()=>{
  const input=capture(version,format,placement,[{url:'https://{host}.example.invalid/v1',variables:{host:{default:'other',enum:['known']}}}]);
  if(version.startsWith('3.0')){assert.equal(analyse(input).status,'complete');assert.equal(requestOperation(selected(input)).servers[0].variables.host.default,'other');assert.equal(requestOperation(selected(input)).servers[0].variables.host.defaultOutsideEnumAllowed,true);assert.equal(referencePage(selected(input)).complete,true);}
  else assert.equal(assertInvalid(input).code,'server.variable.default-enum');
 });
 test(`${version} ${format} ${placement} repeated variables follow the declared family`,()=>{
  const input=capture(version,format,placement,[{url:'https://{id}.example.invalid/{id}',variables:{id:{default:'fixed'}}}]);
  if(version.startsWith('3.2'))assert.equal(assertInvalid(input).code,'server.variable.repeated');
  else {assert.equal(analyse(input).status,'complete');assert.equal(requestOperation(selected(input)).servers[0].url,'https://{id}.example.invalid/{id}');}
 });
}
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json']){
 for(const servers of [null,false,0,'https://api.example.invalid',{},[null],[false],[0],['https://api.example.invalid'],[[]],[{}],[{url:null}],[{url:false}],[{url:0}],[{url:[]}],[{url:{}}],[{url:'https://api.example.invalid',variables:[]}],[{url:'https://api.example.invalid',variables:null}],[{url:'https://{v}.example.invalid',variables:{v:{}}}],[{url:'https://{v}.example.invalid',variables:{v:{default:false}}}]])test(`${version} ${format} malformed server shape ${JSON.stringify(servers)} is a specification error, not a fabricated URL`,()=>{
  const input=capture(version,format,'operation',servers);assert.equal(analyse(input).status,'invalid');const problem=assertInvalid(input);assert(['server.array.type','server.structure'].includes(problem.code));
 });
 test(`${version} ${format} a local valid server override does not inherit an invalid root URL`,()=>{
  const input=capture(version,format,'operation',[{url:'https://operation.example.invalid/v1'}]),value=YAML.parse(input.resources[0].text);value.servers=[{url:'https://api.example.invalid/%zz'}];input.resources[0].text=format==='json'?JSON.stringify(value):YAML.stringify(value);const before=input.resources[0].text;
  assert.equal(analyse(input).status,'invalid');assert.equal(requestOperation(selected(input)).servers[0].url,'https://operation.example.invalid/v1');assert.equal(referencePage(selected(input)).complete,true);assert.equal(input.resources[0].text,before);
 });
 test(`${version} ${format} Unicode, IPv6 and extension-looking variable names retain valid canonical contexts`,()=>{
  const input=capture(version,format,'root',[{url:'http://[::1]:8080/雪'},{url:'https://api.example.invalid/{x-version}',variables:{'x-version':{default:'v1'}}}]),before=input.resources[0].text;
  assert.equal(analyse(input).status,'complete');const plan=requestOperation(selected(input));assert.equal(plan.complete,true);assert.equal(plan.servers[0].url,'http://[::1]:8080/雪');assert.equal(plan.servers[1].variables['x-version'].default,'v1');assert.equal(referencePage(selected(input)).complete,true);assert.equal(input.resources[0].text,before);
 });
}
test('repeated declaration switches retire request and Reference default policies in the same captured root',()=>{
 for(let cycle=0;cycle<4;cycle++)for(const version of ['3.0.4','3.1.2','3.2.1','3.0.4']){
  const input=capture(version,'json','root',[{url:'https://api.example.invalid/v{suffix}',variables:{suffix:{default:'other',enum:['known']}}}]);input.snapshot='same-held-root';
  if(version.startsWith('3.0')){assert.equal(requestOperation(selected(input)).servers[0].variables.suffix.defaultOutsideEnumAllowed,true);assert.equal(referencePage(selected(input)).complete,true);}
  else assert.equal(assertInvalid(input).code,'server.variable.default-enum');
 }
});
for(const entry of ['3.1.2','3.2.1'])for(const external of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${entry} entry / ${external} shared operation ${format} keeps selected Server declaration ownership`,()=>{
 const input=capture(entry,format,'root',[{url:'https://entry.example.invalid/v1',name:'source-owned'}]),value=YAML.parse(input.resources[0].text),part='file:///approved/part.'+format;
 value.paths['/items']={$ref:'part.'+format+'#/paths/~1shared'};
 const shared={openapi:external,info:{title:'Shared operation',version:'1'},paths:{'/shared':{get:{responses:{200:{description:'OK'}}}}}};
 const encode=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);input.resources[0].text=encode(value);input.resources.push({id:part,text:encode(shared),generation:13});const before=input.resources.map(r=>r.text);
 const target={...input,resource:part,pointer:'/paths/~1shared/get'};
 if(entry.startsWith('3.2')){assert.equal(analyse(input).status,'complete');assert.equal(requestOperation(target).servers[0].url,'https://entry.example.invalid/v1');assert.equal(referencePage(target).complete,true);}
 else {assert.equal(analyse(input).status,'invalid');assert.throws(()=>requestOperation(target),e=>e.kind==='specification'&&e.source.resource===input.root&&e.source.pointer.startsWith('/servers/0'));assert.equal(referencePage(target).complete,false);}
 assert.deepEqual(input.resources.map(r=>r.text),before);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])for(const kind of ['array','server','variables','variable'])test(`${version} read-only ${kind} aliases retain canonical Server contexts and original bytes`,()=>{
 const hold=kind==='array'?'x-held: &held [{url: "http://[::1]:8080/v1"}]\nservers: *held':kind==='server'?'x-held: &held {url: "http://[::1]:8080/v1"}\nservers: [*held]':kind==='variables'?'x-held: &held {suffix: {default: v1}}\nservers: [{url: "http://[::1]:8080/{suffix}", variables: *held}]':'x-held: &held {default: v1}\nservers: [{url: "http://[::1]:8080/{suffix}", variables: {suffix: *held}}]';
 const root='file:///approved/api.yaml',text='openapi: '+version+'\ninfo: {title: "Read alias", version: "1"}\n'+hold+'\npaths: {/items: {get: {responses: {"204": {description: "No body"}}}}}\n',input={root,snapshot:version+kind,resources:[{id:root,text,generation:1}]};
 assert.equal(analyse(input).status,'complete');const plan=requestOperation(selected(input));assert.equal(plan.complete,true);assert(plan.servers[0].url.startsWith('http://[::1]:8080/'));assert.equal(referencePage(selected(input)).complete,true);assert.equal(input.resources[0].text,text);
});
for(const version of patches)for(const format of ['yaml','json'])for(const placement of ['root','path','operation'])for(const fragment of ['#anchor','?base=0#anchor','#'])test(`${version} ${format} ${placement} fragment ${fragment} keeps source and captured HTTP policy`,()=>{
 const url='http://[::1]:8080/v1'+fragment,input=capture(version,format,placement,[{url}]),before=input.resources[0].text;
 if(version.startsWith('3.0')){
  assert.equal(analyse(input).status,'complete');const server=requestOperation(selected(input)).servers[0];assert.equal(server.url,url);assert.equal(server.httpFragmentPolicy,'omit');assert.equal(server.urlSource.resource,input.root);assert(server.urlSource.pointer.endsWith('/url'));assert(server.urlSource.range[1]>server.urlSource.range[0]);assert.equal(referencePage(selected(input)).complete,true);
 }else assert.equal(assertInvalid(input).code,'server.url.query-fragment');
 assert.equal(input.resources[0].text,before);
});
for(const version of patches)for(const format of ['yaml','json'])for(const placement of ['root','path','operation'])for(const suffix of ['\x7f','%7F'])test(`${version} ${format} ${placement} template suffix ${JSON.stringify(suffix)} distinguishes literals from percent encoding`,()=>{
 const url='https://api.example.invalid/{v}'+suffix,input=capture(version,format,placement,[{url,variables:{v:{default:'v1'}}}]),before=input.resources[0].text;
 if(suffix==='\x7f')assert.equal(assertInvalid(input).code,version.startsWith('3.2')?'server.url.template':'server.url.template-literal');
 else {assert.equal(analyse(input).status,'complete');assert.equal(requestOperation(selected(input)).servers[0].url,url);assert.equal(referencePage(selected(input)).complete,true);}
 assert.equal(input.resources[0].text,before);
});
