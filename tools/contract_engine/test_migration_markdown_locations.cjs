const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml'),{Parser}=require('commonmark');
const {planMigration}=require('./dist/migration.cjs'),{createGraph}=require('./dist/model.cjs'),{resolveUri,documentUriBase}=require('./dist/reference_graph.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const versions=['2.0','3.0.4','3.1.2','3.2.1'];
const patches=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function description(kind){
 const uri=kind==='network'?'//docs.example.invalid/guide/%E9%9B%AA?zero=0&empty=#part':kind==='parent'?'../../guide/%7Euser?zero=0&empty=#part':'/guide/雪?zero=0&empty=#part';
 return ['Keep **organization** 雪.',`[Guide](${uri} "Kept title")`,
 '[Named][guide] [guide][] [guide]',`[guide]: <${uri}> "Definition title"`,
 `![Icon](${kind==='network'?'//docs.example.invalid/icon.svg':'/icon.svg'})`,
 '`[Inline code](../code)`','```text','[Block code](../block)','```',
 '<!-- [Comment](../comment) -->','[Unused]: ../unused','[Anchor](#inside)',
 '\\[Escaped\\](../literal)'].join('\n');
}
function fixture(version,format,kind='root',alias=false){
 const root='file:///source/deep/api.'+format,value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Keep 雪',version:'api-version',description:description(kind)},paths:{},'x-kept':{description:'[Literal payload](../payload)',n:'EXACT',flag:false,empty:''}};
 const text=(format==='yaml'?'# Keep source organization 雪\r\n'+YAML.stringify(value,{aliasDuplicateObjects:false}).replaceAll('\n','\r\n'):JSON.stringify(value)).replaceAll('"EXACT"','9007199254740993.000').replaceAll('EXACT','9007199254740993.000');
 return {root,snapshot:'markdown-locations',resources:[{id:root,text,generation:1,...(alias?{aliases:['https://contracts.example.invalid/deep/api.'+format]}:{})}],destination:'file:///converted/output/'};
}
function destinations(source){
 const walker=new Parser().parse(source).walker(),out=[];let event;
 while((event=walker.next()))if(event.entering&&['link','image'].includes(event.node.type)&&!event.node.destination.startsWith('#'))out.push(event.node.destination);
 return out;
}
async function convertible(version,targetVersion,format,kind){
 const input={...fixture(version,format,kind),targetVersion},before=input.resources[0].text,result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.status,'faithfully-convertible');
 const output=result.outputs.find(o=>o.id===result.outputRoot),original=new SourceDocument(before,input.root),migrated=new SourceDocument(output.text,output.id);
 assert.equal(migrated.node('/info/description').value,original.node('/info/description').value,'No Markdown/source rewrite is necessary');
 assert.equal(migrated.dataJson('/x-kept'),original.dataJson('/x-kept'));
 const sourceGraph=createGraph(input).graph,targetGraph=createGraph({root:result.outputRoot,snapshot:'cold',resources:result.outputs.map(o=>({id:o.id,text:o.text,generation:0}))}).graph;
 const sourceBase=documentUriBase(sourceGraph,sourceGraph.scope(input.root,'/info')),targetBase=documentUriBase(targetGraph,targetGraph.scope(result.outputRoot,'/info'));
 assert.notEqual(sourceBase,targetBase,'The retrieval base really changed');
 assert.deepEqual(destinations(original.node('/info/description').value).map(d=>resolveUri(d,sourceBase).href),destinations(migrated.node('/info/description').value).map(d=>resolveUri(d,targetBase).href));
 assert.equal(input.resources[0].text,before);assert.equal(result.outputs.length,1);
 if(format==='yaml')assert(output.text.startsWith('# Keep source organization 雪\r\n'));
}
for(const version of versions)for(const target of versions)for(const format of ['yaml','json'])for(const kind of ['root','network'])
 test(`${version} -> ${target} ${format} ${kind} Markdown keeps actual resolved destinations`,()=>convertible(version,target,format,kind));
for(const version of patches)for(const format of ['yaml','json'])
 test(`${version} ${format} published patch keeps root-relative Markdown destinations`,()=>convertible(version,'3.2.1',format,'root'));
for(const version of versions)for(const format of ['yaml','json'])for(const kind of ['folder','mixed','empty','protocol'])
 test(`${version} ${format} ${kind} changed rendered destinations remain located blockers`,async()=>{
  const input={...fixture(version,format,kind==='protocol'?'network':'root',kind==='protocol'),targetVersion:'3.2.1'};
  if(kind!=='protocol'){
   const value=kind==='folder'?'[Guide](../guide)':kind==='empty'?'[Current]()':description('root')+'\n[Different](../guide)';
   input.resources[0].text=new SourceDocument(input.resources[0].text,input.root).set('/info/description',value);
  }
  const before=input.resources[0].text,result=await planMigration(input);
  assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);
  const issue=result.problems.find(p=>p.code==='migration.description.relative-links');assert(issue,JSON.stringify(result.problems));assert.equal(issue.resource,input.root);assert.equal(issue.pointer,'/info/description');assert(issue.range[1]>issue.range[0]);assert.equal(input.resources[0].text,before);
 });

for(const version of versions)for(const format of ['yaml','json'])
 test(`${version} ${format} normalized parent paths keep the same rendered destinations`,()=>convertible(version,'3.2.1',format,'parent'));
for(const version of versions)for(const format of ['yaml','json'])
 test(`${version} ${format} unresolvable Markdown URI is an explicit source-located failure`,async()=>{
  const input={...fixture(version,format),targetVersion:'3.2.1'};
  input.resources[0].text=new SourceDocument(input.resources[0].text,input.root).set('/info/description','[Guide](//[invalid]/guide)');
  const before=input.resources[0].text,result=await planMigration(input);
  assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);
  const issue=result.problems.find(p=>p.code==='migration.description.uri');assert(issue,JSON.stringify(result.problems));assert.equal(issue.reason,'source-incomplete');assert.equal(issue.resource,input.root);assert.equal(issue.pointer,'/info/description');assert(issue.range[1]>issue.range[0]);assert.equal(input.resources[0].text,before);
 });

for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const targetVersion of ['3.0.4','2.0'])for(const format of ['yaml','json'])for(const protocol of ['https','file'])
 test(`${version} -> ${targetVersion} ${format} original schema identity context ${protocol} survives structural stages`,async()=>{
  const input={...fixture(version,format),targetVersion};
  const beforeDoc=new SourceDocument(input.resources[0].text,input.root);
  let text=beforeDoc.remove('/info/description');
  const schema={$id:protocol==='https'?'https://schemas.example.invalid/value':'file:///original-schema/value',type:'string',description:'[Guide](/guide)'};
  text=new SourceDocument(text,input.root).set('/components',{schemas:{Value:schema}});input.resources[0].text=text;const before=text;
  const result=await planMigration(input);
  if(protocol==='https'){
   assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
   const issue=result.problems.find(p=>p.code==='migration.description.relative-links');assert(issue,JSON.stringify(result.problems));assert.equal(issue.resource,input.root);assert.equal(issue.pointer,'/components/schemas/Value/description');assert(input.resources[0].text.slice(...issue.range).includes('Guide'));
  }else{
   assert.equal(result.complete,true,JSON.stringify(result.problems));
   const output=result.outputs.find(o=>o.id===result.outputRoot),pointer=targetVersion==='2.0'?'/definitions/Value':'/components/schemas/Value';
   assert.equal(new SourceDocument(output.text,output.id).node(pointer+'/description').value,schema.description);
  }
  assert.equal(input.resources[0].text,before);
 });
for(const version of versions)for(const format of ['yaml','json'])
 test(`${version} ${format} a scope named description is plain map data`,async()=>{
  const input={...fixture(version,format),targetVersion:'3.2.1'};
  let doc=new SourceDocument(input.resources[0].text,input.root),text=doc.remove('/info/description');
  const scopes={description:'[Literal scope label](../uninterpreted)',read:'read items'};
  const scheme=version==='2.0'?{type:'oauth2',flow:'implicit',authorizationUrl:'https://auth.example.invalid/authorize',scopes}:{type:'oauth2',flows:{implicit:{authorizationUrl:'https://auth.example.invalid/authorize',scopes}}};
  text=new SourceDocument(text,input.root).set(version==='2.0'?'/securityDefinitions':'/components',version==='2.0'?{Access:scheme}:{securitySchemes:{Access:scheme}});input.resources[0].text=text;
  const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(input.resources[0].text,text);
  const output=result.outputs.find(o=>o.id===result.outputRoot),after=new SourceDocument(output.text,output.id);assert.equal(after.dataJson('/components/securitySchemes/Access/flows/implicit/scopes'),new SourceDocument(text,input.root).dataJson(version==='2.0'?'/securityDefinitions/Access/scopes':'/components/securitySchemes/Access/flows/implicit/scopes'));
 });

for(const format of ['yaml','json'])for(const mode of ['inline','reusable','fragment','mapped-fragment'])
 test(`Swagger ${format} ${mode} body-description context follows its surviving owner`,async()=>{
  const input={...fixture('2.0',format),targetVersion:'3.2.1'};
  let text=new SourceDocument(input.resources[0].text,input.root).remove('/info/description');
  const set=(pointer,value)=>{text=new SourceDocument(text,input.root).set(pointer,value);};
  for(const [name,value]of Object.entries({host:'fixture.example.invalid',schemes:['https'],basePath:'/v1',consumes:['application/json'],produces:['application/json']}))set('/'+name,value);
  const body={name:'payload',in:'body',required:true,description:'[Guide](/guide)',schema:{type:'object',properties:{n:{type:'integer'}}}};
  const reference=mode==='inline'?body:{$ref:mode==='reusable'?'#/parameters/Payload':'payload.'+format};
  set('/paths',{'/items':{post:{parameters:[reference],responses:{200:{description:'Value',schema:{type:'string'}}}}}});
  if(mode==='reusable')set('/parameters',{Payload:body});
  input.resources[0].text=text;
  if(mode==='fragment'||mode==='mapped-fragment')input.resources.push({id:'file:///source/deep/payload.'+format,text:format==='json'?JSON.stringify(body):YAML.stringify(body),generation:1,...(mode==='mapped-fragment'?{aliases:['https://schemas.example.invalid/body-parameter']}:{})});
  const before=input.resources.map(r=>r.text),result=await planMigration(input);
  if(mode==='mapped-fragment'){
   assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
   const issue=result.problems.find(p=>p.code==='migration.description.relative-links');assert(issue,JSON.stringify(result.problems));assert.equal(issue.resource,input.resources[1].id);assert.equal(issue.pointer,'/description');
  }else{
   assert.equal(result.complete,true,JSON.stringify(result.problems));
   const output=result.outputs.find(o=>o.id===result.outputRoot),graph=createGraph({root:output.id,snapshot:'cold-body',resources:result.outputs.map(o=>({id:o.id,text:o.text,generation:0}))}).graph;
   assert([...graph.scopes.values()].some(scope=>scope.kind==='request-body'&&graph.docs.get(scope.resource).dataNode(scope.pointer)?.value?.description===body.description));
  }
  assert.deepEqual(input.resources.map(r=>r.text),before);
 });

for(const version of ['3.1.2','3.2.1'])for(const targetVersion of ['3.1.2','3.2.1'])
 test(`${version} -> ${targetVersion} YAML aliases keep each logical Markdown context`,async()=>{
  const input=fixture(version,'yaml');input.targetVersion=targetVersion;
  input.resources[0].text=[
   '# Keep shared Markdown contexts',`openapi: ${version}`,'info: {title: Keep, version: "1"}','paths: {}','components:','  schemas:',
   '    A:','      $id: https://a.example.invalid/schema','      type: object','      properties:','        value: &shared','          type: string','          description: "[Guide](../guide)"',
   '    B:','      $id: https://b.example.invalid/schema','      type: object','      properties:','        value: *shared','',
  ].join('\r\n');
  const before=input.resources[0].text,result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(input.resources[0].text,before);
  const output=result.outputs.find(o=>o.id===result.outputRoot);assert(output.text.includes('&shared'));assert(output.text.includes('*shared'));
  const original=createGraph(input).graph,target=createGraph({root:output.id,snapshot:'cold-alias',resources:[{id:output.id,text:output.text,generation:0}]}).graph;
  for(const name of ['A','B']){
   const pointer='/components/schemas/'+name+'/properties/value',source=original.scope(input.root,pointer),destination=target.scope(output.id,pointer);
   assert.equal(documentUriBase(original,source),documentUriBase(target,destination));
  }
 });
