const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas,standardResource}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const versions=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const literal='https://example.invalid/literal#';
function fixture(version,format,uri,placement){
 const root='file:///dialects/api.'+format,model='file:///dialects/model.'+format;
 const value={type:'object',required:['n','$schema'],properties:{n:{type:'integer',enum:['EXACT',0]},$schema:{type:'string',enum:[literal]}},example:{n:0,$schema:literal}};
 const api={openapi:version,info:{title:'Keep 雪',version:'api-version'},paths:{},components:{schemas:{Value:placement==='resource'?{$ref:'model.'+format}:value}}};
 if(placement==='default')api.jsonSchemaDialect=uri;
 else value.$schema=uri;
 if(placement==='resource'){
  value.$id='./model-id';value.$dynamicAnchor='node';
  value.properties.children={type:'array',items:{$dynamicRef:'#node'}};
 }
 const render=value=>(format==='yaml'?'# Keep source 雪\r\n'+YAML.stringify(value,{aliasDuplicateObjects:false}).replaceAll('\n','\r\n'):JSON.stringify(value)).replaceAll('"EXACT"','9007199254740993.000').replaceAll('EXACT','9007199254740993.000')+'\r\n';
 return {root,snapshot:'dialect-resource-identity',resources:[{id:root,text:render(api),generation:1},...(placement==='resource'?[{id:model,text:render(value),generation:2}]:[])]};
}
for(const version of versions)for(const format of ['yaml','json'])for(const placement of ['default','schema','resource']){
 const family=version.slice(0,3),uris=['https://json-schema.org/draft/2020-12/schema',`https://spec.openapis.org/oas/${family}/dialect/base`,`https://spec.openapis.org/oas/${family}/dialect/${family==='3.1'?'2024-11-10':'2026-02-26'}`,...(family==='3.2'?['https://spec.openapis.org/oas/3.2/dialect/2025-09-17']:[])];
 for(const uri of uris)test(`${version} ${format} ${placement} preserves dialect resource identity ${uri}`,async()=>{
  const outcomes=[];
  for(const declared of [uri,uri+'#']){
   const input=fixture(version,format,declared,placement),before=input.resources.map(r=>r.text),checked=analyse(input);
   assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.findings,[]);
   const resource=placement==='resource'?input.resources[1].id:input.root,pointer=placement==='resource'?'':'/components/schemas/Value',scope=createGraph(input).graph.scope(resource,pointer);
   assert.equal(scope.dialect,declared,'The declared spelling remains provenance');
   const good=placement==='resource'?`{"n":9007199254740993.000,"$schema":"${literal}","children":[{"n":0,"$schema":"${literal}"}]}`:`{"n":9007199254740993.000,"$schema":"${literal}"}`;
   const bad=`{"n":1,"$schema":"${literal}"}`;
   const result=await evaluateSchemas({...input,runtimeInstances:[good,bad].map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer:'/components/schemas/Value'}}))});
   assert.equal(result.complete,true,JSON.stringify(result.findings));assert(result.runtimeEvaluations.every(e=>e.complete));assert.deepEqual(result.runtimeEvaluations.map(e=>e.valid),[true,false]);
   assert.deepEqual(input.resources.map(r=>r.text),before);outcomes.push(result.runtimeEvaluations.map(e=>e.valid));
  }
  assert.deepEqual(outcomes[0],outcomes[1]);
 });
}

for(const version of versions)for(const format of ['yaml','json'])for(const boolean of [true,false])
test(`${version} ${format} empty-fragment default dialect retains boolean schema ${boolean}`,async()=>{
 const input=fixture(version,format,'https://json-schema.org/draft/2020-12/schema#','default');
 input.resources[0].text=new SourceDocument(input.resources[0].text,input.root).set('/components/schemas/Value',boolean);const before=input.resources[0].text;
 const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'response-body',location:'application/json',text:'false',schema:{resource:input.root,pointer:'/components/schemas/Value'}}]});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.runtimeEvaluations[0].complete,true);assert.equal(result.runtimeEvaluations[0].valid,boolean);assert.equal(input.resources[0].text,before);
});

for(const version of versions)for(const uri of ['https://example.invalid/dialect#','https://json-schema.org/draft/2020-12/schema#/properties','urn:busyapi:schema-dialect:swagger-2.0#','https://spec.openapis.org/oas/3.0/dialect#'])
test(`${version} unsupported dialect stays incomplete ${uri}`,async()=>{
 const input=fixture(version,'json',uri,'schema'),before=input.resources[0].text,result=await evaluateSchemas({...input,runtimeInstances:[{subject:'response-body',location:'application/json',text:'0',schema:{resource:input.root,pointer:'/components/schemas/Value'}}]});
 assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='schema.dialect.incomplete'));assert.equal(result.runtimeEvaluations[0].complete,false);assert.equal(result.runtimeEvaluations[0].valid,false);assert.equal(input.resources[0].text,before);
});

for(const uri of ['https://json-schema.org/draft/2020-12/schema','https://spec.openapis.org/oas/3.1/dialect/base','https://spec.openapis.org/oas/3.2/dialect/base'])
test(`packaged standard lookup treats an empty fragment as the same resource ${uri}`,async()=>{
 const canonical=await standardResource({uri}),alias=await standardResource({uri:uri+'#'});assert.equal(canonical.found,true);assert.equal(alias.found,true);assert.equal(alias.source.id,canonical.source.id);assert.equal(alias.source.text,canonical.source.text);assert.equal(alias.source.identity,canonical.source.identity);assert(alias.source.aliases.every(uri=>!uri.includes('#')));
});

for(const version of ['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])
test(`${version} ${format} a standard dialect alias cannot activate modern schema keywords`,()=>{
 const root='file:///dialects/legacy.'+format,value={type:'string',$schema:'https://json-schema.org/draft/2020-12/schema#'};
 const api={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Legacy',version:'1'},paths:{},...(version==='2.0'?{definitions:{Value:value}}:{components:{schemas:{Value:value}}})};
 const text=format==='yaml'?YAML.stringify(api):JSON.stringify(api),input={root,snapshot:'legacy-dialect',resources:[{id:root,text,generation:1}]},result=analyse(input);
 assert.notEqual(result.status,'complete');assert(result.findings.some(f=>f.severity==='error'&&f.resource===root));assert.equal(input.resources[0].text,text);
});

for(const version of ['3.1.2','3.2.1'])for(const dialect of [1,true,{},[]])
test(`${version} malformed dialect ${JSON.stringify(dialect)} remains a document finding`,()=>{
 const input=fixture(version,'json','https://json-schema.org/draft/2020-12/schema','default');input.resources[0].text=new SourceDocument(input.resources[0].text,input.root).set('/jsonSchemaDialect',dialect);const before=input.resources[0].text;
 const result=analyse(input);assert.notEqual(result.status,'complete');assert(result.findings.some(f=>f.severity==='error'&&f.pointer.startsWith('/jsonSchemaDialect')));assert.equal(input.resources[0].text,before);
});
