const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');

const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const schema={type:'object',required:['id','flag','empty','$ref'],properties:{id:{type:'integer',enum:['EXACT']},flag:{type:'boolean',enum:[false]},empty:{type:'string',maxLength:0},$ref:{type:'string',enum:['literal-not-a-resource']}},additionalProperties:false};
function capture(version,format,header={required:true,content:{'application/json':{schema}}},subject='request-body'){
 const root='file:///mime-header/api.'+format,ordered=version.startsWith('3.2.');
 const encoding={contentType:'text/plain',headers:{'X-Meta':header}};
 const media={schema:ordered?{type:'array',items:{type:'string'}}:{type:'object',required:['value'],properties:{value:{type:'string'}}},...(ordered?{itemEncoding:encoding}:{encoding:{value:encoding}})};
 const content={'multipart/mixed':media},value={openapi:version,info:{title:'Keep 雪',version:'unchanged'},paths:{'/parts':{post:{requestBody:{content},responses:{200:{description:'Keep response',content}}}}}};
 const text=(format==='json'?JSON.stringify(value):'# Keep CRLF and exact numbers\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 const at='/paths/~1parts/post/'+(subject==='request-body'?'requestBody':'responses/200')+'/content/multipart~1mixed';
 return {root,snapshot:version+format+subject,resources:[{id:root,text,generation:3}],at,subject,ordered,headerAt:at+(ordered?'/itemEncoding':'/encoding/value')+'/headers/X-Meta'};
}
const good='{"id":9007199254740993.00,"flag":false,"empty":"","$ref":"literal-not-a-resource"}';
function wire(value=good,extra=''){
 return '--Fixture\r\nContent-Disposition: form-data; name="value"\r\nContent-Type: text/plain\r\n'+(value===null?'':'X-Meta: '+value+'\r\n')+extra+'\r\nvalue\r\n--Fixture--\r\n';
}
async function run(input,value=good,extra=''){
 const {at,subject,ordered,headerAt,...source}=input;
 return evaluateSchemas({...source,runtimeInstances:[{subject,location:'multipart/mixed',text:Buffer.from(wire(value,extra)).toString('base64'),mediaType:'multipart/mixed; boundary=Fixture',mediaBase64:true,form:{resource:input.root,pointer:at},schema:{resource:input.root,pointer:at+'/schema'}}]});
}
function result(value,valid,complete=true){
 assert.equal(value.complete,complete,JSON.stringify(value.runtimeFindings));assert(value.runtimeEvaluations.length>0);
 assert.equal(value.runtimeEvaluations.every(entry=>entry.valid===true),valid,JSON.stringify(value.runtimeFindings));
}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} MIME Header content keeps exact JSON kinds, references and source ownership`,async()=>{
 const input=capture(version,format),original=input.resources[0].text;
 result(await run(input),true);
 for(const value of [good.replace('9007199254740993.00','9007199254740992'),good.replace('false','true'),good.replace('"empty":"",',''),good.replace('literal-not-a-resource','another-literal')]){
  const invalid=await run(input,value);result(invalid,false);
  assert(invalid.runtimeFindings.some(finding=>finding.schema?.resource===input.root&&finding.schema.pointer===input.headerAt+'/content/application~1json/schema'),JSON.stringify(invalid.runtimeFindings));
 }
 const malformed=await run(input,'{"id":');result(malformed,false);assert(malformed.runtimeFindings.some(finding=>finding.code==='runtime.body.syntax'&&finding.source?.resource===input.root&&finding.source.pointer===input.headerAt+'/content/application~1json'));
 const duplicate=await run(input,good,'X-Meta: '+good+'\r\n');result(duplicate,false,false);
 const missing=await run(input,null);result(missing,false);assert(missing.runtimeFindings.some(finding=>finding.code==='runtime.form.header.required'&&finding.source?.pointer===input.headerAt));
 assert.equal(input.resources[0].text,original);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} MIME Header content follows captured external Header Objects`,async()=>{
 const input=capture(version,format,{$ref:'headers.'+format+'#/Alias'}),original=input.resources[0].text;
 const value={Alias:{$ref:'#/Actual'},Actual:{required:true,content:{'application/json':{schema}}},'x-payload':{$ref:'literal'}};
 const text=(format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 input.resources.push({id:'file:///mime-header/headers.'+format,text,generation:4});
 result(await run(input),true);const invalid=await run(input,good.replace('false','true'));result(invalid,false);
 assert(invalid.runtimeFindings.some(finding=>finding.schema?.resource==='file:///mime-header/headers.'+format&&finding.schema.pointer==='/Actual/content/application~1json/schema'));
 assert.equal(input.resources[0].text,original);assert.equal(input.resources[1].text,text);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} MIME Header content uses the existing text and form media decoders`,async()=>{
 const text=capture(version,format,{content:{'text/plain':{schema:{type:'string',enum:['false']}}}});
 result(await run(text,'false'),true);result(await run(text,'true'),false);
 const form=capture(version,format,{content:{'application/x-www-form-urlencoded':{schema:{type:'object',required:['n','flag','empty'],properties:{n:{type:'integer',enum:['EXACT']},flag:{type:'boolean',enum:[false]},empty:{type:'string',maxLength:0}}}}}});
 result(await run(form,'n=9007199254740993&flag=false&empty='),true);result(await run(form,'n=9007199254740992&flag=false&empty='),false);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} response MIME headers respect their owning family's Encoding applicability`,async()=>{
 const input=capture(version,'yaml',undefined,'response-body');
 result(await run(input),true);result(await run(input,good.replace('false','true')),!input.ordered);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} MIME Header binary content retains its family's data model`,async()=>{
 const legacy=version.startsWith('3.0.');
 const input=capture(version,format,{content:{'application/octet-stream':{schema:legacy?{type:'string',minLength:2,maxLength:2,enum:['AB']}:{not:{type:'null'}}}}});
 result(await run(input,'AB'),true);
 const string=capture(version,format,{content:{'application/octet-stream':{schema:{type:'string',minLength:2,maxLength:2}}}});
 result(await run(string,'AB'),legacy);result(await run(string,'ABC'),false);
 const unknown=capture(version,format,{content:{'application/x-unimplemented-header-codec':{schema:{}}}});result(await run(unknown,'AB'),false,false);
});
for(const format of ['yaml','json'])test(`${format} modern Header schema dialect and boolean schema remain authoritative`,async()=>{
 for(const schema of [true,false]){
  const input=capture('3.2.1',format,{content:{'application/json':{schema}}});result(await run(input,'false'),schema);
 }
 const input=capture('3.1.2',format,{content:{'application/json':{schema:{$schema:'https://example.invalid/unsupported-dialect',type:'object'}}}});
 result(await run(input,'{}'),false,false);
});
for(const format of ['yaml','json'])test(`${format} Header content itemSchema evaluates its own captured sequential values`,async()=>{
 const input=capture('3.2.1',format,{content:{'application/jsonl':{schema:{type:'array'},itemSchema:{type:'integer',minimum:1}}}});
 result(await run(input,'1'),true);const invalid=await run(input,'0');result(invalid,false);
 assert(invalid.runtimeFindings.some(finding=>finding.schema?.pointer===input.headerAt+'/content/application~1jsonl/itemSchema'));
});
for(const version of ['3.0.4','3.2.1'])test(`${version} external YAML Header aliases preserve their physical schema provenance`,async()=>{
 const input=capture(version,'yaml',{$ref:'headers.yaml#/Alias'});
 const header={required:true,content:{'application/json':{schema}}};
 const text=('# Keep shared anchor\r\n'+YAML.stringify({Actual:header,Alias:header}).replaceAll('\n','\r\n')).replaceAll('EXACT','9007199254740993.00');
 assert(/Actual: &/.test(text)&&/Alias: \*/.test(text));
 input.resources.push({id:'file:///mime-header/headers.yaml',text,generation:8});
 const original=JSON.stringify(input.resources);result(await run(input),true);
 const invalid=await run(input,good.replace('false','true'));result(invalid,false);
 assert(invalid.runtimeFindings.some(finding=>finding.schema?.resource==='file:///mime-header/headers.yaml'&&Array.isArray(finding.schema.range)&&finding.schema.range[0]>0),JSON.stringify(invalid.runtimeFindings));
 assert.equal(JSON.stringify(input.resources),original);
});
