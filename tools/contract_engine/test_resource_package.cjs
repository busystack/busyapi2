const assert=require('node:assert/strict');
const {test}=require('node:test');
const {describeResourcePackage}=require('./dist/resource_package.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {createGraph}=require('./dist/model.cjs');

for(const version of ['3.1.2','3.2.1'])test(`exact resource package exposes only established URI/anchor ownership ${version}`,()=>{
 const root='file:///original/root.json',model='file:///cache/value.json',uri='https://original.invalid/model.json';
 const text='{"$schema":"https://json-schema.org/draft/2020-12/schema","$defs":{"Tree":{"$id":"tree","$dynamicAnchor":"node","properties":{"child":{"$dynamicRef":"#node"}},"const":{"exact":9007199254740993,"$ref":"payload data"}}}}';
 const value={openapi:version,info:{title:'Package',version:'1'},paths:{},components:{schemas:{Model:{$ref:uri+'#/$defs/Tree'}}},'x-data':{$id:'not-identity',$ref:'literal data'}};
 const input={root,snapshot:'immutable',resources:[{id:root,text:JSON.stringify(value),generation:1,identity:'root'},{id:model,text,generation:2,identity:'model',aliases:[uri]}]};
 const frozen=structuredClone(input),result=describeResourcePackage(input),context=createGraph(input);
 assert.deepEqual(input,frozen);assert.equal(result.root,root);assert.equal(result.snapshot,'immutable');
 assert(result.identities.some(i=>i.uri==='https://original.invalid/tree#node'&&i.resource===model&&i.pointer==='/$defs/Tree'));
 assert(!result.identities.some(i=>i.uri.includes('not-identity')||i.uri.includes('literal')||i.uri.includes('payload')));
 for(const item of result.identities){const node=context.docs.get(item.resource).dataNode(item.pointer);assert.deepEqual(item.range,node.range);}
 assert.deepEqual(describeResourcePackage({...input,resources:[...input.resources].reverse()}),result);
 const raw=new SourceDocument(text,model);assert(raw.dataJson('/$defs/Tree/const').includes('9007199254740993'));
 const missing={...input,resources:[input.resources[0]]};assert.throws(()=>describeResourcePackage(missing),e=>e.code==='bundle.graph');
 const collision={...input,resources:[...input.resources,{id:'file:///cache/other.json',text:'{"$id":"https://original.invalid/tree"}',generation:3}]};
 assert.throws(()=>describeResourcePackage(collision),e=>e.code==='bundle.graph');assert.deepEqual(input,frozen);
});
test('resource-package bindings retain physical YAML alias and occurrence coordinates',()=>{
 const root='file:///original/aliases.yaml',text='openapi: 3.2.1\ninfo: {title: Aliases, version: "1"}\npaths: {}\nx-definition: &node\n  $id: https://schemas.invalid/node\n  type: string\ncomponents:\n  schemas:\n    Node: *node\n';
 const input={root,snapshot:'alias-coordinates',resources:[{id:root,text,generation:1}]};
 const result=describeResourcePackage(input),binding=result.identities.find(i=>i.uri==='https://schemas.invalid/node');
 assert.equal(binding.pointer,'/components/schemas/Node');assert.equal(binding.physicalPointer,'/x-definition');
 assert.equal(text.slice(...binding.occurrenceRange),'*node');assert(text.slice(...binding.range).includes('$id: https://schemas.invalid/node'));
 assert.equal(input.resources[0].text,text);
});
