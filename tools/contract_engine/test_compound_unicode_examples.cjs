const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas,schemaProducer}=require('./dist/schema_evaluation.cjs');
const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const modern=v=>v.startsWith('3.1')||v.startsWith('3.2');
const render=(value,format)=>format==='yaml'?'# Keep MIME source\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)+'\r\n';
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
function fixture(kind,charset){
 const concrete='text/plain'+(charset?'; charset='+charset:'');
 const contentType='multipart/'+(kind.endsWith('form')?'form-data':'mixed')+'; boundary=Outer';
 const leaf=(boundary,form)=>'--'+boundary+'\r\n'+(form?'Content-Disposition: form-data; name="label"\r\n':'')+'Content-Type: '+concrete+'\r\n\r\nA\r\n--'+boundary+'--\r\n';
 const textSchema={type:'string',enum:['A']},objectSchema={type:'object',required:['label'],properties:{label:textSchema}},arraySchema={type:'array',minItems:1,items:textSchema};
 if(kind==='form')return {contentType,schema:objectSchema,encoding:{label:{contentType:concrete}},wire:leaf('Outer',true)};
 if(kind==='mixed')return {contentType,schema:arraySchema,itemEncoding:{contentType:concrete},wire:leaf('Outer',false)};
 const childForm=kind==='nested-mixed',childType='multipart/'+(childForm?'form-data':'mixed')+'; boundary=Inner';
 const nested={contentType:childType,...childForm?{encoding:{label:{contentType:concrete}}}:{itemEncoding:{contentType:concrete}}};
 const schema=childForm?{type:'array',minItems:1,items:objectSchema}:{type:'object',required:['group'],properties:{group:{type:'array',minItems:1,items:arraySchema}}};
 return {contentType,schema,...childForm?{itemEncoding:nested}:{encoding:{group:nested}},wire:'--Outer\r\n'+(childForm?'':'Content-Disposition: form-data; name="group"\r\n')+'Content-Type: '+childType+'\r\n\r\n'+leaf('Inner',childForm)+'\r\n--Outer--\r\n'};
}
function document(version,fixture,example){
 const {wire,contentType,...description}=fixture;
 return {openapi:version,info:{title:'MIME contexts',version:'business'},paths:{'/parts':{post:{requestBody:{content:{[contentType]:{...description,examples:{Value:example}}}},responses:{204:{description:'None'}}}}}};
}
async function check(version,format,kind,charset){
 const f=fixture(kind,charset),root='file:///controlled/mime.'+format;
 const source=render(document(version,f,{serializedValue:f.wire}),format),resources=[{id:root,text:source,generation:3}];
 const input={root,snapshot:version+format+kind+charset,resources};
 const result=await evaluateSchemas(input),sample=result.serializedEvaluations[0];
 assert(sample,JSON.stringify(result));const eligible=!['iso-8859-1','shift_jis'].includes(charset);
 assert.equal(sample.complete,eligible,JSON.stringify(result.findings));assert.equal(sample.valid,eligible,JSON.stringify(result.findings));
 if(!eligible){
  const finding=result.findings.find(f=>f.code==='example.serialization.incomplete');assert(finding,JSON.stringify(result.findings));
  assert(finding.details.some(d=>d.detailCode==='runtime.media.unicode.unsupported'),JSON.stringify(finding));assert(finding.range[1]>finding.range[0]);
  assert.equal(finding.resource,root);assert(finding.pointer.endsWith('/examples/Value/serializedValue'));
 }
 // Actual bytes keep their decoder's charset rules; an ineligible authored
 // Unicode serialization must not disable a supported byte representation.
 const actualDocument=document(version,f,{summary:'No serialized proof requested'}),pointer='/paths/~1parts/post/requestBody/content/'+escape(f.contentType);
 const actual=await evaluateSchemas({...input,resources:[{...resources[0],text:render(actualDocument,format)}],runtimeInstances:[{subject:'request-body',location:'body',text:Buffer.from(f.wire).toString('base64'),mediaType:f.contentType,mediaBase64:true,form:{resource:root,pointer},schema:{resource:root,pointer:pointer+'/schema'}}]});
 assert.equal(actual.complete,charset!=='shift_jis',JSON.stringify(actual.runtimeFindings));assert(actual.runtimeEvaluations.length>0);
 assert(actual.runtimeEvaluations.every(v=>v.complete===(charset!=='shift_jis')&&v.valid===(charset!=='shift_jis')),JSON.stringify(actual.runtimeFindings));
 assert.equal(resources[0].text,source);
}
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const kind of ['form','mixed','nested-form','nested-mixed'])for(const charset of ['utf-8','us-ascii','','iso-8859-1','shift_jis'])test(`${version} ${format} ${kind} ${charset||'default'} requires eligible Unicode leaves and preserves actual bytes`,()=>check(version,format,kind,charset));
for(const version of versions.filter(modern))for(const exampleVersion of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const charset of ['utf-8','iso-8859-1'])test(`${version} ${format} referenced ${exampleVersion} MIME example owns Unicode eligibility for ${charset}`,async()=>{
 const f=fixture('form',charset),root='file:///controlled/root.'+format,shared='file:///controlled/examples.'+format;
 const resources=[{id:root,text:render(document(version,f,{$ref:'examples.'+format+'#/components/examples/Actual~1~0'}),format),generation:2},{id:shared,text:render({openapi:exampleVersion,info:{title:'Defining examples',version:'business'},paths:{},components:{examples:{'Actual/~':{serializedValue:f.wire}}}},format),generation:5}];
 const before=resources.map(r=>r.text),result=await evaluateSchemas({root,snapshot:version+exampleVersion+format+charset,resources});
 assert.equal(result.serializedEvaluations.length,1);const sample=result.serializedEvaluations[0];assert.equal(sample.complete,charset==='utf-8');assert.equal(sample.valid,charset==='utf-8');assert.equal(sample.resource,shared);assert.equal(sample.pointer,'/components/examples/Actual~1~0/serializedValue');
 if(charset!=='utf-8'){const finding=result.findings.find(f=>f.code==='example.serialization.incomplete');assert.equal(finding.resource,shared);assert(finding.range[1]>finding.range[0]);}
 assert.deepEqual(resources.map(r=>r.text),before);
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} embedded MIME values retain their existing non-Unicode context`,async()=>{
 const f=fixture('form','iso-8859-1'),root='file:///controlled/embedded.'+format;
 let doc;
 if(version==='2.0')doc={swagger:version,info:{title:'Embedded response',version:'business'},produces:[f.contentType],paths:{'/parts':{get:{responses:{200:{description:'Reply',schema:f.schema,examples:{[f.contentType]:f.wire}}}}}}};
 else doc=document(version,f,{value:f.wire});
 const text=render(doc,format),result=await evaluateSchemas({root,snapshot:version+format,resources:[{id:root,text,generation:3}]});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.serializedEvaluations.length,1);assert(result.serializedEvaluations[0].complete&&result.serializedEvaluations[0].valid,JSON.stringify(result.findings));
});
test('compound Unicode semantics have a distinct captured evaluator identity',()=>{assert.equal(schemaProducer.version,'1.18.0+45');assert(schemaProducer.configuration.includes('compound-unicode-v1'));});

async function transferCheck(version,format,codec,schemaEncoded,opaque,nonAscii=false){
 const root='file:///controlled/transfer.'+format,f=fixture('mixed','iso-8859-1');
 const wire=codec==='base64'?(nonAscii?'Q雪Q==':'QQ=='):codec==='quoted-printable'?'=41':'A';
 const concrete=opaque?'application/octet-stream':'text/plain; charset=iso-8859-1';
 f.schema.items=schemaEncoded?{type:'string',contentEncoding:codec,enum:[wire]}:opaque?{}:{type:'string',enum:['A']};
 f.itemEncoding={contentType:concrete};
 f.wire='--Outer\r\nContent-Type: '+concrete+'\r\nContent-Transfer-Encoding: '+codec+'\r\n\r\n'+wire+'\r\n--Outer--\r\n';
 const source=render(document(version,f,{serializedValue:f.wire}),format),result=await evaluateSchemas({root,snapshot:version+format+codec+schemaEncoded+opaque+nonAscii,resources:[{id:root,text:source,generation:4}]});
 const expected=!nonAscii&&(codec==='base64'||codec==='quoted-printable'||codec==='7bit'),sample=result.serializedEvaluations[0];assert(sample,JSON.stringify(result));
 assert.equal(sample.complete,expected,JSON.stringify(result.findings));assert.equal(sample.valid,expected,JSON.stringify(result.findings));
 if(!expected)assert(result.findings.some(f=>f.code==='example.serialization.incomplete'&&f.details.some(d=>d.detailCode==='runtime.media.unicode.unsupported')),JSON.stringify(result.findings));
}
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json']){
 for(const codec of ['base64','quoted-printable'])for(const schemaEncoded of [false,true])for(const opaque of [false,true])test(`${version} ${format} ${codec} schema-encoded=${schemaEncoded} opaque=${opaque} retains an ASCII MIME serialization`,()=>transferCheck(version,format,codec,schemaEncoded,opaque));
 for(const codec of ['binary','8bit','7bit'])test(`${version} ${format} ${codec} opaque MIME parts need an established Unicode representation`,()=>transferCheck(version,format,codec,false,true));
 test(`${version} ${format} non-ASCII MIME transfer padding has no ASCII serialization proof`,()=>transferCheck(version,format,'base64',false,false,true));
}
