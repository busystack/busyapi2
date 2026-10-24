const assert = require('node:assert/strict');
const {test} = require('node:test');
const {suggestSchema,planSchemaSuggestion} = require('./dist/schema_suggestion.cjs');
const YAML = require('yaml');
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`reviewed example inference ${version} ${json?'JSON':'YAML'} preserves source data`,()=>{
 const root='file:///project/root.'+(json?'json':'yaml'), pointer='/paths/~1items/post/requestBody/content/application~1json';
 const sample={kind:'literal',a:1,decimal:1.5,nil:null,list:[true,'x',null],empty:[],optional:{$ref:'payload data'}};
 const data={openapi:version,info:{title:'T',version:'1'},paths:{'/items':{post:{requestBody:{content:{'application/json':{example:sample}}}}}}};
 const text=(json?JSON.stringify(data):'# kept\r\n'+YAML.stringify(data).replaceAll('\n','\r\n')).replace(json?'"a":1':'a: 1',json?'"a":9007199254740993':'a: 9007199254740993');
 const input={root,snapshot:'captured',resources:[{id:root,generation:3,identity:'source',text}],resource:root,pointer:pointer+'/example',target:{resource:root,generation:3,pointer}};
 const result=suggestSchema(input);
 assert.equal(result.schema.type,'object');assert.equal(result.schema.properties.a.type,'integer');
 assert.equal(result.schema.properties.decimal.type,'number');assert.equal(result.schema.properties.nil.type,'null');
 assert.deepEqual(result.schema.properties.empty,{type:'array'});
 assert.equal(result.schema.properties.optional.properties.$ref.type,'string');
 assert(!JSON.stringify(result.schema).includes('required'));assert(!JSON.stringify(result.schema).includes('enum'));
 const plan=planSchemaSuggestion(input);let after=text;for(const edit of plan.edits)after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
 assert(after.includes('9007199254740993'));assert(after.includes('payload data'));
 if(!json){assert(after.startsWith('# kept\r\n'));assert(!/(?<!\r)\n/.test(after));}
 assert.deepEqual(json?JSON.parse(after).paths['/items'].post.requestBody.content['application/json'].example:YAML.parse(after).paths['/items'].post.requestBody.content['application/json'].example,json?JSON.parse(text).paths['/items'].post.requestBody.content['application/json'].example:YAML.parse(text).paths['/items'].post.requestBody.content['application/json'].example);
 const changed={...input,resources:[{...input.resources[0],text:after}]};
 assert.throws(()=>planSchemaSuggestion(changed),e=>e.code==='suggest.collision');
 const nullable=planSchemaSuggestion({...input,nullable:true});assert.deepEqual(nullable.schema.anyOf[1],{type:'null'});
});
test('inference refuses serialized and external data; mathematical integers never use a rounded number',()=>{
 const root='file:///project/root.json';
 const data={openapi:'3.2.1',info:{title:'T',version:'1'},paths:{},components:{examples:{E:{value:null},S:{serializedValue:'123'},X:{externalValue:'https://never-fetch.invalid'}}}};
 const input={root,snapshot:'s',resource:root,resources:[{id:root,generation:1,identity:'a',text:JSON.stringify(data)}]};
 for(const pointer of ['/components/examples/S/serializedValue','/components/examples/X/externalValue','/info/title'])assert.throws(()=>suggestSchema({...input,pointer}),e=>e.code==='suggest.context');
 for(const [raw,type] of [['1.0','integer'],['1e3000','integer'],['1e-3000','number'],['-0.00','integer'],['9007199254740993.1','number']]){
  const resource={...input.resources[0],text:input.resources[0].text.replace('"value":null','"value":'+raw)};
  assert.equal(suggestSchema({...input,resources:[resource],pointer:'/components/examples/E/value'}).schema.type,type);
 }
});
