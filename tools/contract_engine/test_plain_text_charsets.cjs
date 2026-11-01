const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {evaluateSchemas,schemaProducer}=require('./dist/schema_evaluation.cjs');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function render(value,format){
 return (format==='yaml'?'# Keep 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value))
  .replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
}
function api(version){return {...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Original',version:'business'},paths:{},'x-number':'EXACT'};}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} actual plain-text octets honor default and explicit charsets`,async()=>{
 const document=api(version),legacy=version==='2.0',root='file:///controlled/text.'+format;
 if(legacy)document.definitions={Text:{type:'string'}};else document.components={schemas:{Text:{type:'string'}}};
 const resources=[{id:root,text:render(document,format),generation:7}],before=resources[0].text;
 const schema={resource:root,pointer:legacy?'/definitions/Text':'/components/schemas/Text'};
 for(const [mediaType,bytes,complete,valid]of [
  ['text/plain',Buffer.from('false'),true,true],['text/plain',Buffer.alloc(0),true,true],
  ['text/plain',Buffer.from('café'),true,false],['text/plain',Buffer.from([0xe9]),true,false],
  ['text/plain; charset=utf-8',Buffer.from('雪😀'),true,true],
  ['text/plain; charset=utf-8',Buffer.from([0xff]),true,false],
  ['text/plain; charset=iso-8859-1',Buffer.from([0,0x80,0x9f,0xff]),true,true],
  ['text/plain; charset=latin1',Buffer.from([0xe9]),true,true],
  ['text/plain; charset=us-ascii',Buffer.from([0xff]),true,false],
  ['text/plain; charset=shift_jis',Buffer.from('false'),false,false],
 ]){
  const text=bytes.toString('base64'),runtimeInstances=[{subject:'response-body',location:'text',mediaType,mediaBase64:true,text,schema}];
  const result=await evaluateSchemas({root,snapshot:version+format,resources,runtimeInstances});
  assert.equal(result.complete,complete,JSON.stringify({mediaType,result}));
  assert.equal(result.runtimeEvaluations.length,1);assert.equal(result.runtimeEvaluations[0].valid,valid,JSON.stringify(result));
  if(!valid)assert(result.runtimeFindings.some(value=>complete?value.code==='runtime.body.syntax':value.kind==='unsupported'),JSON.stringify(result.runtimeFindings));
  assert.equal(runtimeInstances[0].text,text);assert.equal(resources[0].text,before);
 }
});
for(const version of versions.filter(value=>value.startsWith('3.1')||value.startsWith('3.2')))for(const format of ['yaml','json'])test(`${version} ${format} referenced Unicode examples retain charset eligibility and provenance`,async()=>{
 const root='file:///controlled/examples-root.'+format,shared='file:///controlled/shared.'+format;
 const document=api(version),examples={};
 const cases=[
  ['DefaultASCII','text/plain','false',true,true],['DefaultUnicode','text/plain','café',true,false],
  ['ASCIIUnicode','text/plain; charset=us-ascii','café',true,false],
  ['Latin1','text/plain; charset=iso-8859-1','café',false,false],
  ['UTF8','text/plain; charset=utf-8','雪😀',true,true],
  ['Unknown','text/plain; charset=shift_jis','false',false,false],
 ];
 document.paths['/text']={get:{responses:{200:{description:'Text',content:Object.fromEntries(cases.map(([name,mediaType])=>[mediaType,{schema:{type:'string'},examples:{[name]:{$ref:'shared.'+format+'#/components/examples/'+name}}}]))}}}};
 // Distinct content owners are needed for the two default-charset examples.
 document.paths['/text'].get.responses[200].content['text/plain'].examples={DefaultASCII:{$ref:'shared.'+format+'#/components/examples/DefaultASCII'},DefaultUnicode:{$ref:'shared.'+format+'#/components/examples/DefaultUnicode'}};
 for(const [name,,text]of cases)examples[name]={serializedValue:text};
 const resources=[{id:root,text:render(document,format),generation:2},{id:shared,text:render({...api('3.2.1'),components:{examples}},format),generation:3}],before=resources.map(value=>value.text);
 const result=await evaluateSchemas({root,snapshot:version+format,resources});
 assert.equal(result.complete,false);assert.equal(result.serializedEvaluations.length,cases.length);
 for(const [name,,text,complete,valid]of cases){
  const pointer='/components/examples/'+name+'/serializedValue',value=result.serializedEvaluations.find(value=>value.pointer===pointer);
  assert(value,name);assert.equal(value.resource,shared);assert.equal(value.complete,complete,name);assert.equal(value.valid,valid,name);
  if(!valid){const finding=result.findings.find(value=>value.resource===shared&&value.pointer===pointer);assert(finding,name);assert.equal(finding.severity,'warning');assert(finding.range[1]>finding.range[0]);assert(resources[1].text.slice(...finding.range).includes(text));}
 }
 assert.deepEqual(resources.map(value=>value.text),before);
});
function wire(port,path){return new Promise((resolve,reject)=>{
 const request=http.request({host:'127.0.0.1',port,path,method:'GET'},response=>{const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.on('error',reject);response.on('end',()=>resolve({status:response.statusCode,headers:response.headers,bytes:Buffer.concat(chunks)}));});
 request.on('error',reject);request.end();
});}
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} generated and proxy text preserve actual byte encodings`,{timeout:30000},async t=>{
 const document=api(version),legacy=version==='2.0',root='file:///controlled/mock.'+format;
 const cases=[['bare','text/plain','café','text/plain; charset=utf-8',Buffer.from('café')],
  ['latin','text/plain; charset=iso-8859-1','café','text/plain; charset=iso-8859-1',Buffer.from('café','latin1')],
  ['utf8','text/plain; charset=utf-8','雪😀','text/plain; charset=utf-8',Buffer.from('雪😀')],
  ['ascii','text/plain','false','text/plain',Buffer.from('false')]];
 for(const [name,mediaType,text]of cases){const schema={type:'string',enum:[text]};document.paths['/'+name]={get:{...(legacy?{produces:[mediaType]}:{}),responses:{200:{description:'Text',...(legacy?{schema,examples:{[mediaType]:text}}:{content:{[mediaType]:{schema,example:text}}})}}}};}
 for(const [name,mediaType,text]of [['invalid-ascii','text/plain; charset=us-ascii','café'],['invalid-latin','text/plain; charset=iso-8859-1','€']]){
  const schema={type:'string',enum:[text]};document.paths['/'+name]={get:{...(legacy?{produces:[mediaType]}:{}),responses:{200:{description:'Unencodable',...(legacy?{schema,examples:{[mediaType]:text}}:{content:{[mediaType]:{schema,example:text}}})}}}};
 }
 const input=mockStart(render(document,format),{},root),before=JSON.stringify(input.capture),{port}=await startMock(t,input);
 for(const [name,,,mediaType,bytes]of cases){const response=await wire(port,'/'+name);assert.equal(response.status,200,response.bytes.toString());assert.equal(response.headers['content-type'],mediaType);assert.deepEqual(response.bytes,bytes);assert.equal(response.headers['busyapi-response-validation-complete'],'true');assert.deepEqual(JSON.parse(response.headers['sl-violations']??'[]'),[]);}
 for(const name of ['invalid-ascii','invalid-latin']){
  const response=await wire(port,'/'+name),problem=JSON.parse(response.bytes.toString());
  assert.equal(response.status,500,JSON.stringify(problem));assert.equal(problem.complete,false);assert.equal(response.headers['busyapi-response-validation-complete'],'false');
  assert(problem.findings.some(value=>value.code==='runtime.media.charset'&&value.source.resource===root&&value.source.pointer==='/paths/~1'+name+'/get'&&value.source.range[1]>value.source.range[0]),JSON.stringify(problem));
 }
 const upstream=http.createServer((request,response)=>{const item=cases.find(([name])=>request.url==='/'+name);response.setHeader('content-type',item[1]);response.end(item[4]);});
 await new Promise((resolve,reject)=>{upstream.once('error',reject);upstream.listen(0,'127.0.0.1',resolve);});
 t.after(()=>new Promise(resolve=>{upstream.closeAllConnections();upstream.close(resolve);}));
 const proxy=await startMock(t,mockStart(render(document,format),{upstream:'http://127.0.0.1:'+upstream.address().port},root));
 for(const [name,mediaType,,,bytes]of cases){const response=await wire(proxy.port,'/'+name);assert.equal(response.status,200);assert.equal(response.headers['content-type'],mediaType);assert.deepEqual(response.bytes,bytes);assert.equal(response.headers['busyapi-response-validation-complete'],'true');const findings=JSON.parse(response.headers['sl-violations']??'[]');if(name==='bare')assert(findings.some(value=>value.code==='runtime.body.syntax'),JSON.stringify(findings));else assert.deepEqual(findings,[]);}
 assert.equal(JSON.stringify(input.capture),before);
});
test('plain-text evaluation has a revised captured identity',()=>{assert.equal(schemaProducer.version,'1.18.0+45');assert(schemaProducer.configuration.includes('runtime-media-v3'));assert(schemaProducer.configuration.includes('form-context-v2'));});
test('text serialization context is bounded and requires a Unicode string instance',async()=>{
 const root='file:///controlled/protocol.json',resources=[{id:root,text:JSON.stringify(api('3.2.1')),generation:1}];
 for(const extra of [{textSerialization:'other',unicodeSerialization:true},{textSerialization:true,unicodeSerialization:true},{textSerialization:'embedded'},{textSerialization:'unicode',unicodeSerialization:false},{textSerialization:'embedded',unicodeSerialization:true,mediaBase64:true}]){
  await assert.rejects(evaluateSchemas({root,snapshot:'protocol',resources,runtimeInstances:[{subject:'request-body',location:'text',text:'false',mediaType:'text/plain',...extra}]}),error=>error.code==='runtime.instance');
 }
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} form fields retain their explicit UTF-8 context`,async()=>{
 const document=api(version),legacy=version==='2.0',root='file:///controlled/form-text.'+format;
 const schema={type:'object',properties:{value:{type:'string',enum:['雪😀']}}},types=['multipart/form-data','application/x-www-form-urlencoded'];
 document.paths['/parts']={post:{...(legacy?{consumes:types,parameters:[{in:'formData',name:'value',type:'string',enum:['雪😀']}]}:{requestBody:{content:Object.fromEntries(types.map(type=>[type,{schema:structuredClone(schema)}]))}}),responses:{204:{description:'None'}}}};
 const resources=[{id:root,text:render(document,format),generation:5}],original=resources[0].text;
 const wires=[...['', 'Content-Type: text/plain\r\n'].map(header=>['multipart/form-data; boundary=Charset','--Charset\r\nContent-Disposition: form-data; name="value"\r\n'+header+'\r\n雪😀\r\n--Charset--\r\n']),['application/x-www-form-urlencoded','value='+encodeURIComponent('雪😀')]];
 for(const [mediaType,wire]of wires){
  const at='/paths/~1parts/post'+(legacy?'':'/requestBody/content/'+mediaType.split(';')[0].replaceAll('/','~1'));
  const result=await evaluateSchemas({root,snapshot:version+format,resources,runtimeInstances:[{subject:'request-body',location:'form',text:Buffer.from(wire).toString('base64'),mediaType,mediaBase64:true,form:{resource:root,pointer:at},...(!legacy?{schema:{resource:root,pointer:at+'/schema'}}:{})}]});
  assert.equal(result.complete,true,JSON.stringify(result.runtimeFindings));assert(result.runtimeEvaluations.length>0);
  assert(result.runtimeEvaluations.every(value=>value.valid===true),JSON.stringify({mediaType,findings:result.runtimeFindings}));
 }
 assert.equal(resources[0].text,original);
});
