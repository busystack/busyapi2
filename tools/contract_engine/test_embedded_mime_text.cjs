const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {evaluateSchemas,schemaProducer}=require('./dist/schema_evaluation.cjs');
const {requestMimeTextBytes}=require('./dist/execution.cjs');
const YAML=require('yaml');
const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const escape=s=>s.replaceAll('~','~0').replaceAll('/','~1');
const render=(v,format)=>(format==='yaml'?'# Keep embedded MIME source\r\n'+YAML.stringify(v).replaceAll('\n','\r\n'):JSON.stringify(v)+'\r\n').replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
for(const version of versions)for(const format of ['yaml','json'])for(const charset of ['utf-8','iso-8859-1'])test(`${version} ${format} embedded MIME ${charset} uses the same character policy as standalone text`,async()=>{
 const legacy=version==='2.0',root='file:///controlled/embedded.'+format,mediaType='multipart/form-data; boundary=Literal';
 const schema={type:'object',required:['label'],properties:{label:{type:'string',enum:['café']}}};
 const wire='--Literal\r\nContent-Disposition: form-data; name="label"\r\nContent-Type: text/plain; charset='+charset+'\r\n\r\ncafé\r\n--Literal--\r\n';
 const content={schema,encoding:{label:{contentType:'text/plain; charset='+charset}},examples:{Value:{value:wire}}};
 const value={...legacy?{swagger:version,produces:[mediaType]}:{openapi:version},info:{title:'Original embedded MIME',version:'business'},paths:{'/data':{[legacy?'get':'post']:{...legacy?{}:{requestBody:{content:{[mediaType]:content}}},responses:{200:{description:'Reply',...legacy?{schema,examples:{[mediaType]:wire}}:{}}}}}},'x-number':'EXACT'};
 const source=render(value,format),input={root,snapshot:version+format+charset,resources:[{id:root,text:source,generation:4}]};
 const pointer='/paths/~1data/'+(legacy?'get/responses/200':'post/requestBody/content/'+escape(mediaType));
 const actualDocument=structuredClone(value);
 if(legacy)delete actualDocument.paths['/data'].get.responses[200].examples;
 else actualDocument.paths['/data'].post.requestBody.content[mediaType].examples={Value:{summary:'No authored string witness'}};
 const bytes=Buffer.from(wire,charset==='iso-8859-1'?'latin1':'utf8');
 const actual=await evaluateSchemas({...input,resources:[{...input.resources[0],text:render(actualDocument,format)}],runtimeInstances:[{subject:legacy?'response-body':'request-body',location:'body',text:bytes.toString('base64'),mediaType,mediaBase64:true,form:{resource:root,pointer},schema:{resource:root,pointer:pointer+'/schema'}}]});
 assert.equal(actual.complete,true,JSON.stringify(actual.runtimeFindings));assert(actual.runtimeEvaluations.length>0);assert(actual.runtimeEvaluations.every(v=>v.complete&&v.valid),JSON.stringify(actual.runtimeFindings));
 const authored=await evaluateSchemas(input);assert.equal(authored.complete,true,JSON.stringify(authored.findings));assert.equal(authored.serializedEvaluations.length,1);
 assert.equal(authored.serializedEvaluations[0].valid,true,JSON.stringify(authored.findings));
 assert.equal(input.resources[0].text,source);
});

const mimeType='multipart/form-data; boundary=Wire';
const frame=(headers,body,boundary='Wire')=>'--'+boundary+'\r\n'+headers+'\r\n\r\n'+body+'\r\n--'+boundary+'--\r\n';
const header=charset=>'Content-Disposition: form-data; name="label"\r\nContent-Type: text/plain; charset='+charset;
const prepare=(text,mediaType=mimeType)=>requestMimeTextBytes({snapshot:'captured-wire',text,mediaType});
const materialize=(text,mediaType=mimeType)=>Buffer.from(prepare(text,mediaType).base64,'base64');
for(const [charset,codec]of [['utf-8','utf8'],['UTF-8','utf8'],['iso-8859-1','latin1'],['ISO-8859-1','latin1'],['latin1','latin1']])test('wire bytes use the declared leaf charset '+charset,()=>{
 const text=frame(header(charset),'café\0ÿ'),result=prepare(text),bytes=Buffer.from(result.base64,'base64');
 const expected=Buffer.concat([Buffer.from('--Wire\r\n'+header(charset)+'\r\n\r\n'),Buffer.from('café\0ÿ',codec),Buffer.from('\r\n--Wire--\r\n')]);
 assert.deepEqual(bytes,expected);assert.equal(result.byteLength,expected.length);
 assert.equal(result.version,1);assert.equal(result.revision,'1');assert.equal(result.snapshot,'captured-wire');assert.equal(result.mediaType,mimeType);
 assert.equal(result.mode,'encoded');assert(!Object.hasOwn(result,'problem'));
 assert.equal(result.input,createHash('sha256').update(text).digest('hex'));
});
test('mixed MIME leaves preserve distinct charsets, headers and exact numeric JSON bytes',()=>{
 const first='--Wire\r\n'+header('iso-8859-1')+'\r\n\r\n';
 const middle='\r\n--Wire\r\nContent-Disposition: form-data; name="data"\r\nContent-Type: application/json\r\n\r\n';
 const json='{"n":9007199254740993.00,"zero":0,"null":null,"false":false,"empty":"","text":"雪😀","$ref":"literal.json"}';
 const end='\r\n--Wire--\r\n';
 const text=first+'café'+middle+json+end;
 assert.deepEqual(materialize(text),Buffer.concat([Buffer.from(first),Buffer.from([99,97,102,233]),Buffer.from(middle+json+end)]));
});
test('nested MIME byte spans retain Unicode preamble, epilogue and framing',()=>{
 const first='雪 preamble\r\n--Outer\r\nContent-Type: multipart/mixed; boundary=Inner\r\n\r\n--Inner\r\nContent-Type: text/plain; charset=iso-8859-1\r\nX-Keep: spelling\r\n\r\n';
 const last='\r\n--Inner--\r\n\r\n--Outer--\r\n😀 epilogue';
 const text=first+'café'+last;
 assert.deepEqual(materialize(text,'multipart/mixed; boundary=Outer'),Buffer.concat([Buffer.from(first),Buffer.from([99,97,102,233]),Buffer.from(last)]));
});
test('multiple replacements retain original byte offsets across nesting',()=>{
 const first='--Wire\r\n'+header('iso-8859-1')+'\r\n\r\n';
 const middle='\r\n--Wire\r\nContent-Disposition: form-data; name="nested"\r\nContent-Type: multipart/mixed; boundary=Nested\r\n\r\n--Nested\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\n';
 const end='\r\n--Nested--\r\n\r\n--Wire--\r\n';
 const text=first+'café'+middle+'naïve'+end;
 assert.deepEqual(materialize(text),Buffer.concat([Buffer.from(first),Buffer.from([99,97,102,233]),Buffer.from(middle),Buffer.from([110,97,239,118,101]),Buffer.from(end)]));
});
for(const [transfer,body]of [['base64','Y2Fm6Q=='],['quoted-printable','caf=E9']])test('ASCII '+transfer+' wire representation is never transcoded',()=>{
 const text=frame(header('iso-8859-1')+'\r\nContent-Transfer-Encoding: '+transfer,body);
 assert.deepEqual(materialize(text),Buffer.from(text));
});
test('default form-data text is UTF8 and generic text retains its ASCII default',()=>{
 const form=frame('Content-Disposition: form-data; name="label"','雪😀');
 assert.deepEqual(materialize(form),Buffer.from(form));
 const generic=frame('Content-Type: text/plain','ASCII','Generic');
 assert.deepEqual(materialize(generic,'multipart/mixed; boundary=Generic'),Buffer.from(generic));
 assert.throws(()=>materialize(frame('Content-Type: text/plain','café','Generic'),'multipart/mixed; boundary=Generic'),error=>error.code==='runtime.media.charset');
});
for(const [charset,value,code]of [['iso-8859-1','雪','runtime.media.charset'],['us-ascii','é','runtime.media.charset'],['utf-16','value','runtime.media.unsupported']])test('unrepresentable or unsupported leaf text fails precisely '+charset,()=>{
 const text=frame(header(charset),value);
 assert.throws(()=>materialize(text),error=>error.code===code);
 assert.equal(text,frame(header(charset),value));
});
test('opaque body text and zero-byte leaf values retain their existing bytes',()=>{
 const opaque=frame('Content-Disposition: form-data; name="file"\r\nContent-Type: application/octet-stream','é\0');
 assert.deepEqual(materialize(opaque),Buffer.from(opaque));
 const empty=frame(header('iso-8859-1'),'');assert.deepEqual(materialize(empty),Buffer.from(empty));
});
test('unknown transfer semantics refuse preparation and malformed raw MIME stays explicitly invalid',()=>{
 assert.throws(()=>materialize(frame(header('utf-8')+'\r\nContent-Transfer-Encoding: unknown','body')),error=>error.code==='runtime.mime-text.transfer.unsupported'&&error.kind==='unsupported');
 const invalid=prepare('not a MIME entity');assert.equal(invalid.mode,'literal-invalid');assert.equal(invalid.problem.code,'runtime.form.syntax');
 assert.deepEqual(Buffer.from(invalid.base64,'base64'),Buffer.from('not a MIME entity'));
});
test('a late framing failure preserves the whole literal input without partial transcoding',()=>{
 const first='--Wire\r\n'+header('iso-8859-1')+'\r\n\r\ncafé\r\n';
 const nested='--Wire\r\nContent-Disposition: form-data; name="nested"\r\nContent-Type: multipart/mixed; boundary=Broken\r\n\r\n--Broken\r\nContent-Type: text/plain\r\n\r\nunfinished\r\n--Wire--\r\n';
 const text=first+nested,result=prepare(text);
 assert.equal(result.mode,'literal-invalid');assert.equal(result.problem.code,'runtime.form.syntax');
 assert.deepEqual(Buffer.from(result.base64,'base64'),Buffer.from(text));
 const unknown=first+'--Wire\r\n'+header('utf-8')+'\r\nContent-Transfer-Encoding: unknown\r\n\r\nvalue\r\n--Wire--\r\n';
 assert.throws(()=>prepare(unknown),error=>error.code==='runtime.mime-text.transfer.unsupported');
});
test('embedded MIME changes own a distinct evaluator identity',()=>{
 assert.equal(schemaProducer.version,'1.18.0+44');
 assert(schemaProducer.configuration.includes('embedded-mime-text-v1'));
 assert(schemaProducer.configuration.includes('compound-unicode-v1'));
});
test('nested MIME limits are explicit and retain the last supported depth',()=>{
 let text=frame('Content-Type: text/plain; charset=utf-8','A','Depth0'),type='multipart/mixed; boundary=Depth0';
 for(let depth=1;depth<=8;depth++){
  text=frame('Content-Type: '+type,text,'Depth'+depth);type='multipart/mixed; boundary=Depth'+depth;
 }
 assert.deepEqual(materialize(text,type),Buffer.from(text));
 text=frame('Content-Type: '+type,text,'TooDeep');
 assert.throws(()=>prepare(text,'multipart/mixed; boundary=TooDeep'),error=>error.code==='limit.runtime.mime-text.depth');
});
test('total MIME part work is bounded independently of per-container limits',()=>{
 let text='';
 for(let group=0;group<128;group++){
  const boundary='Group'+group;
  let child='';for(let item=0;item<128;item++)child+='--'+boundary+'\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nA\r\n';
  child+='--'+boundary+'--\r\n';
  text+='--Total\r\nContent-Type: multipart/mixed; boundary='+boundary+'\r\n\r\n'+child+'\r\n';
 }
 text+='--Total--\r\n';
 assert.throws(()=>prepare(text,'multipart/mixed; boundary=Total'),error=>error.code==='limit.runtime.mime-text.parts');
});
test('MIME text budget measures UTF8 bytes rather than UTF16 string length',()=>{
 assert.throws(()=>prepare('é'.repeat(32*1024*1024+1)),error=>error.code==='limit.runtime.mime-text');
});
test('unpaired surrogate data is refused without literal-byte fallback',()=>{
 assert.throws(()=>prepare(frame(header('utf-8'),'A\ud800')),error=>error.code==='runtime.media.encoding');
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const charset of ['utf-8','iso-8859-1'])test(`${version} ${format} serializedValue retains its strict Unicode rule for ${charset}`,async()=>{
 const root='file:///controlled/strict.'+format,wire=frame(header(charset),'café');
 const document={openapi:version,info:{title:'Strict serialization',version:'business'},paths:{'/data':{post:{
  requestBody:{content:{[mimeType]:{schema:{type:'object',required:['label'],properties:{label:{type:'string',enum:['café']}}},encoding:{label:{contentType:'text/plain; charset='+charset}},examples:{Value:{serializedValue:wire}}}}},
  responses:{200:{description:'Reply'}},
 }}}};
 const source=render(document,format),resources=[{id:root,text:source,generation:3}];
 const result=await evaluateSchemas({root,snapshot:version+format+charset,resources}),sample=result.serializedEvaluations[0],eligible=charset==='utf-8';
 assert.equal(sample.complete,eligible,JSON.stringify(result.findings));assert.equal(sample.valid,eligible,JSON.stringify(result.findings));
 if(!eligible){
  const finding=result.findings.find(value=>value.code==='example.serialization.incomplete');assert(finding);
  assert(finding.details.some(detail=>detail.detailCode==='runtime.media.unicode.unsupported'));
  assert.equal(finding.resource,root);assert(finding.pointer.endsWith('/serializedValue'));assert(finding.range[1]>finding.range[0]);
 }
 assert.equal(resources[0].text,source);
});
