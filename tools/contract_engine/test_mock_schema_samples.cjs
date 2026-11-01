const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const {capturedMockStart,startMock}=require('./mock_test_capture.cjs');

const high='9007199254740993.00',low='9007199254740992.00';
const decimal='1.23000000000000000000000000000000001e-27';
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','2.0','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function encode(value,format){
 let text=format==='json'?JSON.stringify(value):YAML.stringify(value);
 for(const [marker,raw]of [['BIG',high],['LOW',low],['DECIMAL',decimal]])
  text=text.replaceAll('"'+marker+'"',raw).replaceAll(marker,raw);
 return text;
}
function send(port,path,headers={}){
 return new Promise((resolve,reject)=>{
  const request=http.get({host:'127.0.0.1',port,path,headers},response=>{
   const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);
   response.once('end',()=>resolve({status:response.statusCode,text:Buffer.concat(chunks).toString('utf8'),headers:response.headers}));
  });
  request.once('error',reject);
 });
}

for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} native generated candidates retain exact source values`,{timeout:45000},async t=>{
 const swagger=version==='2.0',modern=version.startsWith('3.1')||version.startsWith('3.2');
 const root='file:///native-samples/api.'+format,shared='file:///native-samples/model.'+format;
 const rich=JSON.parse('{"$ref":"literal","__proto__":{"zero":0},"number":"BIG","text":"café 東京","false":false,"empty":[]}');
 const nullSchema=swagger?{enum:[null],default:null}:modern?{type:['string','null'],default:null}:{type:'string',nullable:true,default:null};
 const samples=[
  ['default',{type:'integer',default:'BIG'},high],
  ['enum',{type:'integer',enum:['BIG']},high],
  ['filtered',{type:'integer',minimum:'BIG',enum:['LOW','BIG']},high],
  ['decimal',{type:'number',default:'DECIMAL'},decimal],
  ['false',{type:'boolean',default:false},'false'],
  ['zero',{type:'integer',default:0},'0'],
  ['empty',{type:'string',default:''},'""'],
  ['null',nullSchema,'null'],
  ['array',{type:'array',items:{type:'integer'},default:[]},'[]'],
  ['object',{type:'object',default:rich},encode(rich,'json')],
  ['untyped',{default:rich},encode(rich,'json')],
  ['object-enum',{type:'object',enum:[rich]},encode(rich,'json')],
  ['array-enum',{type:'array',items:{type:'integer'},enum:[['BIG']]},'['+high+']'],
  ['reference',{$ref:'./model.'+format+'#/Stored',minimum:'BIG'},modern?high:low],
  ['composition',{allOf:[{$ref:'./model.'+format+'#/Stored'}]},low],
  ['example',{type:'integer',example:'BIG'},high],
  ['nested-enum',{type:'object',required:['id'],properties:{id:{type:'integer',enum:['BIG']}},additionalProperties:false},'{"id":'+high+'}'],
  ['nested-array',{type:'array',minItems:2,maxItems:2,uniqueItems:true,items:{type:'integer',enum:['LOW','BIG']}},'['+low+','+high+']'],
  ['nested-reference',{type:'object',required:['id'],properties:{id:{$ref:'./model.'+format+'#/Stored',minimum:'BIG'}}},'{"id":'+(modern?high:low)+'}'],
  ['nested-composition',{type:'object',required:['id'],properties:{id:{allOf:[{type:'integer',enum:['LOW','BIG']},{minimum:'BIG'}]}}},'{"id":'+high+'}'],
  ['nested-default',{type:'object',required:['payload'],properties:{payload:{type:'object',default:rich}}},'{"payload":'+encode(rich,'json')+'}'],
  ['nested-falsy',{type:'object',required:['false','zero','empty','null'],properties:{false:{type:'boolean',enum:[false]},zero:{type:'integer',enum:[0]},empty:{type:'string',enum:['']},null:{...nullSchema,enum:[null]}}},'{"false":false,"zero":0,"empty":"","null":null}'],
  ['nested-objects',{allOf:[{type:'object',required:['id'],properties:{id:{type:'integer',enum:['BIG']}}},{type:'object',required:['label'],properties:{label:{type:'string',enum:['café 東京']}}}]},'{"id":'+high+',"label":"café 東京"}'],
  ...(modern?[['const',{type:'integer',const:'BIG'},high]]:[]),
 ];
 const responseFor=schema=>({description:'Generated',...(swagger?{schema}:{content:{'application/json':{schema}}})});
 const paths=Object.fromEntries(samples.map(([name,schema])=>['/'+name,{get:{responses:{200:responseFor(schema)}}}]));
 const preferred={description:'Authored example',...(swagger?{schema:{type:'integer',default:'BIG'},examples:{'application/json':'LOW'}}:
  {content:{'application/json':{schema:{type:'integer',default:'BIG'},example:'LOW'}}})};
 paths['/preferred']={get:{responses:{200:preferred}}};
 const boundedSchema={type:'integer',minimum:256,enum:Array.from({length:257},(_,i)=>i)};
 paths['/bounded']={get:{responses:{200:responseFor(boundedSchema)}}};
 paths['/prefix']={get:{responses:{200:responseFor({type:'integer',enum:Array.from({length:257},(_,i)=>i)})}}};
 const nested=schema=>({type:'object',required:['id'],properties:{id:schema},additionalProperties:false});
 paths['/nested-bounded']={get:{responses:{200:responseFor(nested(boundedSchema))}}};
 paths['/nested-prefix']={get:{responses:{200:responseFor(nested({type:'integer',enum:Array.from({length:257},(_,i)=>i)}))}}};
 const names=Array.from({length:32},(_,index)=>'field'+index);
 const wide={type:'object',required:names,properties:Object.fromEntries(names.map(name=>[name,{type:'integer',enum:['BIG']}])),additionalProperties:false};
 paths['/nested-wide']={get:{responses:{200:responseFor(wide)}}};
 paths['/alternative']={get:{responses:{200:responseFor({type:'integer',default:'BIG'}),418:responseFor(boundedSchema)}}};
 const document={[swagger?'swagger':'openapi']:version,info:{title:'Native schema samples',version:'1'},...(swagger?{produces:['application/json']}:{}),paths};
 const text=encode(document,format),model=encode({Stored:{type:'integer',enum:['LOW','BIG']}},format);
 const capture={root,snapshot:'0'.repeat(64),resources:[{id:root,text},{id:shared,text:model}].map(resource=>({
  ...resource,generation:1,identity:createHash('sha256').update(resource.text).digest('hex'),
 }))};
 const input=capturedMockStart(capture),before=JSON.stringify(input);
 const event=await startMock(t,input),{port}=event;
 assert.equal(event.nativeGeneration.name,'busyapi-native-schema-samples');
 assert.equal(event.nativeGeneration.version,'3');
 for(const [name,,expected]of [...samples,['preferred',{},low],['prefix',{},'0'],['alternative',{},high],
  ['nested-prefix',{},'{"id":0}'],['nested-wide',{},encode(Object.fromEntries(names.map(name=>[name,'BIG'])),'json')]]){
  const response=await send(port,'/'+name);
  assert.equal(response.status,200,name+': '+response.text);assert.equal(response.text,expected,name);
  assert.equal(response.headers['busyapi-response-validation-complete'],'true',name);
  assert.deepEqual(JSON.parse(response.headers['sl-violations']??'[]'),[],name);
  assert.equal(Number(response.headers['content-length']),Buffer.byteLength(expected),name);
 }
 for(const [path,expected]of [['filtered',high],['object-enum',encode(rich,'json')],['array-enum','['+high+']'],['example',high]]){
  const response=await send(port,'/'+path,{prefer:path==='example'?'dynamic=true,example=default':'dynamic=true'});
  assert.equal(response.status,200,path+': '+response.text);assert.equal(response.text,expected,path);
  assert.equal(response.headers['busyapi-response-validation-complete'],'true');
  assert.deepEqual(JSON.parse(response.headers['sl-violations']??'[]'),[]);
 }
 for(const name of ['nested-enum','nested-array','nested-reference','nested-composition','nested-falsy']){
  const expected=samples.find(sample=>sample[0]===name)[2];
  const allowed=name==='nested-array'?['['+low+','+high+']','['+high+','+low+']']
   :name==='nested-reference'&&!modern?['{"id":'+low+'}','{"id":'+high+'}']:[expected];
  const response=await send(port,'/'+name,{prefer:'dynamic=true'});
  assert.equal(response.status,200,name+': '+response.text);assert.ok(allowed.includes(response.text),name+': '+response.text);
  assert.equal(response.headers['busyapi-response-validation-complete'],'true');
  assert.deepEqual(JSON.parse(response.headers['sl-violations']??'[]'),[],name);
 }
 const limited=await send(port,'/bounded');
 assert.equal(limited.status,501);assert.equal(limited.headers['busyapi-response-validation-complete'],'false');
 const failure=JSON.parse(limited.text);assert.equal(failure.complete,false);
 assert.equal(failure.findings[0].code,'mock.sample.limit');
 assert.equal(failure.findings[0].source.resource,root);
 assert.ok(failure.findings[0].source.pointer.endsWith('/enum/256'));
 const nestedLimited=await send(port,'/nested-bounded');
 assert.equal(nestedLimited.status,501);assert.equal(nestedLimited.headers['busyapi-response-validation-complete'],'false');
 const nestedFailure=JSON.parse(nestedLimited.text);assert.equal(nestedFailure.complete,false);
 assert.equal(nestedFailure.findings[0].code,'mock.sample.limit');
 assert.equal(nestedFailure.findings[0].source.resource,root);
 assert.ok(nestedFailure.findings[0].source.pointer.endsWith('/enum/256'));
 const alternative=await send(port,'/alternative',{prefer:'code=418'});
 assert.equal(alternative.status,501);assert.equal(JSON.parse(alternative.text).complete,false);
 assert.equal(JSON.stringify(input),before,'Captured originals were altered');
});
