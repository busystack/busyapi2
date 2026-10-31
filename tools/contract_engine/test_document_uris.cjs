const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{deriveBundle}=require('./dist/derived_bundle.cjs');
const {planMigration}=require('./dist/migration.cjs'),{planFileMove}=require('./dist/refactoring_file.cjs');
const patches=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function capture(version,format,terms){
 const root='file:///approved/api.'+format,value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Terms 雪',version:'1',termsOfService:terms},paths:{},'x-number':111,'x-payload':{termsOfService:'not a URI',contact:{url:'also not a URI'}}};
 const text=(format==='json'?JSON.stringify(value):'# Keep comments\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace('111','9007199254740993.00');
 return {root,snapshot:'terms-'+version,resources:[{id:root,text,generation:1,identity:'original'}]};
}
for(const version of patches)for(const format of ['yaml','json'])for(const [label,value,valid]of [['prose','Internal use only',false],['unicode','利用条件',false],['newline','https://example.invalid/\n',false],['escape','https://example.invalid/%zz',false],['relative','../terms?lang=en#part',true],['encoded','https://example.invalid/%E9%9B%AA',true],['empty','',true]])test(`${version} ${format} Terms of Service ${label} uses its own family`,()=>{
 const input=capture(version,format,value),before=JSON.stringify(input),result=analyse(input),expected=version==='2.0'||valid,issues=result.findings.filter(f=>f.code==='metadata.uri');
 assert.equal(result.status,expected?'complete':'invalid',JSON.stringify(result.findings));assert.equal(result.complete,true);assert.equal(issues.length,expected?0:1);assert.equal(JSON.stringify(input),before);
 if(!expected){assert.equal(issues[0].pointer,'/info/termsOfService');assert.equal(issues[0].resource,input.root);assert.equal(issues[0].category,'openapi');assert(issues[0].range[1]>issues[0].range[0]);}
});
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const field of ['contact','license','externalDocs'])test(`${version} ${format} ${field} URI syntax is enforced outside literal payloads`,()=>{
 const input=capture(version,format,'https://terms.example.invalid/'),document=YAML.parse(input.resources[0].text);if(field==='externalDocs')document.externalDocs={url:'not a URI'};else document.info[field]={...(field==='license'?{name:'License'}:{}),url:'not a URI'};
 input.resources[0].text=format==='json'?JSON.stringify(document):YAML.stringify(document);const result=analyse(input),issue=result.findings.find(f=>f.code==='metadata.uri');assert(issue,JSON.stringify(result.findings));assert.equal(issue.pointer,field==='externalDocs'?'/externalDocs/url':'/info/'+field+'/url');assert.equal(result.status,'invalid');
});
for(const format of ['yaml','json'])for(const text of ['Internal use only','terms','https://terms.example.invalid/','利用条件',''])test(`Swagger ${format} free text remains exact when bundled or moved: ${JSON.stringify(text)}`,()=>{
 const input=capture('2.0',format,text),original=input.resources[0].text,bundle=deriveBundle({...input,outputId:'https://output.example.invalid/api.json'});assert.equal(bundle.complete,true);assert.equal(JSON.parse(bundle.output.text).info.termsOfService,text);assert(bundle.output.text.includes('9007199254740993.00'));assert.equal(input.resources[0].text,original);
 const plan=planFileMove({snapshot:input.snapshot,resources:input.resources,contexts:[{root:input.root,resources:[input.root]}],target:{resource:input.root,generation:1},destinationResource:'file:///approved/nested/api.'+format});let moved=original;
 for(const edit of plan.edits.filter(e=>e.buffer===input.root).sort((a,b)=>b.start-a.start)){assert.equal(moved.slice(edit.start,edit.end),edit.expected);moved=moved.slice(0,edit.start)+edit.replacement+moved.slice(edit.end);}
 assert.equal(moved,original);assert.equal(YAML.parse(moved).info.termsOfService,text);assert.equal(input.resources[0].text,original);
});
for(const format of ['yaml','json'])for(const targetVersion of ['3.0.4','3.1.2','3.2.1'])test(`Swagger ${format} prose cannot become a target ${targetVersion} URL`,async()=>{
 const input={...capture('2.0',format,'Internal use only'),targetVersion,destination:'file:///output/review/'},before=input.resources[0].text,result=await planMigration(input);assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);const issue=result.problems.find(p=>p.code==='migration.info.terms-uri');assert(issue,JSON.stringify(result.problems));assert.equal(issue.pointer,'/info/termsOfService');assert.equal(issue.resource,input.root);assert(input.resources[0].text.slice(...issue.range).includes('Internal use only'));assert.equal(input.resources[0].text,before);
});
for(const format of ['yaml','json'])for(const targetVersion of ['3.0.4','3.1.2','3.2.1'])test(`Swagger ${format} URL interpretation requires an explicit captured decision for ${targetVersion}`,async()=>{
 const input={...capture('2.0',format,'https://terms.example.invalid/policy'),targetVersion,destination:'file:///output/review/'},before=input.resources[0].text,review=await planMigration(input);assert.equal(review.status,'requires-decision');assert.deepEqual(review.outputs,[]);const issue=review.problems.find(p=>p.code==='migration.info.terms-uri-activation');assert(issue,JSON.stringify(review.problems));assert.equal(issue.pointer,'/info/termsOfService');assert.deepEqual(issue.choices,['interpret-terms-as-uri']);
 const result=await planMigration({...input,decisions:{[issue.id]:'interpret-terms-as-uri'}});assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.producerVersion,'26');assert(result.acceptedDecisions.includes(issue.id));assert.equal(YAML.parse(result.outputs.find(o=>o.id===result.outputRoot).text).info.termsOfService,'https://terms.example.invalid/policy');assert.equal(input.resources[0].text,before);await assert.rejects(planMigration({...input,snapshot:'changed',decisions:{[issue.id]:'interpret-terms-as-uri'}}),error=>error.code==='migration.decisions.stale');
});
for(const format of ['yaml','json'])test(`Swagger ${format} same-family migration retains prose without activating URI rules`,async()=>{
 const input={...capture('2.0',format,'Internal use only'),targetVersion:'2.0',destination:'file:///output/review/'},result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(YAML.parse(result.outputs.find(o=>o.id===result.outputRoot).text).info.termsOfService,'Internal use only');
});
for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} unsupported metadata host syntax stays incomplete`,()=>{
 const input=capture(version,'json','https://[v1.future]/terms'),result=analyse(input);assert.equal(result.status,'incomplete');assert.equal(result.complete,false);const issue=result.findings.find(f=>f.code==='metadata.uri.unsupported');assert(issue);assert.equal(issue.pointer,'/info/termsOfService');assert.equal(issue.severity,'warning');
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} externalValue diagnostics distinguish Reference siblings and example payloads`,()=>{
 const input=capture(version,format,'https://terms.example.invalid/'),document=YAML.parse(input.resources[0].text);document.components={examples:{Bad:{externalValue:'payload with spaces.json'},Literal:{value:{externalValue:'literal payload',url:'literal url'}},Use:{$ref:'#/components/examples/Literal',externalValue:'ignored sibling'}}};input.resources[0].text=format==='json'?JSON.stringify(document):YAML.stringify(document);
 const result=analyse(input),issues=result.findings.filter(f=>f.code==='metadata.uri');assert.equal(issues.length,1,JSON.stringify(result.findings));assert.equal(issues[0].pointer,'/components/examples/Bad/externalValue');assert.equal(result.complete,true);assert.equal(result.resources.length,1);
});
test('repeated same-resource declaration switches do not retain Terms URI rules',()=>{
 for(let cycle=0;cycle<5;cycle++)for(const version of ['2.0','3.0.4','3.1.2','3.2.1','2.0']){const input=capture(version,'json','Internal use only');input.snapshot+='-'+cycle;const result=analyse(input);assert.equal(result.status,version==='2.0'?'complete':'invalid');}
});
