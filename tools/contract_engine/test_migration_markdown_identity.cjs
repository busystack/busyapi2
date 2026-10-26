const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {createGraph}=require('./dist/model.cjs');
const {documentUriBase,resolveUri}=require('./dist/reference_graph.cjs');
const description='[Guide](../guides/Guide%20One.md?q=a%2Fb#Intro) and ![図](./diagram.svg)';
function fixture(version,format,self){
 const root='file:///approved/contracts/api.'+format;
 const document={...(version==='2.0'?{swagger:version}:{openapi:version}),...(self===undefined?{}:{$self:self}),info:{title:'Keep 雪',version:'1',description},paths:{}};
 const text=(format==='json'?JSON.stringify(document):'# Keep organization\r\n'+YAML.stringify(document).replaceAll('\n','\r\n'))+'\r\n';
 return {root,snapshot:'markdown-identity',targetVersion:'3.2.1',destination:'file:///reviewed/migrated/',resources:[{id:root,text,generation:4}]};
}
for(const version of ['3.2.0','3.2.1'])for(const targetVersion of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const self of ['https://example.invalid/contracts/api','./identity/api.'+format])
test(`${version} -> ${targetVersion} ${format} explicit identity preserves relative Markdown ${self}`,async()=>{
 const input={...fixture(version,format,self),targetVersion},before=input.resources[0].text;
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.status,'faithfully-convertible');
 assert.equal(new Set(Object.values(result.manifest.resourceMappings)).size,Object.values(result.manifest.resourceMappings).length,'Each published file needs one configured retrieval base');
 const output=result.outputs.find(value=>value.id===result.outputRoot);assert(output);
 const sourceGraph=createGraph(input).graph,targetGraph=createGraph({root:result.outputRoot,snapshot:'cold',resources:result.outputs.map(value=>({id:value.id,text:value.text,generation:0}))}).graph;
 const source=sourceGraph.scopes.get(input.root+'#/info'),target=targetGraph.scopes.get(result.outputRoot+'#/info');assert(source&&target);
 assert.equal(targetGraph.docs.get(target.resource).dataNode('/info/description').value,description);
 for(const destination of ['../guides/Guide%20One.md?q=a%2Fb#Intro','./diagram.svg'])
  assert.equal(resolveUri(destination,documentUriBase(sourceGraph,source)).href,resolveUri(destination,documentUriBase(targetGraph,target)).href);
 if(format==='yaml')assert(output.text.startsWith('# Keep organization\r\n'));
 assert.equal(input.resources[0].text,before);
});
for(const version of ['2.0','3.0.4','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} changed Markdown base still blocks without partial output`,async()=>{
 const input=fixture(version,format),before=input.resources[0].text,result=await planMigration(input);
 assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
 const problem=result.problems.find(p=>p.code==='migration.description.relative-links');assert(problem);assert.equal(problem.resource,input.root);assert.equal(problem.pointer,'/info/description');
 assert(input.resources[0].text.slice(...problem.range).includes('Guide'));assert.equal(input.resources[0].text,before);
});

for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const targetVersion of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])
test(`${version} -> ${targetVersion} ${format} retained schema identity preserves nested Markdown`,async()=>{
 const input={...fixture(version,format),targetVersion};
 const document=format==='json'?JSON.parse(input.resources[0].text):YAML.parse(input.resources[0].text);delete document.info.description;
 document.components={schemas:{Value:{$id:'https://example.invalid/schemas/value',type:'object',description}}};
 input.resources[0].text=format==='json'?JSON.stringify(document):YAML.stringify(document);const before=input.resources[0].text;
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));
 const output=result.outputs.find(value=>value.id===result.outputRoot),targetGraph=createGraph({root:result.outputRoot,snapshot:'cold',resources:result.outputs.map(value=>({id:value.id,text:value.text,generation:0}))}).graph;
 const pointer='/components/schemas/Value',sourceGraph=createGraph(input).graph,source=sourceGraph.scopes.get(input.root+'#'+pointer),target=targetGraph.scopes.get(result.outputRoot+'#'+pointer);
 assert(source&&target);assert.equal(documentUriBase(sourceGraph,source),documentUriBase(targetGraph,target));
 assert.equal(targetGraph.docs.get(target.resource).dataNode(pointer+'/description').value,description);assert.equal(input.resources[0].text,before);
});
