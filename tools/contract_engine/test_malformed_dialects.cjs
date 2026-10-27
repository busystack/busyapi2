const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const versions=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const dialect='https://json-schema.org/draft/2020-12/schema#';
const malformed=[null,false,true,0,1,[],{},'', 'relative', '#fragment', '/schema', 'https://example.invalid/%xx', 'https://example.invalid/path with space', 'https://example.invalid/\\schema', 'https://example.invalid/<schema>', 'https://example.invalid/雪', 'https://example.invalid/schema\n', 'https://example.invalid/schema\r\n', 'https://example.invalid/schema\u2028'];
function fixture(version,format,selection,placement){
 const root='file:///dialects/api.'+format;
 const value={type:'integer',enum:['EXACT']};
 const explicit={$schema:dialect,type:'integer',enum:['EXACT']};
 const api={openapi:version,info:{title:'Keep 雪',version:'api-version'},paths:{},components:{schemas:{Value:value,Explicit:explicit}},'x-literal':{$schema:null,jsonSchemaDialect:false,n:'EXACT'}};
 if(placement==='default')api.jsonSchemaDialect=selection;
 if(placement==='schema')value.$schema=selection;
 const text=(format==='yaml'?'# Keep 雪\r\n'+YAML.stringify(api,{aliasDuplicateObjects:false}).replaceAll('\n','\r\n'):JSON.stringify(api)).replaceAll('"EXACT"','9007199254740993.000').replaceAll('EXACT','9007199254740993.000');
 return {root,snapshot:'malformed-dialect',resources:[{id:root,text,generation:1}]};
}
const runtime=input=>['Value','Explicit'].map(name=>({subject:'response-body',location:name,text:'9007199254740993.000',schema:{resource:input.root,pointer:'/components/schemas/'+name}}));
for(const version of versions)for(const format of ['yaml','json'])for(const placement of ['default','schema'])for(const selection of malformed)
test(`${version} ${format} ${placement} malformed dialect ${JSON.stringify(selection)} cannot select a fallback`,async()=>{
 const input=fixture(version,format,selection,placement),before=input.resources[0].text,graph=createGraph(input).graph;
 const declaration=placement==='default'?'/jsonSchemaDialect':'/components/schemas/Value/$schema';
 if(placement==='default'){
  const structural=analyse(input);assert.equal(structural.specification.family,version.slice(0,3));assert.equal(structural.specification.schemaDialect,null);
 }
 assert.equal(graph.scope(input.root,'/components/schemas/Value').dialect,null);
 const checked=await evaluateSchemas({...input,runtimeInstances:runtime(input)});
 assert.equal(checked.complete,false,JSON.stringify(checked.findings));
 assert(checked.findings.some(f=>f.code==='schema.dialect.malformed'&&f.resource===input.root&&f.pointer===declaration),JSON.stringify(checked.findings));
 assert.equal(checked.runtimeEvaluations[0].complete,false);assert.equal(checked.runtimeEvaluations[0].valid,false);
 assert.equal(checked.runtimeEvaluations[1].complete,true);assert.equal(checked.runtimeEvaluations[1].valid,true,'An independent explicit dialect remains evaluable');
 assert.equal(input.resources[0].text,before);
 const corrected={...input,snapshot:'corrected-dialect',resources:[{...input.resources[0],generation:2,text:new SourceDocument(before,input.root).set(declaration,dialect)}]};
 const clean=await evaluateSchemas({...corrected,runtimeInstances:runtime(corrected)});assert.equal(clean.complete,true,JSON.stringify(clean.findings));assert.deepEqual(clean.runtimeEvaluations.map(e=>[e.complete,e.valid]),[[true,true],[true,true]]);
});
for(const version of versions)for(const format of ['yaml','json'])
test(`${version} ${format} only an absent dialect uses the family default`,async()=>{
 const input=fixture(version,format,undefined,'absent'),result=await evaluateSchemas({...input,runtimeInstances:runtime(input)});assert.equal(result.complete,true,JSON.stringify(result.findings));assert(result.runtimeEvaluations.every(e=>e.complete&&e.valid));assert.equal(analyse(input).specification.schemaDialect,`https://spec.openapis.org/oas/${version.slice(0,3)}/dialect/base`);
});
for(const version of versions)for(const format of ['yaml','json'])
test(`${version} ${format} unsupported URI remains distinct from a malformed declaration`,async()=>{
 const uri='https://example.invalid/dialect#',input=fixture(version,format,uri,'default'),result=await evaluateSchemas({...input,runtimeInstances:runtime(input)});assert.equal(result.complete,false);assert.equal(analyse(input).specification.schemaDialect,uri);assert(result.findings.some(f=>f.code==='schema.dialect.incomplete'));assert(!result.findings.some(f=>f.code==='schema.dialect.malformed'));assert.equal(result.runtimeEvaluations[0].complete,false);
});

for(const version of versions)for(const format of ['yaml','json'])for(const placement of ['default','schema'])for(const uri of ['https://[v1.future]/dialect','https://[vF.future:part]/dialect#'])
test(`${version} ${format} ${placement} IPvFuture dialect is explicit and unsupported: ${uri}`,async()=>{
 const input=fixture(version,format,uri,placement),before=input.resources[0].text,graph=createGraph(input).graph;
 assert.equal(graph.scope(input.root,'/components/schemas/Value').dialect,uri);
 const structural=analyse(input);assert.equal(structural.specification.family,version.slice(0,3));assert.equal(structural.complete,false);assert(!structural.findings.some(f=>f.code==='schema.dialect.malformed'));
 const result=await evaluateSchemas({...input,runtimeInstances:runtime(input)});assert.equal(result.complete,false,JSON.stringify(result.findings));assert(result.findings.some(f=>f.code==='schema.dialect.incomplete'));assert(!result.findings.some(f=>f.code==='schema.dialect.malformed'));assert.equal(result.runtimeEvaluations[0].complete,false);assert.equal(result.runtimeEvaluations[0].valid,false);assert.equal(result.runtimeEvaluations[1].complete,true);assert.equal(result.runtimeEvaluations[1].valid,true);assert.equal(input.resources[0].text,before);
 const pointer=placement==='default'?'/jsonSchemaDialect':'/components/schemas/Value/$schema',corrected={...input,snapshot:'repaired-future-host',resources:[{...input.resources[0],generation:2,text:new SourceDocument(before,input.root).set(pointer,dialect)}]},clean=await evaluateSchemas({...corrected,runtimeInstances:runtime(corrected)});assert.equal(clean.complete,true,JSON.stringify(clean.findings));assert(clean.runtimeEvaluations.every(e=>e.complete&&e.valid));
});
