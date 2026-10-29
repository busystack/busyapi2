const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const {evaluateSchemas,schemaProducer}=require('./dist/schema_evaluation.cjs');
const http=require('node:http');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

const versions=['3.2.0','3.2.1'];
const variants=[
 ['query array',{name:'ids',in:'query',style:'form',explode:true,schema:{type:'array',items:{type:'integer'},maxItems:0}},[]],
 ['query object',{name:'values',in:'query',style:'form',explode:true,schema:{type:'object',additionalProperties:{type:'integer'},maxProperties:0}},{}],
 ['query deep object',{name:'values',in:'query',style:'deepObject',explode:true,schema:{type:'object',maxProperties:0}},{}],
 ['form cookie array',{name:'ids',in:'cookie',style:'form',explode:true,schema:{type:'array',items:{type:'integer'},maxItems:0}},[]],
 ['form cookie object',{name:'values',in:'cookie',style:'form',explode:true,schema:{type:'object',maxProperties:0}},{}],
 ['native cookie array',{name:'ids',in:'cookie',style:'cookie',explode:true,schema:{type:'array',items:{type:'integer'},maxItems:0}},[]],
 ['native cookie object',{name:'values',in:'cookie',style:'cookie',explode:true,schema:{type:'object',maxProperties:0}},{}],
];
function fixture(version,format,declaration,example,placement='inline'){
 const root='file:///controlled/parameter.'+format,owner=structuredClone(declaration);
 const value={openapi:version,info:{title:'Keep 雪😀',version:'business-version'},paths:{'/items':{get:{parameters:[owner],responses:{204:{description:'No content'}}}}},'x-literal':{serializedValue:'',value:'EXACT'}};
 if(placement==='reference'){
  value.components={examples:{Chain:{$ref:'examples.'+format+'#/Empty~1~0'}}};
  owner.examples={Empty:{$ref:'#/components/examples/Chain'}};
 }else owner.examples={Empty:example};
 let text=(format==='yaml'?'# Keep outside the example\r\n'+YAML.stringify(value,{aliasDuplicateObjects:false}).replaceAll('\n','\r\n'):JSON.stringify(value)).replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
 if(placement==='alias'){
  assert.equal(format,'yaml');
  text=text.replace('Empty:\r\n','Empty: &empty\r\n')+'x-shared-example: *empty\r\n';
 }
 return {root,snapshot:'optional-'+version+'-'+placement,resources:[{id:root,text,generation:7},...(placement==='reference'?[{id:'file:///controlled/examples.'+format,text:format==='yaml'?YAML.stringify({'Empty/~':example}):JSON.stringify({'Empty/~':example}),generation:3}]:[])]};
}
async function checked(input){
 const before=input.resources.map(value=>value.text),result=await evaluateSchemas(input);
 assert.deepEqual(input.resources.map(value=>value.text),before,'Read-only validation changed source');
 return result;
}
function exampleResult(result){assert.equal(result.serializedEvaluations.length,1,JSON.stringify(result));return result.serializedEvaluations[0];}
for(const version of versions)for(const format of ['yaml','json'])for(const [label,owner,data]of variants)for(const placement of format==='yaml'?['inline','reference','alias']:['inline','reference']){
 test(`${version} ${format} ${placement} ${label} proves its omitted empty collection`,async()=>{
  const input=fixture(version,format,owner,{dataValue:data,serializedValue:''},placement);
  assert.equal(analyse(input).status,'complete',JSON.stringify(analyse(input).findings));
  const result=await checked(input),evaluation=exampleResult(result);
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(evaluation.complete,true);assert.equal(evaluation.valid,true);assert.equal(evaluation.omission,'empty-collection');
  assert.equal(evaluation.resource,placement==='reference'?input.resources[1].id:input.root);assert(evaluation.pointer.endsWith('/serializedValue'));
  if(placement==='reference')assert.equal(evaluation.pointer,'/Empty~1~0/serializedValue');
  assert(!result.findings.some(value=>value.code==='example.serialization.incomplete'||value.code==='example.serialization.incompatible'),JSON.stringify(result.findings));
 });
}
for(const version of versions)for(const format of ['yaml','json']){
 for(const [label,schema]of [
  ['boolean true',true],['type union',{type:['array','object'],maxItems:0,maxProperties:0}],
  ['enum',{enum:[[]]}],['composition',{allOf:[{type:'array',items:{type:'integer'}},{maxItems:0}]}],
  ['exact unrelated bound',{type:'array',items:{type:'number',minimum:'EXACT'},maxItems:0}],
 ])test(`${version} ${format} ${label} omission uses original schema assertions`,async()=>{
  const input=fixture(version,format,{name:'ids',in:'query',schema},{serializedValue:''});
  const result=await checked(input);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(exampleResult(result).omission,'empty-collection');
 });
 for(const [label,schema]of [
  ['boolean false',false],['nonempty array',{type:'array',items:{type:'integer'},minItems:1}],
  ['nonempty object',{type:'object',minProperties:1}],['not empty',{not:{enum:[[],{}]}}],
  ['unsupported dialect',{$schema:'https://example.invalid/unsupported',type:'array',items:{type:'integer'}}],
  ['scalar string',{type:'string',maxLength:0}],['scalar false',{type:'boolean',const:false}],['scalar zero',{type:'integer',const:0}],
 ])test(`${version} ${format} ${label} is not successful merely because the parameter is optional`,async()=>{
  const input=fixture(version,format,{name:'ids',in:'query',schema},{serializedValue:''});
  const result=await checked(input),evaluation=exampleResult(result);
  assert.equal(result.complete,false);assert.equal(evaluation.complete,false);assert.equal(evaluation.valid,false);assert.equal(evaluation.omission,undefined);
  const finding=result.findings.find(value=>value.code==='example.serialization.incomplete');assert(finding,JSON.stringify(result.findings));assert.equal(finding.pointer,evaluation.pointer);assert(finding.range[1]>finding.range[0]);
 });
 for(const required of [true,false])test(`${version} ${format} required=${required} retains actual parameter presence`,async()=>{
  const input=fixture(version,format,{name:'ids',in:'query',required,schema:{type:'array',items:{type:'integer'},maxItems:0}},{serializedValue:required?'':'other=0'});
  const result=await checked(input),evaluation=exampleResult(result);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(evaluation.complete,true);assert.equal(evaluation.valid,false);assert.equal(evaluation.omission,undefined);
  assert(result.findings.some(value=>value.code==='example.serialization.incompatible'));
 });
 for(const [label,schema,text]of [
  ['empty string',{type:'string',maxLength:0},'id='],['false',{type:'boolean',const:false},'id=false'],
  ['zero',{type:'integer',const:0},'id=0'],['literal null',{type:'null'},'id=null'],
  ['exact integer',{type:'integer',enum:['EXACT']},'id=9007199254740993'],['Unicode',{type:'string',const:'雪'},'id=%E9%9B%AA'],
 ])test(`${version} ${format} explicit ${label} remains a present instance`,async()=>{
  const result=await checked(fixture(version,format,{name:'id',in:'query',schema},{serializedValue:text}));
  assert.equal(result.complete,true,JSON.stringify(result.findings));const evaluation=exampleResult(result);assert.equal(evaluation.valid,true);assert.equal(evaluation.omission,undefined);
 });
 test(`${version} ${format} unknown content omission remains incomplete`,async()=>{
  const result=await checked(fixture(version,format,{name:'whole',in:'querystring',content:{'application/unknown':{schema:{type:'array',maxItems:0}}}},{serializedValue:''}));
  assert.equal(result.complete,false);assert.equal(exampleResult(result).omission,undefined);
 });
 test(`${version} ${format} schema reference retains its captured defining context`,async()=>{
  const input=fixture(version,format,{name:'ids',in:'query',schema:{$ref:'schema.'+format+'#/Bag~1~0'}},{serializedValue:''});
  const value={'Bag/~':{type:'array',items:{$ref:'#/Bag~1~0'},maxItems:0}};
  input.resources.push({id:'file:///controlled/schema.'+format,text:format==='yaml'?YAML.stringify(value):JSON.stringify(value),generation:4});
  const result=await checked(input);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(exampleResult(result).omission,'empty-collection');
 });
}
for(const version of ['3.1.0','3.1.1','3.1.2'])for(const format of ['yaml','json'])test(`${version} ${format} a referenced 3.2 Example retains the containing parameter family`,async()=>{
 const input=fixture(version,format,{name:'ids',in:'query',schema:{type:'array',items:{type:'integer'},maxItems:0}},{$ref:'examples.'+format+'#/components/examples/Empty'});
 const shared={openapi:'3.2.1',info:{title:'Shared modern examples',version:'business'},paths:{},components:{examples:{Empty:{serializedValue:''}}}};
 input.resources.push({id:'file:///controlled/examples.'+format,text:format==='yaml'?YAML.stringify(shared):JSON.stringify(shared),generation:2});
 const result=await checked(input);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(exampleResult(result).resource,input.resources[1].id);assert.equal(exampleResult(result).omission,'empty-collection');
 assert.equal(analyse(input).specification.family,'3.1');
});
for(const version of ['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2',...versions])for(const format of ['yaml','json']){
 test(`${version} ${format} actual optional HTTP absence retains native request checks`,{timeout:20000},async t=>{
  const root='file:///controlled/absent.'+format,parameter=version==='2.0'?{name:'id',in:'query',type:'integer',enum:[0]}:{name:'id',in:'query',schema:{type:'integer',enum:[0]}};
  const value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Native absence',version:'business'},paths:{'/items':{get:{parameters:[parameter],responses:{204:{description:'None'}}}}}};
  const input={root,snapshot:'native-absence',resources:[{id:root,text:format==='yaml'?YAML.stringify(value):JSON.stringify(value),generation:1}]};
  const original=input.resources[0].text,{port}=await startMock(t,mockStart(original,{},root));
  const wire=path=>new Promise((resolve,reject)=>{
   const request=http.request({host:'127.0.0.1',port,path,method:'GET'},response=>{const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.on('error',reject);response.on('end',()=>resolve({status:response.statusCode,text:Buffer.concat(chunks).toString()}));});
   request.on('error',reject);request.end();
  });
  for(const path of ['/items','/items?id=0']){const response=await wire(path);assert.equal(response.status,204,response.text);}
  const invalid=await wire('/items?id=1');assert.equal(invalid.status,422,invalid.text);
  assert.equal(input.resources[0].text,original);
 });
}
test('omission semantics have a new captured evaluator identity',()=>{assert.equal(schemaProducer.version,'1.18.0+40');assert(schemaProducer.configuration.includes('parameter-example-serialization-v2'));});
