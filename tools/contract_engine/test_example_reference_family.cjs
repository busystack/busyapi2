const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {requestOperation}=require('./dist/execution.cjs');
for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const exampleVersion of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const field of ['dataValue','serializedValue'])
test(`${version} ${format} request examples retain referenced ${exampleVersion} ${field}`,()=>{
 const root='file:///p/api.'+format,examples='file:///p/examples.'+format;
 const source={openapi:version,info:{title:'Keep',version:'1'},paths:{'/items/{id}':{get:{parameters:[{name:'id',in:'path',required:true,style:'label',schema:{type:'array',items:{type:'integer'}},examples:{Observed:{$ref:'./examples.'+format+'#/components/examples/Observed'}}}],responses:{204:{description:'None'}}}}}};
 const definition={openapi:exampleVersion,info:{title:'Examples',version:'1'},paths:{},components:{examples:{Observed:{[field]:field==='dataValue'?['EXACT',0]:'.9007199254740993.0'}}}};
 const render=value=>(format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll('"EXACT"','9007199254740993').replaceAll('EXACT','9007199254740993');
 const resources=[{id:root,text:render(source),generation:1},{id:examples,text:render(definition),generation:2}],before=resources.map(r=>r.text);
 const result=requestOperation({root,snapshot:'cross-family-example',resource:root,pointer:'/paths/~1items~1{id}/get',resources});
 const example=result.parameters[0].example;assert(example,'The referenced example must remain available to native Use example');
 assert.equal(example.representation,field==='dataValue'?'json':'serialized');
 assert.equal(example.raw,field==='dataValue'?'[9007199254740993,0]':'.9007199254740993.0');
 assert.equal(example.source.resource,examples);assert.equal(example.source.pointer,'/components/examples/Observed/'+field);assert.deepEqual(resources.map(r=>r.text),before);
});
