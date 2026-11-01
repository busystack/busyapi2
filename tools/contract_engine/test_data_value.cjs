const assert=require('node:assert/strict');
const {test}=require('node:test');
const {inspect,readDataValue,propose}=require('./dist/model.cjs');
const {SourceDocument}=require('./dist/document.cjs');
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`captured large data ${version} ${json?'JSON':'YAML'} preserves exact numbers, literal references and authored absence`,()=>{
 const root='file:///project/root.'+(json?'json':'yaml'),description='line 雪😀\n'.repeat(3000);
 const payload='{"number":9007199254740993.00,"$ref":"literal payload","items":['+Array(4000).fill('false').join(',')+']}';
 const source=json?'{"openapi":"'+version+'","info":{"title":"Data","version":"1"},"paths":{},"components":{"examples":{"Payload":{"value":'+payload+',"description":'+JSON.stringify(description)+'}}},"x-kept":null}':
  '# comment 😀\r\nopenapi: '+version+'\r\ninfo: {title: Data, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  examples:\r\n    Payload:\r\n      value: '+payload+'\r\n      description: '+JSON.stringify(description)+'\r\nx-kept: null';
 const input={root,snapshot:'captured',resource:root,pointer:'/components/examples/Payload',resources:[{id:root,generation:7,identity:'source',text:source}]};
 const projected=inspect(input),value=projected.fields.find(field=>field.name==='value'),text=projected.fields.find(field=>field.name==='description');
 assert.equal(value.raw,undefined);assert.equal(text.raw,undefined);assert.equal(text.dataType,'string');
 const data=readDataValue({...input,target:value.target,representation:'json'});assert.equal(data.value,payload);assert.equal(data.snapshot,'captured');
 assert.equal(readDataValue({...input,target:text.target,representation:'text'}).value,description);
 const changed=data.value.replace('9007199254740993.00','9007199254740994.00');
 const plan=propose({...input,target:projected,actions:[{kind:'setData',pointer:value.target.pointer,raw:changed}]});
 let actual=source;for(const edit of plan.edits.reverse()){assert.equal(actual.slice(edit.start,edit.end),edit.expected);actual=actual.slice(0,edit.start)+edit.replacement+actual.slice(edit.end);}
 assert.equal(actual,source.replace('9007199254740993.00','9007199254740994.00'));
 assert.equal(new SourceDocument(actual,root).dataJson(value.target.pointer),changed);
 assert.equal(input.resources[0].text,source);assert.equal(inspect(input).references.length,0);
 assert.throws(()=>readDataValue({...input,target:{...value.target,generation:8},representation:'json'}),e=>e.code==='data.value.stale');
 assert.throws(()=>readDataValue({...input,target:{...value.target,range:[0,1]},representation:'json'}),e=>e.code==='data.value.stale');
 assert.throws(()=>readDataValue({...input,target:value.target,representation:'text'}),e=>e.code==='data.value.type');
});
test('shared YAML data is not silently expanded into an independently editable form',()=>{
 const root='file:///project/root.yaml',source='openapi: 3.2.1\ninfo: {title: Shared, version: "1"}\npaths: {}\ncomponents:\n  examples:\n    A: {value: &shared {number: 9007199254740993.00}}\n    B: {value: *shared}\n';
 const input={root,snapshot:'shared',resources:[{id:root,text:source,generation:1}]};
 const projected=inspect({...input,resource:root,pointer:'/components/examples/B'});
 const value=projected.fields.find(field=>field.name==='value');
 assert.throws(()=>readDataValue({...input,target:value.target,representation:'json'}),e=>e.code==='edit.shared');
});
test('data edits retain untouched YAML comments, quote/block styles, order and aliases without numeric rounding',()=>{
 const root='file:///project/root.yaml',source='# keep\r\nopenapi: 3.2.1\r\ninfo: {title: Data, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  examples:\r\n    Data:\r\n      value:\r\n        name: \'雪😀\' # keep name\r\n        number: 9007199254740993.00 # keep number\r\n        message: |-\r\n          original\r\n          text\r\n        same: &shared {n: 9007199254740993.00}\r\n        alias: *shared\r\n        list: [a, b, c]\r\nx-tail: null';
 const doc=new SourceDocument(source,root),pointer='/components/examples/Data/value',value=doc.dataJson(pointer);
 const input={snapshot:'exact',resources:[{id:root,text:source,generation:1}],target:{resource:root,pointer,generation:1}};
 const result=propose({...input,actions:[{kind:'setData',pointer,raw:value.replace('"number":9007199254740993.00','"number":9007199254740994.00')}]});
 let text=source;for(const edit of result.edits.reverse())text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
 assert.equal(text,source.replace('number: 9007199254740993.00','number: 9007199254740994.00'));
 assert.deepEqual(propose({...input,actions:[{kind:'setData',pointer,raw:value}]}).edits,[]);
 const changedAlias=value.replace('"alias":{"n":9007199254740993.00}','"alias":{"n":0}');
 assert.throws(()=>propose({...input,actions:[{kind:'setData',pointer,raw:changedAlias}]}),e=>e.code==='edit.shared');
 const structural=value.replace('"list":["a","b","c"]','"list":["a"]');
 const trimmed=propose({...input,actions:[{kind:'setData',pointer,raw:structural}]});
 let after=source;for(const edit of trimmed.edits.reverse())after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
 assert(after.includes('list: [a]'));assert(after.includes('same: &shared'));assert(after.includes('alias: *shared'));assert(after.endsWith('x-tail: null'));
});
