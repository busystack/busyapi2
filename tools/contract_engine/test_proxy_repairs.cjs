const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const {spawn}=require('node:child_process');
const {once}=require('node:events');
const path=require('node:path');
async function fixture(t){
 const cookies=['a=1; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT','b=2; Path=/','a=3; Path=/nested'];
 const upstream=http.createServer((req,res)=>{
  const status=Number(req.url.slice(1))||200;res.statusCode=status;
  res.setHeader('content-type','application/json');res.setHeader('x-retained','yes');
  res.setHeader('set-cookie',cookies);res.setHeader('vary',['Accept','Origin']);
  res.end(req.url==='/empty'?'':req.url==='/malformed'?'{bad':status===200&&req.method!=='HEAD'?'{"n":9007199254740993.00}':undefined);
 });
 await new Promise((resolve,reject)=>{upstream.once('error',reject);upstream.listen(0,'127.0.0.1',resolve);});
 t.after(()=>new Promise(resolve=>{upstream.closeAllConnections();upstream.close(resolve);}));
 const document={openapi:'3.2.1',info:{title:'Proxy',version:'1'},paths:Object.fromEntries([200,204,205,304].map(status=>['/'+status,Object.fromEntries(['get','head'].map(method=>[method,{responses:{[status]:{description:'upstream',...(status===200&&method==='get'?{content:{'application/json':{schema:{type:'object'}}}}:{})}}}]))]))};
 for(const path of ['/empty','/malformed'])document.paths[path]={get:{responses:{200:{description:'body applies',content:{'application/json':{schema:{type:'object'}}}}}}};
 const child=spawn(process.execPath,[path.join(__dirname,'dist/mock-server.cjs')],{stdio:['pipe','pipe','pipe']});let stderr='';child.stderr.on('data',chunk=>stderr+=chunk);
 t.after(async()=>{if(child.exitCode===null){child.kill('SIGTERM');await once(child,'exit');}});
 child.stdin.end(JSON.stringify({version:1,snapshot:'0'.repeat(64),document:JSON.stringify(document),upstream:'http://127.0.0.1:'+upstream.address().port}));
 const ready=await new Promise((resolve,reject)=>{let out='';child.once('error',reject);child.once('exit',()=>reject(Error('proxy exited: '+stderr)));child.stdout.on('data',chunk=>{out+=chunk;for(const line of out.split('\n')){if(!line)continue;try{const event=JSON.parse(line);if(event.event==='ready')resolve(event);}catch{}}});});
 return {cookies,port:ready.port};
}
function request(port,method,status){return new Promise((resolve,reject)=>{const req=http.request({host:'127.0.0.1',port,path:'/'+status,method},res=>{const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,rawHeaders:res.rawHeaders,body:Buffer.concat(chunks).toString()}));});req.on('error',reject);req.end();});}
test('R12 compiled proxy respects HEAD and no-content status body applicability',{timeout:15000},async t=>{
 const {port}=await fixture(t);
 for(const [method,status]of [['HEAD',200],['GET',204],['GET',205],['GET',304]]){
  const res=await request(port,method,status);assert.equal(res.status,status,res.body);assert.equal(res.body,'');assert.equal(res.headers['x-retained'],'yes');
 }
 const normal=await request(port,'GET',200);assert.equal(normal.status,200);assert.equal(normal.body,'{"n":9007199254740993.00}');
});
test('R13 compiled proxy preserves separate Set-Cookie field lines',{timeout:15000},async t=>{
 const {port,cookies}=await fixture(t),res=await request(port,'GET',200);
 assert.equal(res.status,200);assert.deepEqual(res.headers['set-cookie'],cookies);assert.equal(res.headers.vary,'Accept, Origin');
 assert.equal(res.body,'{"n":9007199254740993.00}');
});

test('R12 applicable empty or malformed JSON remains an explicit proxy failure',{timeout:15000},async t=>{
 const {port}=await fixture(t);
 for(const path of ['empty','malformed']){
  const res=await request(port,'GET',path);assert.equal(res.status,500);assert.equal(res.headers['content-type'],'application/problem+json');
 }
});
