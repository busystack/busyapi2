const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const variants=[
 ['query integer',{name:'id',in:'query',schema:{type:'integer',enum:['EXACT']}},'id=9007199254740993','id=9007199254740992'],
 ['query false',{name:'flag',in:'query',schema:{type:'boolean',const:false}},'flag=false','flag=true'],
 ['query empty',{name:'text',in:'query',schema:{type:'string',maxLength:0}},'text=','text=x'],
 ['query array',{name:'ids',in:'query',schema:{type:'array',items:{type:'integer'},minItems:2,maxItems:2}},'ids=0&ids=2','ids=0'],
 ['query object',{name:'point',in:'query',style:'deepObject',schema:{type:'object',properties:{x:{const:0},y:{const:false}},required:['x','y']}},'point[x]=0&point[y]=false','point[x]=0&point[y]=true'],
 ['path label',{name:'id',in:'path',required:true,style:'label',schema:{type:'integer',enum:['EXACT']}},'.9007199254740993','.9007199254740992'],
 ['path Unicode',{name:'id',in:'path',required:true,schema:{type:'string',const:'雪'}},'%E9%9B%AA','%E9%9B%A9'],
 ['cookie form',{name:'flag',in:'cookie',schema:{type:'boolean',const:false}},'flag=false','flag=true'],
 ['cookie native',{name:'flag',in:'cookie',style:'cookie',schema:{type:'boolean',const:false}},'flag=false','flag=true'],
 ['header parameter',{name:'X-Id',in:'header',schema:{type:'integer',enum:['EXACT']}},'9007199254740993','9007199254740992'],
 ['header response',{schema:{type:'integer',enum:['EXACT']}},'9007199254740993','9007199254740992'],
 ['header content',{content:{'application/json':{schema:{type:'object',properties:{id:{type:'integer',enum:['EXACT']}},required:['id']}}}},'{"id":9007199254740993}','{"id":9007199254740992}'],
 ['parameter content',{name:'data',in:'query',content:{'application/json':{schema:{type:'object',properties:{flag:{const:false}},required:['flag']}}}},'data=%7B%22flag%22%3Afalse%7D','data=%7B%22flag%22%3Atrue%7D'],
];
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const [label,declaration,good,bad]of variants)test(`${version} ${format} native serialized ${label}`,async()=>{
 const id='file:///p/api.'+format,owner=structuredClone(declaration),header=!Object.hasOwn(owner,'in');
 owner.examples={Good:{serializedValue:good},Bad:{serializedValue:bad}};
 const operation={responses:{200:{description:'Read',...(header?{headers:{'X-Result':owner}}:{})}},...(!header?{parameters:[owner]}:{})};
 const value={openapi:version,info:{title:'Keep 雪',version:'api-version'},paths:{[owner.in==='path'?'/items/{id}':'/items']:{get:operation}},'x-exact':'EXACT'};
 const text=(format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll('"EXACT"','9007199254740993').replaceAll('EXACT','9007199254740993');
 const input={root:id,snapshot:'serialized-parameter',resources:[{id,text,generation:3}]};
 const result=await evaluateSchemas(input);
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.equal(result.serializedEvaluations.length,2,JSON.stringify(result));
 const checks=result.serializedEvaluations;
 assert.equal(checks.find(v=>v.pointer.includes('/Good/')).valid,true,JSON.stringify(result));
 assert.equal(checks.find(v=>v.pointer.includes('/Bad/')).valid,false,JSON.stringify(result));
 const findings=result.findings.filter(v=>v.code==='example.serialization.incompatible');
 assert.equal(findings.length,1,JSON.stringify(result.findings));assert(findings[0].pointer.includes('/Bad/serializedValue'));
 assert.equal(input.resources[0].text,text);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json']){
 const render=value=>(format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll('"EXACT"','9007199254740993').replaceAll('EXACT','9007199254740993');
 const root='file:///p/api.'+format;
 const api=()=>({openapi:version,info:{title:'Keep',version:'api'},paths:{'/items':{get:{responses:{200:{description:'Read'}}}}}});
 const checked=async(value,extra=[])=>evaluateSchemas({root,snapshot:'wire-contexts',resources:[{id:root,text:render(value),generation:1},...extra]});
 test(`${version} ${format} shared Header and Example chains keep their physical owners`,async()=>{
  const value=api(),shared='file:///p/examples.'+format;
  value.components={headers:{Shared:{schema:{type:'integer',enum:['EXACT']},examples:{Value:{$ref:shared+'#/Chain'}}}}};
  value.paths['/items'].get.responses[200].headers={'X-First':{$ref:'#/components/headers/Shared'},'X-Second':{$ref:'#/components/headers/Shared'}};
  const extra={id:shared,text:render({Chain:{$ref:'#/Actual'},Actual:{serializedValue:'9007199254740993'}}),generation:2};
  const result=await checked(value,[extra]);assert.equal(result.complete,true,JSON.stringify(result.findings));
  assert.equal(result.serializedEvaluations.length,2);assert(result.serializedEvaluations.every(v=>v.resource===shared&&v.pointer==='/Actual/serializedValue'&&v.valid));
  assert.equal(new Set(result.serializedEvaluations.map(v=>v.header.pointer)).size,2);
 });
 test(`${version} ${format} Header inside a referenced root Response keeps its field context`,async()=>{
  const value=api(),response='file:///p/response.'+format;
  value.paths['/items'].get.responses[200]={$ref:response};
  const result=await checked(value,[{id:response,generation:1,text:render({description:'Read',headers:{'X-Id':{schema:{type:'integer',enum:['EXACT']},examples:{Value:{serializedValue:'9007199254740993'}}}}})}]);
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,1);
  assert.equal(result.serializedEvaluations[0].header.pointer,'/headers/X-Id');assert.equal(result.serializedEvaluations[0].valid,true);
 });
 test(`${version} ${format} Set-Cookie example field lines retain commas`,async()=>{
  const value=api();
  value.paths['/items'].get.responses[200].headers={'Set-Cookie':{style:'simple',explode:true,schema:{type:'object',required:['lang','foo'],properties:{lang:{type:'string',const:'en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT'},foo:{type:'string',const:'bar'}}},examples:{Value:{serializedValue:'lang=en-US; Expires=Wed, 09 Jun 2021 10:18:14 GMT\nfoo=bar\n'}}}};
  const result=await checked(value);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,1);assert.equal(result.serializedEvaluations[0].valid,true,JSON.stringify(result.findings));
 });
 for(const [label,owner,text]of [
  ['malformed percent',{name:'id',in:'query',schema:{type:'integer'}},'id=%E9'],
  ['malformed header integer',{schema:{type:'integer'}},'neither-number-nor-string'],
  ['header control',{schema:{type:'string'}},'one\r\nInjected: value'],
 ])test(`${version} ${format} ${label} is evaluated as incompatible`,async()=>{
  const value=api(),declaration={...owner,examples:{Value:{serializedValue:text}}};
  if(Object.hasOwn(owner,'in'))value.paths['/items'].get.parameters=[declaration];else value.paths['/items'].get.responses[200].headers={'X-Value':declaration};
  const result=await checked(value);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,1);assert.equal(result.serializedEvaluations[0].valid,false);
  assert.equal(result.findings.filter(v=>v.code==='example.serialization.incompatible').length,1);
 });
 test(`${version} ${format} unsupported Header dialect cannot be successful`,async()=>{
  const value=api();value.paths['/items'].get.responses[200].headers={'X-Id':{schema:{$schema:'https://example.invalid/unsupported',type:'integer'},examples:{Value:{serializedValue:'0'}}}};
  const result=await checked(value);assert.equal(result.complete,false);assert(result.findings.some(v=>v.code==='example.serialization.incomplete'));
 });
 test(`${version} ${format} a free Header definition does not invent a wire field name`,async()=>{
  const value=api();value.components={headers:{Reusable:{schema:{type:'integer'},examples:{Value:{serializedValue:'0'}}}}};
  const result=await checked(value);assert.equal(result.complete,false);assert(result.findings.some(v=>v.code==='example.serialization.incomplete'));
 });
 for(const [media,text,schema]of [
  ['application/json','%7B%22flag%22%3Afalse%7D',{type:'object',properties:{flag:{const:false}},required:['flag']}],
  ['application/x-www-form-urlencoded','flag=false&n=9007199254740993',{type:'object',properties:{flag:{type:'boolean',const:false},n:{type:'integer',enum:['EXACT']}},required:['flag','n']}],
 ])test(`${version} ${format} querystring serialization ${media}`,async()=>{
  const value=api();value.paths['/items'].get.parameters=[{name:'whole',in:'querystring',content:{[media]:{schema}},examples:{Value:{serializedValue:text}}}];
  const result=await checked(value);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,1);assert.equal(result.serializedEvaluations[0].valid,true,JSON.stringify(result.findings));
 });
}
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const schema of [{},true,{type:['string','object']}])test(`${version} ${format} unconstrained or alternative Header representation ${JSON.stringify(schema)}`,async()=>{
 const root='file:///p/header.'+format,value={openapi:version,info:{title:'Keep',version:'1'},paths:{'/items':{get:{responses:{200:{description:'Read',headers:{'X-Text':{schema,examples:{Value:{serializedValue:'plain'}}}}}}}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value);
 const result=await evaluateSchemas({root,snapshot:'unconstrained-header',resources:[{id:root,text,generation:1}]});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,1);assert.equal(result.serializedEvaluations[0].valid,true,JSON.stringify(result.findings));
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} MIME Encoding Header uses its actual field occurrence`,async()=>{
 const root='file:///p/mime.'+format;
 const header={schema:{type:'integer',enum:['EXACT']},examples:{Value:{serializedValue:'9007199254740993'}}};
 const media={schema:{type:'object',properties:{text:{type:'string'}}},encoding:{text:{headers:{'X-Id':header}}}};
 const operation={requestBody:{content:{'multipart/form-data':media}},responses:{204:{description:'None'}}};
 const value={openapi:version,info:{title:'Keep',version:'1'},paths:{'/items':{post:operation}}};
 const text=(format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll('"EXACT"','9007199254740993').replaceAll('EXACT','9007199254740993');
 const result=await evaluateSchemas({root,snapshot:'mime-header',resources:[{id:root,text,generation:1}]});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,1);assert.equal(result.serializedEvaluations[0].valid,true,JSON.stringify(result.findings));
});
