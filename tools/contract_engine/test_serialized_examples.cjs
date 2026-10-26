const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const versions=['3.2.0','3.2.1'];
const schema={type:'object',required:['id'],properties:{id:{type:'integer',enum:['EXACT']}},additionalProperties:false};
const wire=number=>'\u007b"id":'+number+'}';
function render(value,format){return (format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');}
function api(version,media){return {openapi:version,info:{title:'Keep 雪',version:'api-version'},paths:{'/parts':{post:{requestBody:{content:media},responses:{204:{description:'Empty'}}}}}};}
async function check(version,format,media,more={}){
 const root='file:///approved/api.'+format,document=api(version,media);Object.assign(document,more);
 const text=render(document,format),input={root,snapshot:version+format,resources:[{id:root,text,generation:1}]};
 const result=await evaluateSchemas(input);assert.equal(input.resources[0].text,text);return result;
}
for(const version of versions)for(const format of ['yaml','json'])for(const kind of ['exact','rounded','malformed','paired','unsupported'])test(`${version} ${format} serialized media example ${kind}`,async()=>{
 const text=kind==='malformed'?'{"id":':wire(kind==='exact'?'9007199254740993.00':'9007199254740992');
 const mediaType=kind==='unsupported'?'application/xml':'application/json';
 const result=await check(version,format,{[mediaType]:{schema,examples:{Case:{serializedValue:text,...(kind==='paired'?{dataValue:{id:'EXACT'}}:{})}}}});
 assert.equal(result.complete,kind!=='unsupported',JSON.stringify(result.findings));
 assert.equal(result.serializedEvaluations.length,1);const value=result.serializedEvaluations[0];
 assert.equal(value.complete,kind!=='unsupported');assert.equal(value.valid,kind==='exact');
 assert.equal(value.mediaType,mediaType);assert.equal(value.pointer,'/paths/~1parts/post/requestBody/content/'+mediaType.replaceAll('/','~1')+'/examples/Case/serializedValue');
 assert(!result.skipped.some(value=>value.reason==='serialized-value-not-parsed'));
 assert.deepEqual(result.evaluations.map(value=>value.valid),kind==='paired'?[true]:[]);
 assert.equal(result.findings.filter(value=>value.code==='example.serialization.incompatible').length,['rounded','malformed','paired'].includes(kind)?1:0);
 assert.equal(result.findings.filter(value=>value.code==='example.serialization.incomplete').length,kind==='unsupported'?1:0);
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} serialized false zero empty and null retain their kinds`,async()=>{
 const examples={},properties={};
 for(const [name,value]of [['flag',false],['number',0],['empty',''],['none',null]]){properties[name]={const:value};examples[name]={serializedValue:JSON.stringify(value)};}
 const result=await check(version,format,Object.fromEntries(Object.keys(examples).map(name=>['application/'+name+'+json',{schema:properties[name],examples:{Check:examples[name]}}])));
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,4);assert(result.serializedEvaluations.every(value=>value.complete&&value.valid));
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} sequential and form examples use their original media owner`,async()=>{
 const content={
  'application/x-www-form-urlencoded':{schema,examples:{Check:{serializedValue:'id=9007199254740993.00'}}},
  'application/jsonl':{schema:{type:'array',items:schema},itemSchema:schema,examples:{Check:{serializedValue:wire('9007199254740993')+'\n'+wire('9007199254740993.00')+'\n'}}},
  'text/plain':{schema:{type:'string',const:'雪'},examples:{Check:{serializedValue:'雪'}}},
 };
 const result=await check(version,format,content);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,3);assert(result.serializedEvaluations.every(value=>value.valid),JSON.stringify(result));
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} a reusable media definition keeps each actual content key`,async()=>{
 const result=await check(version,format,{'application/json':{$ref:'#/components/mediaTypes/Shared'},'application/vendor+json':{$ref:'#/components/mediaTypes/Shared'}},{components:{mediaTypes:{Shared:{schema,examples:{Check:{serializedValue:wire('9007199254740993')}}}}}});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,2);assert(result.serializedEvaluations.every(value=>value.valid));
 assert.deepEqual(result.serializedEvaluations.map(value=>value.mediaType).sort(),['application/json','application/vendor+json']);
 assert(result.serializedEvaluations.every(value=>value.pointer==='/components/mediaTypes/Shared/examples/Check/serializedValue'));
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} external Example references retain physical source and literal payload references`,async()=>{
 const root='file:///approved/api.'+format,shared='file:///approved/examples.'+format;
 const content={'application/json':{schema:{type:'object',required:['$ref','id'],properties:{$ref:{const:'literal'},id:schema.properties.id},additionalProperties:false},examples:{Check:{$ref:'./examples.'+format+'#/Chain'}}}};
 const external={Chain:{$ref:'#/Actual'},Actual:{serializedValue:'{"$ref":"literal","id":9007199254740993.00}'}};
 const resources=[{id:root,text:render(api(version,content),format),generation:1},{id:shared,text:render(external,format),generation:2}],before=resources.map(value=>value.text);
 const result=await evaluateSchemas({root,snapshot:'external',resources});assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.serializedEvaluations.map(value=>[value.resource,value.pointer,value.valid]),[[shared,'/Actual/serializedValue',true]]);assert.deepEqual(resources.map(value=>value.text),before);
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} modern readOnly annotations do not suppress required assertions`,async()=>{
 const media={schema:{type:'object',required:['id'],properties:{id:{type:'integer',readOnly:true}}},examples:{Missing:{serializedValue:'{}'},Present:{serializedValue:'{"id":1}'}}};
 const document=api(version,{'application/json':media});document.paths['/parts'].post.responses[200]={description:'Read',content:{'application/json':media}};
 const result=await check(version,format,{},document);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.serializedEvaluations.map(value=>value.valid),[false,true,false,true]);
});
for(const version of versions)test(`${version} YAML alias serialization diagnostics use physical provenance`,async()=>{
 const root='file:///approved/api.yaml',text=`openapi: ${version}\ninfo: {title: Keep, version: unchanged}\nx-example: &example\n  serializedValue: '{"id":9007199254740992}'\npaths:\n  /parts:\n    post:\n      requestBody:\n        content:\n          application/json:\n            schema: {type: integer}\n            examples: {Check: *example}\n      responses: {'204': {description: Empty}}\n`;
 const result=await evaluateSchemas({root,snapshot:version,resources:[{id:root,text,generation:1}]});assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations[0].pointer,'/x-example/serializedValue');
 const finding=result.findings.find(value=>value.code==='example.serialization.incompatible');assert.equal(finding.pointer,'/x-example/serializedValue');assert.equal(finding.range[0],text.indexOf("'{\"id\""));
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} opaque binary serialization cannot claim a Unicode proof`,async()=>{
 const result=await check(version,format,{'application/octet-stream':{schema:{},examples:{Check:{serializedValue:'ASCII still has no declared character representation'}}}});
 assert.equal(result.complete,false);assert.equal(result.serializedEvaluations.length,1);assert.equal(result.serializedEvaluations[0].complete,false);assert.equal(result.serializedEvaluations[0].valid,false);
 assert(result.findings.some(value=>value.code==='example.serialization.incomplete'&&value.details.some(note=>note.detailCode==='runtime.media.unicode.unsupported')));
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} multipart examples retain whole-array and independent item checks`,async()=>{
 const exact='--Fixture\r\nContent-Type: application/json\r\n\r\n'+wire('9007199254740993.00')+'\r\n--Fixture--\r\n';
 const result=await check(version,format,{'multipart/mixed; boundary=Fixture':{schema:{type:'array',minItems:1},itemSchema:schema,itemEncoding:{contentType:'application/json'},examples:{Exact:{serializedValue:exact},Rounded:{serializedValue:exact.replace('9007199254740993.00','9007199254740992')}}}});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.serializedEvaluations.map(value=>value.valid),[true,false]);
});
for(const from of ['3.1.2','3.2.1'])for(const to of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${from} to ${to} ${format} Example and media families retain independent ownership`,async()=>{
 const root='file:///approved/api.'+format,shared='file:///approved/examples.'+format;
 const resources=[{id:root,text:render(api(from,{'application/json':{schema,examples:{Check:{$ref:'./examples.'+format+'#/components/examples/Value'}}}}),format),generation:1},{id:shared,text:render({openapi:to,info:{title:'Shared',version:'1'},paths:{},components:{examples:{Value:{serializedValue:wire('9007199254740993.00')}}}},format),generation:2}];
 const result=await evaluateSchemas({root,snapshot:from+to+format,resources});
 assert.equal(result.complete,to==='3.2.1',JSON.stringify(result.findings));
 if(to==='3.2.1'){
  assert.equal(result.serializedEvaluations.length,1);assert.equal(result.serializedEvaluations[0].valid,true);assert.equal(result.serializedEvaluations[0].resource,shared);
  assert(!result.skipped.some(value=>value.reason==='serialized-value-not-parsed'));
 }else assert(result.findings.some(value=>value.code==='example.serialization.incomplete'&&value.detailCode==='example.serialization.family'));
});
for(const version of ['2.0','3.0.4','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} an explicit false serialization flag preserves ordinary JSON input`,async()=>{
 const root='file:///approved/flags.'+format,legacy=version==='2.0',pointer=legacy?'/definitions/Flag':'/components/schemas/Flag';
 const document={...(legacy?{swagger:version}:{openapi:version}),info:{title:'Keep flags',version:'unchanged'},paths:{},...(legacy?{definitions:{Flag:{type:'boolean',enum:[false]}}}:{components:{schemas:{Flag:{type:'boolean',enum:[false]}}}})};
 const input={root,snapshot:version+format,resources:[{id:root,text:render(document,format),generation:1}]};
 const value={subject:'request-body',location:'flag',text:'false',schema:{resource:root,pointer}};
 await assert.rejects(evaluateSchemas({...input,runtimeInstances:[{...value,unicodeSerialization:true}]}),error=>error.code==='runtime.instance');
 const result=await evaluateSchemas({...input,runtimeInstances:[{...value,unicodeSerialization:false}]});assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.runtimeEvaluations.map(value=>value.valid),[true]);
});
