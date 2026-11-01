const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const exact='__exact_decimal__';
const pointer=value=>value.replaceAll('~','~0').replaceAll('/','~1');
function capture(version,format,media,subject='request-body',type='multipart/mixed'){
 const root='file:///multipart/api.'+format;
 const content={[type]:media},value={openapi:version,info:{title:'MIME',version:'unchanged-api-version'},paths:{'/parts':{post:{requestBody:{content},responses:{200:{description:'OK',content}}}}}};
 const at='/paths/~1parts/post/'+(subject==='request-body'?'requestBody':'responses/200')+'/content/'+pointer(type);
 const text=(format==='json'?JSON.stringify(value):'# Keep 雪 and exact decimal\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll(format==='json'?'"'+exact+'"':exact,'9007199254740993.00');
 return {root,snapshot:version+format+subject,resources:[{id:root,text,generation:7}],at,subject,hasSchema:Object.hasOwn(media,'schema'),hasItemSchema:Object.hasOwn(media,'itemSchema')};
}
function wire(parts,boundary='Fixture',prefix=''){
 return prefix+parts.map(part=>'--'+boundary+'\r\n'+Object.entries(part.headers??{}).map(([name,value])=>name+': '+value+'\r\n').join('')+'\r\n'+part.body+'\r\n').join('')+'--'+boundary+'--\r\nignored epilogue';
}
async function run(input,text,type='multipart/mixed; boundary="Fixture"'){
 const {at,subject,hasSchema,hasItemSchema,...source}=input;
 const result=await evaluateSchemas({...source,runtimeInstances:[{subject,location:type,text:Buffer.from(text).toString('base64'),mediaType:type,mediaBase64:true,
  form:{resource:source.root,pointer:at},
  ...(hasSchema?{schema:{resource:source.root,pointer:at+'/schema'}}:{}),
  ...(hasItemSchema?{itemSchema:{resource:source.root,pointer:at+'/itemSchema'}}:{}),
 }]});
 return {result,valid:result.runtimeEvaluations.every(value=>value.valid===true),findings:result.runtimeFindings};
}
const ordered={schema:{type:'array',minItems:2,maxItems:2,prefixItems:[{type:'object',required:['id'],properties:{id:{type:'integer',enum:[exact]}},additionalProperties:false},{type:'string',maxLength:0}],items:false},
 prefixEncoding:[{contentType:'application/json'},{contentType:'text/plain; charset=utf-8'}]};
const parts=[{headers:{'Content-Type':'application/json'},body:'{"id":9007199254740993.00}'},{headers:{'Content-Type':'text/plain; charset=utf-8'},body:''}];
for(const version of ['3.2.0','3.2.1'])for(const format of ['json','yaml'])for(const subject of ['request-body','response-body'])test(`${version} ${format} ${subject} ordered parts keep exact values and empty strings`,async()=>{
 const input=capture(version,format,ordered,subject),original=input.resources[0].text;
 const valid=await run(input,wire(parts,'Fixture','ignored preamble\r\n'));
 assert.equal(valid.result.complete,true,JSON.stringify(valid.findings));assert.equal(valid.valid,true,JSON.stringify(valid.findings));
 for(const text of [wire(parts).replace('9007199254740993.00','9007199254740992'),wire(parts).replace('"id":','"missing":'),wire(parts.slice(0,1)),wire([...parts,{body:'extra'}])]){
  const bad=await run(input,text);assert.equal(bad.result.complete,true,JSON.stringify(bad.findings));assert.equal(bad.valid,false,JSON.stringify(bad.findings));
 }
 assert.equal(input.resources[0].text,original);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['json','yaml'])test(`${version} ${format} nested positional and named parts use the whole original schema`,async()=>{
 const nested={schema:{type:'array',minItems:2,maxItems:2,prefixItems:[{type:'array',items:{type:'integer'},const:[0,1]},{type:'object',required:['flag','number'],properties:{flag:{type:'boolean',const:false},number:{type:'integer',const:exact}},additionalProperties:false}]},
  prefixEncoding:[{contentType:'application/json'},{contentType:'multipart/form-data',encoding:{flag:{contentType:'text/plain'},number:{contentType:'text/plain'}}}]};
 const input=capture(version,format,nested);
 const body=wire([{headers:{'Content-Type':'application/json'},body:'[0,1]'},{headers:{'Content-Type':'multipart/form-data; boundary=Inner'},body:wire([
  {headers:{'Content-Disposition':'form-data; name="flag"','Content-Type':'text/plain'},body:'false'},
  {headers:{'Content-Disposition':'form-data; name="number"','Content-Type':'text/plain'},body:'9007199254740993'},
 ],'Inner')}]);
 const positive=await run(input,body);assert.equal(positive.result.complete,true,JSON.stringify(positive.findings));assert.equal(positive.valid,true,JSON.stringify(positive.findings));
 const negative=await run(input,body.replace('false','true'));assert.equal(negative.result.complete,true);assert.equal(negative.valid,false);
 const rounded=await run(input,body.replace('9007199254740993','9007199254740992'));assert.equal(rounded.result.complete,true);assert.equal(rounded.valid,false);
});
for(const version of ['3.2.0','3.2.1'])test(`${version} independent itemSchema and surplus prefixEncoding retain their own checks`,async()=>{
 const input=capture(version,'yaml',{schema:{type:'array',minItems:1},itemSchema:{type:'integer',minimum:exact},prefixEncoding:[{contentType:'text/plain'},{contentType:'application/unsupported'}],itemEncoding:{contentType:'text/plain'}});
 const positive=await run(input,wire([{body:'9007199254740993'}]));assert.equal(positive.result.complete,true,JSON.stringify(positive.findings));assert.equal(positive.valid,true,JSON.stringify(positive.findings));assert.equal(positive.result.runtimeEvaluations.length,2);
 const negative=await run(input,wire([{body:'9007199254740992'}]));assert.equal(negative.result.complete,true);assert.equal(negative.valid,false);assert(negative.findings.some(f=>f.schema?.pointer===input.at+'/itemSchema'));
});
test('generic MIME part headers enforce required, false schemas and exact simple-style numbers',async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',items:{type:'string'}},itemEncoding:{contentType:'text/plain',headers:{'Content-Location':{required:true,schema:{type:'string',const:'https://example.invalid/%E9%9B%AA'}},'Content-ID':{schema:false},'X-Count':{schema:{type:'integer',enum:[exact]}}}}});
 const part={headers:{'Content-Location':'https://example.invalid/%E9%9B%AA','X-Count':'9007199254740993'},body:'value'};
 const valid=await run(input,wire([part]));assert.equal(valid.result.complete,true,JSON.stringify(valid.findings));assert.equal(valid.valid,true,JSON.stringify(valid.findings));
 for(const headers of [{...part.headers,'Content-ID':'forbidden'},{'X-Count':'9007199254740993'},{...part.headers,'X-Count':'9007199254740992'}]){
  const invalid=await run(input,wire([{...part,headers}]));assert.equal(invalid.result.complete,true,JSON.stringify(invalid.findings));assert.equal(invalid.valid,false);assert(invalid.findings.some(f=>f.source?.resource===input.root||f.schema?.resource===input.root));
 }
});
for(const format of ['json','yaml'])test(`${format} ordered form-data keeps repeated names as distinct array positions`,async()=>{
 const schema={type:'array',minItems:3,maxItems:3,prefixItems:[
  {type:'object',required:['item'],properties:{item:{type:'integer',const:0}},additionalProperties:false},
  {type:'object',required:['item'],properties:{item:{type:'boolean',const:false}},additionalProperties:false},
  {type:'object',required:['雪'],properties:{'雪':{type:'string',const:'café 東京'}},additionalProperties:false},
 ],items:false};
 const input=capture('3.2.1',format,{schema,prefixEncoding:[{contentType:'text/plain'},{contentType:'text/plain'},{contentType:'text/plain; charset=utf-8'}]},'request-body','multipart/form-data');
 const body=wire([['item','0'],['item','false'],['雪','café 東京']].map(([name,body])=>({headers:{'Content-Disposition':'form-data; name="'+name+'"','Content-Type':'text/plain; charset=utf-8'},body})));
 const valid=await run(input,body,'multipart/form-data; boundary=Fixture');assert.equal(valid.result.complete,true,JSON.stringify(valid.findings));assert.equal(valid.valid,true,JSON.stringify(valid.findings));
 const invalid=await run(input,body.replace('false','true'),'multipart/form-data; boundary=Fixture');assert.equal(invalid.result.complete,true);assert.equal(invalid.valid,false);
});
test('nested unnamed parts retain scalar types, encoded strings and annotation ownership through references',async()=>{
 const input=capture('3.2.1','yaml',{schema:{type:'array',minItems:1,maxItems:1,prefixItems:[{$ref:'values.yaml#/Values'}]},prefixEncoding:[{contentType:'multipart/mixed',prefixEncoding:[{contentType:'application/octet-stream'}],itemEncoding:{contentType:'text/plain'}}]});
 input.resources.push({id:'file:///multipart/values.yaml',generation:2,text:'Values:\n  type: array\n  minItems: 4\n  maxItems: 4\n  prefixItems:\n    - {type: string, contentEncoding: base64, const: AP8=}\n    - {type: "null"}\n    - {type: boolean, const: false}\n    - {type: integer, const: 0}\n  items: false\n'});
 const inner=wire([{headers:{'Content-Type':'application/octet-stream','Content-Transfer-Encoding':'base64'},body:'AP8='},{body:'null'},{body:'false'},{body:'0'}],'Nested');
 const body=wire([{headers:{'Content-Type':'multipart/mixed; boundary=Nested'},body:inner}]);
 const valid=await run(input,body);assert.equal(valid.result.complete,true,JSON.stringify(valid.findings));assert.equal(valid.valid,true,JSON.stringify(valid.findings));
 const invalid=await run(input,body.replace('AP8=','AP4='));assert.equal(invalid.result.complete,true);assert.equal(invalid.valid,false);
 const conflict=await run(input,body.replace('Content-Transfer-Encoding: base64','Content-Transfer-Encoding: binary'));assert.equal(conflict.result.complete,false);assert(conflict.findings.some(f=>f.detailCode==='runtime.form.transfer.undefined'&&f.source?.resource==='file:///multipart/values.yaml'));
});
for(const [label,mutate]of [
 ['missing closing delimiter',text=>text.replace('--Fixture--','--Other--')],
 ['duplicate content type',text=>text.replace('Content-Type: application/json','Content-Type: application/json\r\nContent-Type: text/plain')],
 ['invalid header',text=>text.replace('Content-Type: application/json','bad header: application/json')],
 ['unfinished header',text=>text.replace('Content-Type: application/json\r\n\r\n','Content-Type: application/json\r\n')],
])test(`${label} is invalid MIME, never a clean schema result`,async()=>{
 const input=capture('3.2.1','json',ordered),original=input.resources[0].text,result=await run(input,mutate(wire(parts)));
 assert.equal(result.result.complete,true,JSON.stringify(result.findings));assert.equal(result.valid,false);assert(result.findings.some(f=>f.code==='runtime.body.syntax'));assert.equal(input.resources[0].text,original);
});
test('unimplemented part media, unresolved annotations and bounded nesting stay incomplete and located',async()=>{
 const source=capture('3.2.1','json',{schema:{type:'array',items:{}},itemEncoding:{contentType:'application/xml'}});
 const unsupported=await run(source,wire([{headers:{'Content-Type':'application/xml'},body:'<value/>'}]));assert.equal(unsupported.result.complete,false);assert.equal(unsupported.valid,false);assert(unsupported.findings.some(f=>f.kind==='unsupported'));
 const missing=capture('3.2.1','json',{schema:{type:'array',items:{$ref:'missing.yaml#/Part'}},itemEncoding:{contentType:'application/json'}});
 const unresolved=await run(missing,wire([{headers:{'Content-Type':'application/json'},body:'false'}]));assert.equal(unresolved.result.complete,false);assert.equal(unresolved.valid,false);
 let rule={contentType:'text/plain'};
 for(let depth=0;depth<10;depth++)rule={contentType:'multipart/mixed',itemEncoding:rule};
 // Different boundaries avoid accepting a parent delimiter as a nested one.
 const make=(depth,boundary)=>depth===0?wire([{body:'x'}],boundary):wire([{headers:{'Content-Type':'multipart/mixed; boundary=Level'+depth},body:make(depth-1,'Level'+depth)}],boundary);
 const deep=capture('3.2.1','json',{schema:{type:'array'},itemEncoding:rule});
 const limited=await run(deep,make(10,'Fixture'));assert.equal(limited.result.complete,false);assert.equal(limited.valid,false);assert(limited.findings.some(f=>f.code==='runtime.body.limit'));
});
test('generic MIME headers require ASCII while form-data retains UTF-8 name support',async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',items:{type:'string'}},itemEncoding:{contentType:'text/plain'}});
 const result=await run(input,wire([{headers:{'Content-Location':'https://example.invalid/雪'},body:'value'}]));
 assert.equal(result.result.complete,true);assert.equal(result.valid,false);assert(result.findings.some(f=>f.code==='runtime.body.syntax'));
});
test('a nested multipart entity cannot be base64 transfer-encoded',async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',items:{type:'array',items:{type:'string'}}},itemEncoding:{contentType:'multipart/mixed',itemEncoding:{contentType:'text/plain'}}});
 const inner=wire([{body:'value'}],'Inner');
 const result=await run(input,wire([{headers:{'Content-Type':'multipart/mixed; boundary=Inner','Content-Transfer-Encoding':'base64'},body:Buffer.from(inner).toString('base64')}]));
 assert.equal(result.result.complete,true);assert.equal(result.valid,false);assert(result.findings.some(f=>f.code==='runtime.body.syntax'));
});
for(const headers of [{},{'Content-Type':'text/plain'}])test(`MIME text without an explicit charset defaults to ASCII: ${JSON.stringify(headers)}`,async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',items:{type:'string'}},itemEncoding:{contentType:'text/plain'}});
 const result=await run(input,wire([{headers,body:'雪'}]));assert.equal(result.result.complete,true);assert.equal(result.valid,false);
 const utf8=await run(input,wire([{headers:{'Content-Type':'text/plain; charset=utf-8'},body:'雪'}]));assert.equal(utf8.result.complete,true);assert.equal(utf8.valid,true);
});
test('an empty MIME part can omit both its headers and body area',async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',minItems:1,maxItems:1,items:{type:'string',maxLength:0}},itemEncoding:{contentType:'text/plain'}});
 const result=await run(input,'--Fixture\r\n\r\n--Fixture--\r\n');assert.equal(result.result.complete,true);assert.equal(result.valid,true,JSON.stringify(result.findings));
});
test('a MIME part may contain headers without a body area',async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',minItems:1,maxItems:1,items:{type:'string',maxLength:0}},itemEncoding:{contentType:'text/plain'}});
 const result=await run(input,'--Fixture\r\nContent-Type: text/plain\r\n\r\n--Fixture--\r\n');assert.equal(result.result.complete,true);assert.equal(result.valid,true,JSON.stringify(result.findings));
});
test('multipart digest keeps its message/rfc822 default instead of fabricating a text value',async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',items:{}},itemEncoding:{contentType:'message/rfc822'}},'response-body','multipart/digest');
 const result=await run(input,wire([{body:'Subject: message\r\n\r\nbody'}]),'multipart/digest; boundary=Fixture');
 assert.equal(result.result.complete,false);assert.equal(result.valid,false);assert(result.findings.some(f=>f.kind==='unsupported'));
});
for(const version of ['3.1.2','3.2.1'])for(const format of ['json','yaml'])test(`${version} ${format} contentEncoding does not apply to an object instance`,async()=>{
 const input=capture(version,format,{schema:{type:'object',properties:{value:{type:'object',contentEncoding:'base64',required:['flag'],properties:{flag:{const:false}}}},required:['value']},encoding:{value:{contentType:'application/json'}}},'request-body','multipart/form-data');
 const body=wire([{headers:{'Content-Disposition':'form-data; name="value"','Content-Type':'application/json'},body:'{"flag":false}'}]);
 const result=await run(input,body,'multipart/form-data; boundary=Fixture');assert.equal(result.result.complete,true,JSON.stringify(result.findings));assert.equal(result.valid,true,JSON.stringify(result.findings));
});
test('positional contentEncoding does not apply to an object instance',async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',items:{type:'object',contentEncoding:'base64',required:['flag'],properties:{flag:{const:false}}}},itemEncoding:{contentType:'application/json'}});
 const result=await run(input,wire([{headers:{'Content-Type':'application/json'},body:'{"flag":false}'}]));
 assert.equal(result.result.complete,true,JSON.stringify(result.findings));assert.equal(result.valid,true,JSON.stringify(result.findings));
});
test('an encoded schema string still needs valid decoded JSON media framing',async()=>{
 for(const [encoded,valid]of [['ZmFsc2U=',true],['AP8=',false]]){
  const input=capture('3.2.1','json',{schema:{type:'array',items:{type:'string',contentEncoding:'base64',const:encoded}},itemEncoding:{contentType:'application/json'}});
  const result=await run(input,wire([{headers:{'Content-Type':'application/json','Content-Transfer-Encoding':'base64'},body:encoded}]));
  assert.equal(result.result.complete,true,JSON.stringify(result.findings));assert.equal(result.valid,valid,JSON.stringify(result.findings));
 }
});
test('an encoded schema string still needs the declared text charset',async()=>{
 const input=capture('3.2.1','json',{schema:{type:'array',items:{type:'string',contentEncoding:'base64',const:'AP8='}},itemEncoding:{contentType:'text/plain'}});
 const result=await run(input,wire([{headers:{'Content-Type':'text/plain','Content-Transfer-Encoding':'base64'},body:'AP8='}]));
 assert.equal(result.result.complete,true);assert.equal(result.valid,false);
});
