const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');

const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const escaped=value=>value.replaceAll('~','~0').replaceAll('/','~1');
function capture(version,format,subject,nested=false){
 const root='file:///framing/api.'+format,legacy=version==='2.0',media=nested?'multipart/mixed':'multipart/form-data';
 const schema=nested?{type:'array',items:{type:'array',items:{type:'string'}}}:{type:'object',properties:{value:{type:'string'}}};
 const content={[media]:{schema,...(nested?{itemEncoding:{contentType:'multipart/mixed',itemEncoding:{contentType:'text/plain'}}}:{})}};
 const operation=legacy?{consumes:[media],produces:[media],parameters:[{in:'formData',name:'value',type:'string',allowEmptyValue:true}],responses:{200:{description:'Keep response',schema}}}:
  {requestBody:{content},responses:{200:{description:'Keep response',content}}};
 const value={...(legacy?{swagger:version}:{openapi:version}),info:{title:'Keep 雪',version:'unchanged'},paths:{'/parts':{post:operation}}};
 const text=format==='json'?JSON.stringify(value):'# Preserve CRLF and organization\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
 const at='/paths/~1parts/post'+(legacy?(subject==='request-body'?'':'/responses/200'):'/'+(subject==='request-body'?'requestBody':'responses/200')+'/content/'+escaped(media));
 return {root,snapshot:version+format+subject,resources:[{id:root,text,generation:3}],at,subject,legacy,media};
}
async function run(input,wire){
 const {at,subject,legacy,media,...source}=input;
 return evaluateSchemas({...source,runtimeInstances:[{subject,location:media,text:Buffer.from(wire).toString('base64'),mediaType:media+'; boundary=Fixture',mediaBase64:true,
  form:{resource:source.root,pointer:at},...(!legacy||subject==='response-body'?{schema:{resource:source.root,pointer:at+'/schema'}}:{})}]});
}
function validity(result,expected){
 assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));
 assert(result.runtimeEvaluations.length>0);
 assert.equal(result.runtimeEvaluations.every(value=>value.valid===true),expected,JSON.stringify(result.runtimeFindings));
 if(!expected)assert(result.runtimeFindings.some(value=>value.code==='runtime.body.syntax'),JSON.stringify(result.runtimeFindings));
}
const named=value=>'--Fixture\r\nContent-Disposition: form-data; name="value"\r\n\r\n'+value+'\r\n--Fixture--\r\n';
for(const version of versions)for(const format of ['yaml','json'])for(const subject of ['request-body','response-body']){
 // Swagger has no formData response projection; its ordinary schema body uses
 // the same RFC 2046 framing but does not define a parameter value mapping.
 if(version==='2.0'&&subject==='response-body')continue;
 test(`${version} ${format} ${subject} requires a first MIME part and reserves complete boundary prefixes`,async()=>{
  const input=capture(version,format,subject),original=input.resources[0].text;
  for(const wire of [named(''),named('before\r\n--Other-is-data\r\nafter'),named('inside--Fixture-is-data')])validity(await run(input,wire),true);
  for(const wire of ['--Fixture--\r\n','preamble\r\n--Fixture--\r\nepilogue',named('before\r\n--Fixture-is-data\r\nafter'),named('before\r\n--Fixture--invalid\r\nafter')])validity(await run(input,wire),false);
  assert.equal(input.resources[0].text,original);
 });
}
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const subject of ['request-body','response-body'])test(`${version} ${format} ${subject} nested MIME boundaries cannot begin with the enclosing boundary`,async()=>{
 const input=capture(version,format,subject,true),original=input.resources[0].text;
 const nested=boundary=>'--Fixture\r\nContent-Type: multipart/mixed; boundary='+boundary+'\r\n\r\n--'+boundary+'\r\n\r\nvalue\r\n--'+boundary+'--\r\n\r\n--Fixture--\r\n';
 validity(await run(input,nested('Inner')),true);
 for(const boundary of ['FixtureNested','Fixture--Nested','Fixture'])validity(await run(input,nested(boundary)),false);
 assert.equal(input.resources[0].text,original);
});
