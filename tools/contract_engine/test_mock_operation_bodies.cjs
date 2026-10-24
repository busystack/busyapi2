const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const {spawn}=require('node:child_process');
const {once}=require('node:events');
const path=require('node:path');

async function start(t,version,upstream) {
 const legacy=version==='2.0',methods=['get','head','delete','options','post','put','patch',...(legacy?[]:['trace'])];
 const schema={type:'object',required:['value'],properties:{value:{type:'string'}}};
 const document={...(legacy?{swagger:version,consumes:['application/json']}:{openapi:version}),info:{title:'Method body mock',version:'1'},paths:{'/data':Object.fromEntries(methods.map(method=>[method,{
  ...(legacy?{parameters:[{in:'body',name:'payload',required:true,schema}]}:{requestBody:{required:true,content:{'application/json':{schema}}}}),
  responses:{204:{description:'Empty'}}}]))}};
 const original=JSON.stringify(document),child=spawn(process.execPath,[path.join(__dirname,'dist/mock-server.cjs')],{stdio:['pipe','pipe','pipe']});
 let stderr='';child.stderr.on('data',chunk=>stderr+=chunk);
 t.after(async()=>{if(child.exitCode===null){child.kill('SIGTERM');await once(child,'exit');}});
 child.stdin.end(JSON.stringify({version:1,snapshot:'0'.repeat(64),document:original,...(upstream?{upstream}:{})}));
 const ready=await new Promise((resolve,reject)=>{
  let output='';child.once('error',reject);child.once('exit',()=>reject(Error('mock exited before readiness: '+stderr)));
  child.stdout.on('data',chunk=>{output+=chunk;for(const line of output.split('\n')){if(!line)continue;try{const event=JSON.parse(line);if(event.event==='ready')resolve(event);}catch{}}});
 });
 assert.equal(JSON.stringify(document),original);
 return {port:ready.port,methods};
}
function request(port,method,body) {
 return new Promise((resolve,reject)=>{
  const req=http.request({host:'127.0.0.1',port,path:'/data',method:method.toUpperCase(),headers:body===undefined?{}:{'content-type':'application/json','content-length':Buffer.byteLength(body)}},res=>{
   const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.on('end',()=>resolve({status:res.statusCode,text:Buffer.concat(chunks).toString()}));
  });
  req.on('error',reject);req.end(body);
 });
}
for(const version of ['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])test(`${version} compiled native mock consumes the owning family's method/body rules`,{timeout:20000},async t=>{
 const {port,methods}=await start(t,version);
 for(const method of methods) {
  const ignored=version.startsWith('3.0.')&&!['post','put','patch'].includes(method);
  const absent=await request(port,method);
  if(ignored)assert.equal(absent.status,204,method+': '+absent.text);
  else assert.ok([400,415,422].includes(absent.status),method+': '+absent.status+' '+absent.text);
  // TRACE has no legal message body. The adapter still projects its source
  // declaration according to the family, without sending a forbidden payload.
  if(method==='trace')continue;
  const invalid=await request(port,method,'0');
  if(ignored)assert.equal(invalid.status,204,method+': '+invalid.text);
  else assert.ok([400,415,422].includes(invalid.status),method+': '+invalid.status+' '+invalid.text);
  const valid=await request(port,method,'{"value":"雪"}');assert.equal(valid.status,204,method+': '+valid.text);
 }
});
for(const version of ['3.0.4','3.1.2'])test(`${version} validation proxy retains applicable requests and exact upstream bytes`,{timeout:20000},async t=>{
 const seen=[],server=http.createServer((req,res)=>{const chunks=[];req.on('data',chunk=>chunks.push(chunk));req.on('end',()=>{seen.push({method:req.method,bytes:Buffer.concat(chunks)});res.statusCode=204;res.end();});});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 const {port}=await start(t,version,'http://127.0.0.1:'+server.address().port),ignored=version==='3.0.4';
 for(const data of [undefined,'0']) {
  const response=await request(port,'delete',data);
  assert.equal(response.status,ignored?204:422,response.text);
 }
 assert.equal(seen.length,ignored?2:0);
 if(ignored){assert.deepEqual(seen[0],{method:'DELETE',bytes:Buffer.alloc(0)});assert.deepEqual(seen[1],{method:'DELETE',bytes:Buffer.from('0')});}
 const absentGet=await request(port,'get');assert.equal(absentGet.status,ignored?204:422,absentGet.text);
 const valid=await request(port,'post','{"value":"雪"}');assert.equal(valid.status,204,valid.text);
 assert.deepEqual(seen.at(-1),{method:'POST',bytes:Buffer.from('{"value":"雪"}')});
});
