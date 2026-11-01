const {test}=require('node:test');
const assert=require('node:assert/strict');
const net=require('node:net');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const {capturedMockStart,startMock}=require('./mock_test_capture.cjs');

function wire(port,method,path,headers={},body='') {
 return new Promise((resolve,reject)=>{
  const socket=net.connect({host:'127.0.0.1',port});
  const chunks=[];
  socket.setTimeout(8000,()=>socket.destroy(Error('Synthetic method request timed out')));
  socket.once('error',reject);
  socket.on('data',chunk=>chunks.push(chunk));
  socket.once('end',()=>{
   const bytes=Buffer.concat(chunks),at=bytes.indexOf('\r\n\r\n');
   if(at<0)return reject(Error(`The mock omitted a complete HTTP response for ${method}`));
   const lines=bytes.subarray(0,at).toString('latin1').split('\r\n');
   const status=/^HTTP\/1\.[01] (\d{3}) /.exec(lines.shift());
   if(!status)return reject(Error('The mock omitted an HTTP status'));
   const fields=Object.create(null);
   for(const line of lines){const colon=line.indexOf(':');fields[line.slice(0,colon).toLowerCase()]=line.slice(colon+1).trim();}
   const payload=bytes.subarray(at+4);
   if(fields['content-length']!==undefined)assert.equal(payload.length,Number(fields['content-length']));
   resolve({status:Number(status[1]),headers:fields,bytes:payload,text:payload.toString('utf8')});
  });
  socket.once('connect',()=>socket.write([
   `${method} ${path} HTTP/1.1`, 'Host: 127.0.0.1', 'Connection: close',
   ...Object.entries(headers).map(([name,value])=>`${name}: ${value}`),
   ...(body?['Content-Type: application/json',`Content-Length: ${Buffer.byteLength(body)}`]:[]),
   '',body,
  ].join('\r\n')));
 });
}

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} native mock methods retain case, shared owners and exact bodies`,{timeout:35000},async t=>{
 const root=`file:///custom-mock/api.${format}`,part=`file:///custom-mock/paths.${format}`;
 const custom=['get','post','gEt','trace','CuStOm','__proto__','constructor','X~Task'];
 const fixed=['GET','POST','TRACE','QUERY'];
 const operation=(method,body)=>({
  security:[{Key:[]}],
  ...(body?{requestBody:{required:true,content:{'application/json':{schema:{
   type:'object',required:['method','number'],properties:{method:{const:method},number:{const:'EXACT'}},additionalProperties:false,
  }}}}}:{}),
  responses:{
   200:{description:'Selected original operation',content:{'application/json':{
    schema:{type:'object',required:['method','number']},
    example:{method,number:'EXACT',empty:'',flag:false,$ref:'literal'},
   }}},
   401:{description:'Security rejected'},422:{description:'Input rejected'},
  },
 });
 const shared={Path:{
  parameters:[{name:'id',in:'path',required:true,schema:{type:'integer',const:'EXACT'}}],
  ...Object.fromEntries(fixed.map(method=>[method.toLowerCase(),operation(method,['POST','QUERY'].includes(method))])),
  additionalOperations:Object.fromEntries(custom.map(method=>[method,operation(method,true)])),
 }};
 const document={openapi:version,info:{title:'Native methods',version:'api-version'},
  components:{securitySchemes:{Key:{type:'apiKey',in:'header',name:'X-Key'}}},
  paths:Object.fromEntries(['/work/{id}','/mirror/{id}'].map(path=>[path,{$ref:`paths.${format}#/Path`}]))};
 const encode=value=>(format==='yaml'?YAML.stringify(value):JSON.stringify(value)).replaceAll(format==='yaml'?'EXACT':'"EXACT"','9007199254740993.00');
 const capture={root,snapshot:'0'.repeat(64),resources:[{id:root,text:encode(document)},{id:part,text:encode(shared)}].map(value=>({
  ...value,generation:1,identity:createHash('sha256').update(value.text).digest('hex'),
 }))};
 const original=JSON.stringify(capture),ready=await startMock(t,capturedMockStart(capture));
 assert.equal(ready.operations,24);
 for(const method of [...fixed,...custom]){
  const body=['GET','TRACE'].includes(method)?'':`{"method":${JSON.stringify(method)},"number":9007199254740993.00}`;
  const response=await wire(ready.port,method,'/work/9007199254740993',{'X-Key':'synthetic'},body);
  assert.equal(response.status,200,response.text);
  assert.equal(JSON.parse(response.text).method,method,response.text);
  assert.ok(response.text.includes('9007199254740993.00'),response.text);
  assert.equal(response.headers['sl-violations'],undefined);
  assert.equal(response.headers['busyapi-response-validation-complete'],'true');
 }
 const valid='{"method":"get","number":9007199254740993.00}';
 assert.equal((await wire(ready.port,'get','/mirror/9007199254740993',{'X-Key':'synthetic'},valid)).status,200);
 const bad=await wire(ready.port,'get','/work/9007199254740993',{'X-Key':'synthetic'},valid.replace('9007199254740993','9007199254740992'));
 assert.equal(bad.status,422,bad.text);
 assert.ok(JSON.parse(bad.headers['sl-violations']).some(value=>value.source.resource===part&&value.source.pointer.startsWith('/Path/additionalOperations/get/')));
 assert.equal((await wire(ready.port,'get','/work/9007199254740993',{},valid)).status,401);
 assert.equal((await wire(ready.port,'GeT','/work/9007199254740993',{'X-Key':'synthetic'},valid)).status,405);
 assert.equal((await wire(ready.port,'get','/absent',{'X-Key':'synthetic'},valid)).status,404);
 assert.equal(JSON.stringify(capture),original);
});

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} native custom proxy preserves method, target, body and encoded response bytes`,{timeout:35000},async t=>{
 const calls=[],sockets=new Set();
 const plain=Buffer.from('{"number":9007199254740993.00,"text":"雪"}');
 const {gzipSync}=require('node:zlib');
 const upstream=net.createServer(socket=>{
  sockets.add(socket);socket.once('close',()=>sockets.delete(socket));
  let bytes=Buffer.alloc(0),done=false;
  socket.on('data',chunk=>{
   if(done)return;bytes=Buffer.concat([bytes,chunk]);const at=bytes.indexOf('\r\n\r\n');if(at<0)return;
   const head=bytes.subarray(0,at).toString('latin1'),length=Number(/\r\ncontent-length:\s*(\d+)/i.exec('\r\n'+head)?.[1]??0);
   if(bytes.length<at+4+length)return;done=true;
   const [method,target]=head.split('\r\n')[0].split(' '),body=bytes.subarray(at+4,at+4+length);
   calls.push({method,target,body});
   const encoding=/\r\nx-response:\s*([^\r\n]+)/i.exec('\r\n'+head)?.[1];
   const gzip=encoding==='gzip'||encoding==='invalid-gzip';
   const data=encoding==='invalid-gzip'?Buffer.from(plain.toString().replace('9007199254740993','9007199254740992')):plain;
   const payload=gzip?gzipSync(data):data;
   socket.end(Buffer.concat([Buffer.from('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'+
    (gzip?'Content-Encoding: gzip\r\n':encoding==='unsupported'?'Content-Encoding: busyapi-synthetic\r\n':'')+`Content-Length: ${payload.length}\r\nConnection: close\r\n\r\n`),payload]));
  });
 });
 t.after(async()=>{for(const socket of sockets)socket.destroy();await new Promise(resolve=>upstream.close(resolve));});
 await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
 const methods=['get','post','head','trace','CuStOm','__proto__','X~Task'];
 const operation={requestBody:{required:true,content:{'application/json':{schema:{type:'integer',const:'EXACT'}}}},
  responses:{200:{description:'Retained upstream',content:{'application/json':{schema:{type:'object',required:['number'],properties:{number:{const:'EXACT'}}}}}}}};
 const document={openapi:version,info:{title:'Exact proxy methods',version:'1'},
  paths:{'/data':{additionalOperations:Object.fromEntries(methods.map(method=>[method,operation]))}}};
 const text=(format==='yaml'?YAML.stringify(document):JSON.stringify(document)).replaceAll(format==='yaml'?'EXACT':'"EXACT"','9007199254740993.00');
 const root=`file:///custom-proxy/api.${format}`,capture={root,snapshot:'0'.repeat(64),resources:[{id:root,text,generation:1,identity:createHash('sha256').update(text).digest('hex')}]};
 const original=JSON.stringify(capture),ready=await startMock(t,capturedMockStart(capture,{upstream:`http://127.0.0.1:${upstream.address().port}/base`}));
 const path='/data?lower=%2f&space=a%20b&flag&repeat=1&repeat=2';
 for(const method of methods)for(const encoding of ['identity','gzip']){
  const response=await wire(ready.port,method,path,{'X-Response':encoding},'9007199254740993.00');
  assert.equal(response.status,200,response.text);
  assert.deepEqual(response.bytes,encoding==='gzip'?gzipSync(plain):plain);
  assert.equal(response.headers['content-encoding'],encoding==='gzip'?'gzip':undefined);
  assert.equal(response.headers['busyapi-response-validation-complete'],'true');
  assert.equal(response.headers['sl-violations'],undefined);
  assert.equal(calls.at(-1).method,method);
  assert.equal(calls.at(-1).target,'/base'+path);
  assert.equal(calls.at(-1).body.toString(),'9007199254740993.00');
 }
 const invalid=await wire(ready.port,'get',path,{'X-Response':'invalid-gzip'},'9007199254740993.00');
 assert.equal(invalid.status,200,invalid.text);
 assert.deepEqual(invalid.bytes,gzipSync(Buffer.from(plain.toString().replace('9007199254740993','9007199254740992'))));
 assert.equal(invalid.headers['busyapi-response-validation-complete'],'true');
 assert.ok(JSON.parse(invalid.headers['sl-violations']).some(value=>value.nativeCode==='runtime.schema.incompatible'&&value.source.resource===root&&value.source.pointer.startsWith('/paths/~1data/additionalOperations/get/')));
 const unsupported=await wire(ready.port,'get',path,{'X-Response':'unsupported'},'9007199254740993.00');
 assert.equal(unsupported.status,501,unsupported.text);
 assert.equal(unsupported.headers['busyapi-response-validation-complete'],'false');
 assert.equal(JSON.parse(unsupported.text).complete,false);
 assert.ok(JSON.parse(unsupported.text).findings.some(value=>value.code==='mock.proxy.encoding.unsupported'&&value.kind==='unsupported'&&value.source.resource===root&&value.source.snapshot===capture.snapshot));
 assert.equal(calls.length,methods.length*2+2);
 assert.equal(JSON.stringify(capture),original);
});

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} a CONNECT tunnel never appears as a ready stateless mock`,async t=>{
 const root=`file:///tunnel/api.${format}`;
 const document={openapi:version,info:{title:'Tunnel',version:'1'},paths:{'/':{additionalOperations:{CONNECT:{responses:{200:{description:'Tunnel established'}}}}}}};
 const text=format==='yaml'?YAML.stringify(document):JSON.stringify(document);
 const capture={root,snapshot:'0'.repeat(64),resources:[{id:root,text,generation:1,identity:createHash('sha256').update(text).digest('hex')}]};
 const original=JSON.stringify(capture),failed=await startMock(t,capturedMockStart(capture),{failure:true});
 assert.equal(failed.event,'failed');assert.equal(failed.failure.code,'mock.method.tunnel');
 assert.equal(failed.failure.kind,'unsupported');assert.equal(failed.failure.source.resource,root);
 assert.equal(failed.failure.source.pointer,'/paths/~1/additionalOperations/CONNECT');
 assert.equal(JSON.stringify(capture),original);
});
