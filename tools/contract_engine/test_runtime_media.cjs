const {test}=require('node:test');
const assert=require('node:assert/strict');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {analyse}=require('./dist/model.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const YAML=require('yaml');
const root='file:///runtime-media/api.json';
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const json of [false,true])for(const [label,bad,status,code,issue]of [
 ['quoted','application/json;profile="','invalid','encoding.content-type','encoding.content-type'],
 ['list','application/json, text/plain','invalid','runtime.media.type','media.type.single'],
 ['repeated','application/json;profile=One;profile=Two','unsupported','request.form.media-parameters.unsupported','request.form.media-parameters.unsupported'],
 ['bounded','application/json;profile="'+'x'.repeat(16384)+'"','unsupported','limit.media.type','limit.media.type'],
])test(`${version} ${json?'JSON':'YAML'} ${label} media stays located without hiding a valid later choice`,()=>{
 const legacy=version==='2.0',id='file:///runtime-media/choices.'+(json?'json':'yaml');
 const content={[bad]:{schema:{}},'application/json':{schema:{}},'application/busy-opaque':{schema:{}}};
 const operation=legacy?{parameters:[{name:'payload',in:'body',schema:{}}],responses:{200:{description:'OK',schema:{}}}}:{requestBody:{content},responses:{200:{description:'OK',content}}};
 const document={...(legacy?{swagger:version,consumes:Object.keys(content),produces:Object.keys(content)}:{openapi:version}),info:{title:'Media choices',version:'1'},paths:{'/p':{post:operation}},
  'x-data':{content:{'literal non-media':{$ref:'payload only'}}},
  ...(version.startsWith('3.2')?{components:{mediaTypes:{Named:{schema:{}}}}}:{})};
 const text=json?JSON.stringify(document):'# Keep 雪\r\n'+YAML.stringify(document),input={root:id,snapshot:'media-choices',resources:[{id,text,generation:3}],resource:id,pointer:'/paths/~1p/post'};
 const projection=requestOperation(input);
 for(const entries of [projection.requestBody.content,projection.responses[0].content]){
  assert.deepEqual(entries.map(value=>value.mediaType),Object.keys(content));
  assert.equal(entries[0].dataModelStatus,status);assert.equal(entries[0].dataModel,undefined);assert.equal(entries[0].dataModelIssue.code,code);
  assert.equal(entries[1].dataModel,'json');assert.equal(entries[1].dataModelStatus,'classified');
  assert.equal(entries[2].dataModel,'opaque');assert.equal(entries[2].dataModelStatus,'opaque');
  assert.equal(entries[0].source.resource,id);
 }
 const analysis=analyse(input);assert.equal(analysis.status,status==='invalid'?'invalid':'incomplete');
 assert.equal(analysis.complete,status==='invalid');
 assert(analysis.findings.some(finding=>finding.code===issue&&finding.resource===id));
 assert(!analysis.findings.some(finding=>finding.pointer.startsWith('/x-data')||finding.pointer.startsWith('/components/mediaTypes/Named')));
 assert.equal(input.resources[0].text,text);
});
function packet(version,schema,{yaml=false,itemSchema}={}){
 const legacy=version==='2.0',at=legacy?'/definitions/Payload':'/components/schemas/Payload';
 const data={...(legacy?{swagger:version}:{openapi:version}),info:{title:'Native media',version:'api-version'},paths:{},[legacy?'definitions':'components']:legacy?{Payload:schema}:{schemas:{Payload:schema,...(itemSchema===undefined?{}:{Item:itemSchema})}}};
 let text=JSON.stringify(data).replaceAll('"EXACT_BIG"','9007199254740993').replaceAll('"EXACT_SMALL"','1e-999');
 const id=yaml?'file:///runtime-media/api.yaml':root;
 if(yaml)text='# Original native YAML\n'+(legacy?'swagger: "2.0"':'openapi: '+version)+'\ninfo: {title: Native media, version: api-version}\npaths: {}\n'+(legacy?'definitions: {Payload: ':'components: {schemas: {Payload: ')+JSON.stringify(schema).replaceAll('"EXACT_BIG"','9007199254740993').replaceAll('"EXACT_SMALL"','1e-999')+(itemSchema===undefined?'':', Item: '+JSON.stringify(itemSchema).replaceAll('"EXACT_BIG"','9007199254740993'))+(legacy?'}':'}}')+'\n';
 return {root:id,snapshot:version+yaml,resources:[{id,text,generation:4}],schema:{resource:id,pointer:at},...(itemSchema===undefined?{}:{itemSchema:{resource:id,pointer:'/components/schemas/Item'}})};
}
async function run(source,mediaType,text,extra={}){
 const result=await evaluateSchemas({...source,runtimeInstances:[{subject:'response-body',location:mediaType,text,mediaType,schema:source.schema,...(source.itemSchema?{itemSchema:source.itemSchema}:{}),...extra}]});
 return {result,valid:result.runtimeEvaluations.every(v=>v.valid===true),findings:result.runtimeFindings};
}
const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
for(const version of versions)for(const yaml of [false,true])test(`${version} ${yaml?'YAML':'JSON'} text media evaluates its actual Unicode string`,async()=>{
 const source=packet(version,{type:'string',minLength:2,maxLength:2,pattern:'^雪😀$'},{yaml});
 const original=source.resources[0].text;
 const positive=await run(source,'text/plain; charset=utf-8',Buffer.from('雪😀').toString('base64'),{mediaBase64:true});
 assert.equal(positive.result.complete,true);assert.equal(positive.valid,true,JSON.stringify(positive.findings));
 const negative=await run(source,'text/plain','snow');assert.equal(negative.result.complete,true);assert.equal(negative.valid,false);
 assert.equal(negative.findings[0].schema.resource,source.root);assert.ok(negative.findings[0].schema.range[1]>0);
 assert.equal(source.resources[0].text,original);
});
for(const version of versions)for(const yaml of [false,true])test(`${version} ${yaml?'YAML':'JSON'} charset labels are case-insensitive`,async()=>{
 const source=packet(version,{type:'string',enum:['雪']},{yaml});
 const result=await run(source,'text/plain; charset=UTF-8',Buffer.from('雪').toString('base64'),{mediaBase64:true});
 assert.equal(result.result.complete,true,JSON.stringify(result.findings));assert.equal(result.valid,true,JSON.stringify(result.findings));
});
for(const version of ['3.0.0','3.0.4','3.1.2','3.2.1'])test(`${version} raw bytes retain family-specific binary interpretation`,async()=>{
 const source=packet(version,{$ref:'binary.json#/Binary'});
 source.resources.push({id:'file:///runtime-media/binary.json',generation:3,text:'{"Binary":{"type":"string","format":"binary","minLength":2,"maxLength":4}}'});
 const positive=await run(source,'application/octet-stream',Buffer.from([0,255,254,10]).toString('base64'),{mediaBase64:true});
 assert.equal(positive.result.complete,true);
 if(version.startsWith('3.0.')){
  assert.equal(positive.valid,true,JSON.stringify(positive.findings));
  for(const bytes of [[0],[0,1,2,3,4]]){const invalid=await run(source,'application/octet-stream',Buffer.from(bytes).toString('base64'),{mediaBase64:true});assert.equal(invalid.result.complete,true);assert.equal(invalid.valid,false);}
 }else{
  assert.equal(positive.valid,false);
  assert(positive.findings.some(f=>f.code==='runtime.schema.incompatible'&&f.keyword==='https://json-schema.org/keyword/type'));
  assert(!positive.findings.some(f=>f.kind==='unsupported'));
 }
});
test('3.0 binary length, enum and pattern use the same exact octet string',async()=>{
 const source=packet('3.0.4',{type:'string',format:'binary',minLength:1,maxLength:1,enum:['ÿ'],pattern:'^ÿ$'});
 assert.equal((await run(source,'image/png','/w==',{mediaBase64:true})).valid,true);
 assert.equal((await run(source,'image/png',Buffer.from('ÿ').toString('base64'),{mediaBase64:true})).valid,false);
});
for(const version of ['3.1.2','3.2.0','3.2.1'])for(const mediaType of ['application/jsonl','application/x-ndjson','application/json-seq','application/geo+json-seq'])test(`${version} ${mediaType} maps finite values to an exact array`,async()=>{
 const source=packet(version,{type:'array',minItems:2,maxItems:2,prefixItems:[{const:'EXACT_BIG'},{const:'EXACT_SMALL'}],items:false});
 const text=mediaType.endsWith('json-seq')?'\x1e9007199254740993\n\x1e\x1e1e-999\n':'9007199254740993\r\n1e-999\n';
 const result=await run(source,mediaType,text);assert.equal(result.result.complete,true);assert.equal(result.valid,true,JSON.stringify(result.findings));
 const invalid=await run(source,mediaType,text.replace('9007199254740993','9007199254740992'));assert.equal(invalid.result.complete,true);assert.equal(invalid.valid,false);
});
for(const mediaType of ['application/jsonl','application/json-seq'])test(`3.2 ${mediaType} applies whole schema and itemSchema independently`,async()=>{
 const source=packet('3.2.1',{type:'array',minItems:2,maxItems:2},{itemSchema:{type:'object',required:['id'],properties:{id:{type:'integer',minimum:'EXACT_BIG'}}}});
 const frame=value=>mediaType==='application/jsonl'?value+'\n':'\x1e'+value+'\n';
 const positive=await run(source,mediaType,frame('{"id":9007199254740993}')+frame('{"id":9007199254740994}'));
 assert.equal(positive.result.complete,true);assert.equal(positive.valid,true,JSON.stringify(positive.findings));assert.equal(positive.result.runtimeEvaluations.length,3);
 const invalid=await run(source,mediaType,frame('{"id":9007199254740993}')+frame('{}'));
 assert.equal(invalid.result.complete,true);assert.equal(invalid.valid,false);assert.ok(invalid.findings.some(f=>f.pointer==='/1'&&f.schema.pointer==='/components/schemas/Item'));
 const whole=await run(source,mediaType,frame('{"id":9007199254740993}'));assert.equal(whole.result.complete,true);assert.equal(whole.valid,false);
});
for(const [mediaType,text] of [['application/jsonl','1,2\n'],['application/jsonl','1\n\n2\n'],['application/jsonl','\ufeff1\n'],['application/x-ndjson','1\r2\n'],['application/json-seq','1\n'],['application/json-seq','\x1e1'],['application/json-seq','\x1efalse'],['application/jsonl','{"duplicate":1,"duplicate":2}\n']])test(`invalid ${mediaType} framing cannot become successful array validation: ${JSON.stringify(text)}`,async()=>{
 const source=packet('3.2.1',{type:'array'});const result=await run(source,mediaType,text);assert.equal(result.result.complete,true);assert.equal(result.valid,false);assert.ok(result.findings.some(f=>f.code==='runtime.body.syntax'));
});
test('SSE dispatch framing preserves typed fields, exact retry, multiline data and ignored payload',async()=>{
 const source=packet('3.2.1',{type:'array',minItems:2,maxItems:2},{itemSchema:{type:'object',required:['data'],properties:{retry:{const:'EXACT_BIG'}},additionalProperties:{type:'string'}}});
 const text='\ufeff: comment\r\nevent: add\r\ndata: 雪\r\ndata: 😀\r\nretry: 0009007199254740993\r\nid: first\r\nunknown: ignored\r\n\r\ndata:\rid: bad\0id\rretry: +1\r\rdata: unfinished';
 const result=await run(source,'text/event-stream; charset=iso-8859-1',Buffer.from(text).toString('base64'),{mediaBase64:true});
 assert.equal(result.result.complete,true);assert.equal(result.valid,true,JSON.stringify(result.findings));assert.equal(result.result.runtimeEvaluations.length,3);
 const invalid=await run(source,'text/event-stream',text.replace('0009007199254740993','9007199254740992'));assert.equal(invalid.result.complete,true);assert.equal(invalid.valid,false);
});
test('SSE UTF-8 replacement decoding is used before schema evaluation',async()=>{
 const source=packet('3.2.1',{type:'array',prefixItems:[{properties:{data:{const:'�'}}}],minItems:1,maxItems:1});
 const bytes=Buffer.from([100,97,116,97,58,32,255,10,10]);const result=await run(source,'text/event-stream',bytes.toString('base64'),{mediaBase64:true});assert.equal(result.result.complete,true);assert.equal(result.valid,true);
});
test('sequence work limits and unimplemented media stay explicitly incomplete',async()=>{
 const source=packet('3.2.1',{type:'array'});
 const limited=await run(source,'application/jsonl','0\n'.repeat(2049));assert.equal(limited.result.complete,false);assert.equal(limited.valid,false);assert.ok(limited.findings.some(f=>f.code==='runtime.body.limit'));
 const unknown=await run(source,'application/xml','<item/>');assert.equal(unknown.result.complete,false);assert.ok(unknown.findings.some(f=>f.kind==='unsupported'&&f.reason==='unsupported-representation'));
});
test('runtime media metadata comes from the production operation projection',()=>{
 const value={openapi:'3.2.1',info:{title:'Native',version:'1'},paths:{'/stream':{post:{requestBody:{content:{'application/jsonl':{itemSchema:true}}},responses:{200:{description:'ok',content:{'text/event-stream':{itemSchema:true},'image/*':{}}}}}}}};
 const source={root,snapshot:'metadata',resources:[{id:root,generation:1,text:JSON.stringify(value)}]};const op=analyse(source).operations[0];const result=requestOperation({...source,resource:root,pointer:op.pointer,occurrence:op.occurrence});
 assert.equal(result.requestBody.content[0].dataModel,'json-lines');assert.equal(result.responses[0].content[0].dataModel,'event-stream');assert.equal(result.responses[0].content[1].dataModel,'opaque');
});
test('SSE removes exactly one leading BOM and normalizes an explicit empty event type',async()=>{
 const empty=packet('3.2.1',{type:'array',maxItems:0});
 const doubled=await run(empty,'text/event-stream',Buffer.from('\ufeff\ufeffdata: ignored field\n\n').toString('base64'),{mediaBase64:true});
 assert.equal(doubled.result.complete,true);assert.equal(doubled.valid,true,JSON.stringify(doubled.findings));
 const message=packet('3.2.1',{type:'array',minItems:1,maxItems:1,prefixItems:[{properties:{event:{const:'message'},data:{const:''}},required:['event','data']}]});
 const result=await run(message,'text/event-stream','event:\ndata:\n\n');assert.equal(result.result.complete,true);assert.equal(result.valid,true,JSON.stringify(result.findings));
});
test('repeated media parameters retain unsupported interpretation rather than a fabricated syntax violation',async()=>{
 const source=packet('3.0.4',{type:'string'});const result=await run(source,'text/plain; profile=a; profile=b','literal');
 assert.equal(result.result.complete,false);assert.ok(result.findings.some(f=>f.kind==='unsupported'&&f.code==='runtime.response.body.unchecked'&&f.schema.resource===source.root));
 assert.ok(result.findings.every(f=>f.severity!=='error'));
});
