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
test(`${version} ${format} changed Markdown base gets a reviewed destination mapping`,async()=>{
 const input=fixture(version,format),before=input.resources[0].text,result=await planMigration(input);
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);
 const output=result.outputs.find(value=>value.id===result.outputRoot);assert(output);
 const target=createGraph({root:result.outputRoot,resources:result.outputs.map(value=>({id:value.id,text:value.text,generation:0}))}).graph;
 const actual=target.docs.get(result.outputRoot).dataNode('/info/description').value;
 assert(actual.includes('file:///approved/guides/Guide%20One.md?q=a%2Fb#Intro'));
 assert(actual.includes('file:///approved/contracts/diagram.svg'));
 assert(result.presentationChanges.some(value=>value.resource===input.root&&value.pointer==='/info/description'));
 assert.equal(input.resources[0].text,before);
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


const {Parser}=require('commonmark');
const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const rich=[
 '# Keep 雪 😀',
 '[inline](./guide(a).md?q=a&amp;b=2#part "Keep title")',
 '![image](<../images/caf%C3%A9.svg> "図")',
 '[full][guide] [guide][] [guide] ![guide][]',
 '[guide]: <./reference%20guide.md?q=1&b=2#part> "Keep definition title"',
 '',
 '> [nested][nested]',
 '>',
 '> [nested]: ../nested.md',
 '',
 '[local](#intro) [query](?q=2#part) [empty]() [absolute](https://other.invalid/fixed)',
 '[escaped](./bracket\\(one\\).md)',
 '[unused]: ../leave-unused.md',
 '',
 '@TICK@[literal](../inline-code.md)@TICK@',
 '',
 '@TICK@@TICK@@TICK@md',
 '[literal](../fenced-code.md)',
 '@TICK@@TICK@@TICK@',
 '',
 '<div>',
 '[literal](../html.md)',
 '</div>',
 '',
 '\\[literal](../escaped-label.md)',
 'Keep plain ../prose.md and exact 9007199254740993.00.',
].join('\n').replaceAll('@TICK@',String.fromCharCode(96));
function rendered(markdown,base){
 const walker=new Parser().parse(markdown).walker(),events=[];let event;
 while((event=walker.next())){
  const node=event.node;
  events.push([event.entering,node.type,node.literal,node.title,node.headingLevel,node.info,
   node.destination===null?null:node.destination===undefined?undefined:
    node.destination.startsWith('#')?node.destination:resolveUri(node.destination,base).href]);
 }
 return events;
}
for(const version of versions)for(const format of ['yaml','json'])
test(`${version} ${format} migration repairs rendered Markdown only, retaining code and literal prose`,async()=>{
 const input=fixture(version,format),document=format==='json'?JSON.parse(input.resources[0].text):YAML.parse(input.resources[0].text);
 document.info.description=rich;
 input.resources[0].text=(format==='json'?JSON.stringify(document):'# Keep source\r\n'+YAML.stringify(document).replaceAll('\n','\r\n'))+'\r\n';
 const before=input.resources[0].text,result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.producerVersion,'29');
 const output=result.outputs.find(value=>value.id===result.outputRoot),target=createGraph({root:result.outputRoot,resources:result.outputs.map(value=>({...value,generation:0}))}).graph;
 const actual=target.docs.get(result.outputRoot).dataNode('/info/description').value;
 assert.deepEqual(rendered(actual,result.outputRoot),rendered(rich,input.root));
 for(const literal of ['[unused]: ../leave-unused.md','[literal](../inline-code.md)','[literal](../fenced-code.md)',
  '[literal](../html.md)','\\[literal](../escaped-label.md)','Keep plain ../prose.md and exact 9007199254740993.00.'])assert(actual.includes(literal),literal);
 assert(actual.includes('[local](#intro)'));assert(actual.includes('https://other.invalid/fixed'));
 assert(actual.includes('file:///approved/contracts/api.'+format+'?q=2#part'));
 assert(result.presentationChanges.some(value=>value.resource===input.root&&value.pointer==='/info/description'));
 if(format==='yaml')assert(output.text.startsWith('# Keep source\r\n'));
 assert.equal(input.resources[0].text,before);
});

for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const targetVersion of ['3.0.4','2.0'])for(const format of ['yaml','json'])
test(`${version} -> ${targetVersion} ${format} lowered schema identity retains Markdown targets`,async()=>{
 const input={...fixture(version,format),targetVersion},document=format==='json'?JSON.parse(input.resources[0].text):YAML.parse(input.resources[0].text);
 delete document.info.description;
 document.components={schemas:{Value:{$id:'https://schemas.invalid/models/value',type:'string',description:rich}}};
 input.resources[0].text=format==='json'?JSON.stringify(document):YAML.stringify(document);const before=input.resources[0].text;
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));
 const target=createGraph({root:result.outputRoot,resources:result.outputs.map(value=>({...value,generation:0}))}).graph;
 const pointer=(targetVersion==='2.0'?'/definitions':'/components/schemas')+'/Value/description';
 const actual=target.docs.get(result.outputRoot).dataNode(pointer).value;
 assert.deepEqual(rendered(actual,result.outputRoot),rendered(rich,'https://schemas.invalid/models/value'));
 assert(result.presentationChanges.some(value=>value.resource===input.root&&value.pointer==='/components/schemas/Value/description'));
 assert.equal(input.resources[0].text,before);
});

for(const format of ['yaml','json'])test(`${format} a rendered description also used as literal data is not silently changed`,async()=>{
 const input=fixture('3.1.2',format),doc={openapi:'3.1.2',info:{title:'Shared data',version:'1'},paths:{},components:{schemas:{Value:{$ref:'models.yaml#/schema'}}}};
 // The captured Response Object is also a schema's literal default payload.
 doc.paths={'/x':{get:{responses:{200:{$ref:'models.yaml#/schema/default'}}}}};
 input.resources[0].text=format==='json'?JSON.stringify(doc):YAML.stringify(doc);
 const shared={schema:{type:'object',default:{description:'[Guide](../guide)'}}};
 input.resources.push({id:'file:///approved/contracts/models.yaml',text:YAML.stringify(shared),generation:1});
 const before=input.resources.map(value=>value.text),result=await planMigration(input);
 assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
 assert(result.problems.some(value=>value.code==='migration.description.literal-context'),JSON.stringify(result.problems));
 assert.deepEqual(input.resources.map(value=>value.text),before);
});

for(const body of [
 'info: {title: Keep, version: "1", description: &docs "[Guide](../guide)"}\nx-data: *docs\n',
 'info: &info {title: Keep, version: "1", description: "[Guide](../guide)"}\nx-data: *info\n',
])test('a shared YAML documentation edit retains its ownership refusal and originals',async()=>{
 const root='file:///approved/contracts/api.yaml',text='openapi: 3.1.2\n'+body+'paths: {}\n';
 const input={root,snapshot:'shared-markdown',targetVersion:'3.2.1',destination:'file:///reviewed/',resources:[{id:root,text,generation:1}]};
 const result=await planMigration(input);assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);
 assert(result.problems.some(value=>value.code==='edit.shared'),JSON.stringify(result.problems));assert.equal(input.resources[0].text,text);
});
