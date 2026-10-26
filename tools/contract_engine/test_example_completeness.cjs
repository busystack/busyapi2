const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const render=(value,format)=>format==='json'?JSON.stringify(value):YAML.stringify(value);
async function check(document,format){
 const root='file:///approved/api.'+format,text=render(document,format);
 const resources=[{id:root,text,generation:7}],before=structuredClone(resources);
 const result=await evaluateSchemas({root,snapshot:'example-coverage',resources});
 assert.deepEqual(resources,before);return {result,text};
}
const api=version=>({openapi:version,info:{title:'Exact 雪',version:'unchanged'},paths:{}});
for(const version of versions)for(const format of ['yaml','json'])for(const paired of [false,true])test(`${version} ${format} external serialization remains incomplete paired=${paired}`,async()=>{
 const document=api(version);
 document.paths['/check']={get:{parameters:[{name:'id',in:'query',schema:{type:'integer'},examples:{Remote:{externalValue:'./example.txt',...(paired?version.startsWith('3.2.')?{dataValue:0}:{summary:'Do not infer retrieval'}:{})}}}],responses:{204:{description:'Empty'}}}};
 const {result,text}=await check(document,format);
 assert.equal(result.complete,false,JSON.stringify({skipped:result.skipped,findings:result.findings}));
 const finding=result.findings.find(value=>value.code==='example.serialization.incomplete');
 assert(finding,JSON.stringify(result.findings));assert.equal(finding.pointer,'/paths/~1check/get/parameters/0/examples/Remote/externalValue');
 assert.equal(finding.detailCode,'example.external-value.unavailable');
 assert(text.slice(...finding.range).includes('./example.txt'));
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const owner of ['parameter','header','unused-media','unused-example'])test(`${version} ${format} unhandled serialization has located incomplete coverage ${owner}`,async()=>{
 const document=api(version),example={serializedValue:'id=0'};
 if(owner==='parameter')document.paths['/check']={get:{parameters:[{name:'id',in:'query',schema:{type:'integer'},examples:{Value:example}}],responses:{204:{description:'Empty'}}}};
 if(owner==='header')document.paths['/check']={get:{responses:{200:{description:'Read',headers:{'X-Id':{schema:{type:'integer'},examples:{Value:example}}}}}}};
 if(owner==='unused-media')document.components={mediaTypes:{Unused:{schema:{type:'integer'},examples:{Value:example}}}};
 if(owner==='unused-example')document.components={examples:{Unused:example}};
 const {result}=await check(document,format);
 assert.equal(result.complete,false,JSON.stringify({skipped:result.skipped,findings:result.findings}));
 const finding=result.findings.find(value=>value.code==='example.serialization.incomplete');
 assert(finding,JSON.stringify(result.findings));assert(finding.pointer.endsWith('/serializedValue'));
 assert.equal(finding.detailCode,'example.serialization.context-unchecked');
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} descriptive examples and reference-looking data require no serialization proof`,async()=>{
 const document=api(version);document.components={examples:{Description:{summary:'No value supplied'},Data:{value:{externalValue:'not a resource',serializedValue:false,$ref:'not a reference'}}}};
 document.paths['/check']={post:{requestBody:{content:{'application/json':{schema:{type:'object'},examples:{Data:{$ref:'#/components/examples/Data'}}}}},responses:{204:{description:'Empty'}}}};
 const {result}=await check(document,format);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.findings.length,0);
});
for(const format of ['yaml','json'])test(`Swagger ${format} response-example payload keys retain data ownership`,async()=>{
 const document={swagger:'2.0',info:{title:'Keep',version:'unchanged'},paths:{'/check':{get:{responses:{200:{description:'Read',schema:{type:'object'},examples:{'application/json':{externalValue:'not retrieved',serializedValue:false,$ref:'literal'}}}}}}}};
 const {result}=await check(document,format);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.findings.length,0);
});
for(const version of versions)for(const format of ['yaml','json'])for(const constrained of [false,true])test(`${version} ${format} external media proof requires the serialization even with data constrained=${constrained}`,async()=>{
 const document=api(version);
 document.paths['/check']={post:{requestBody:{content:{'application/json':{...(constrained?{schema:{type:'integer'}}:{}),examples:{Remote:{externalValue:'https://example.invalid/never-acquired.json',...(version.startsWith('3.2.')?{dataValue:0}:{})}}}}},responses:{204:{description:'Empty'}}}};
 const {result}=await check(document,format);assert.equal(result.complete,false,JSON.stringify(result.findings));
 const finding=result.findings.find(value=>value.code==='example.serialization.incomplete');
 assert.equal(finding?.pointer,'/paths/~1check/post/requestBody/content/application~1json/examples/Remote/externalValue');
 assert.equal(finding.detailCode,'example.external-value.unavailable');
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} chained shared external examples retain physical source and one finding`,async()=>{
 const root='file:///approved/api.'+format,shared='file:///approved/examples.'+format;
 const document=api(version);document.paths['/check']={get:{parameters:[{name:'id',in:'query',schema:{type:'integer'},examples:{First:{$ref:'./examples.'+format+'#/Chain'},Second:{$ref:'./examples.'+format+'#/Value'}}}],responses:{204:{description:'Empty'}}}};
 const resources=[{id:root,text:render(document,format),generation:1},{id:shared,text:render({Chain:{$ref:'#/Value'},Value:{externalValue:'./wire.txt'}},format),generation:2}];
 const before=structuredClone(resources),result=await evaluateSchemas({root,snapshot:'shared-example',resources});
 assert.equal(result.complete,false);const findings=result.findings.filter(value=>value.code==='example.serialization.incomplete');
 assert.equal(findings.length,1,JSON.stringify(findings));assert.equal(findings[0].resource,shared);assert.equal(findings[0].pointer,'/Value/externalValue');assert.deepEqual(resources,before);
});
for(const version of ['3.2.0','3.2.1'])test(`${version} shared YAML aliases report the physical serialization once`,async()=>{
 const root='file:///approved/api.yaml',text=`openapi: ${version}\ninfo: {title: Keep, version: unchanged}\nx-value: &shared\n  serializedValue: 'id=0'\npaths:\n  /check:\n    get:\n      parameters:\n        - name: id\n          in: query\n          schema: {type: integer}\n          examples: {First: *shared, Second: *shared}\n      responses: {'204': {description: Empty}}\n`;
 const resources=[{id:root,text,generation:1}],result=await evaluateSchemas({root,snapshot:'alias',resources});
 assert.equal(result.complete,false);const findings=result.findings.filter(value=>value.code==='example.serialization.incomplete');
 assert.equal(findings.length,1,JSON.stringify(findings));assert.equal(findings[0].pointer,'/x-value/serializedValue');assert.equal(resources[0].text,text);
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} Reference Object serialization siblings do not become example data`,async()=>{
 const document=api(version);document.components={examples:{Actual:{value:0}}};
 document.paths['/check']={get:{parameters:[{name:'id',in:'query',schema:{type:'integer'},examples:{Reference:{$ref:'#/components/examples/Actual',externalValue:'https://example.invalid/ignored',...(version.startsWith('3.2.')?{serializedValue:'ignored'}:{})}}}],responses:{204:{description:'Empty'}}}};
 const {result}=await check(document,format);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.findings.length,0);
});
