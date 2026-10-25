const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const net=require('node:net');
const {once}=require('node:events');
const {setTimeout:pause}=require('node:timers/promises');
const {MockMethodTransport,maximumMockMethodBytes}=require('./dist/mock_method_transport.cjs');

async function fixture(t,enabled=true){
 const calls=[];
 const server=http.createServer(async(request,response)=>{
  const method=transport.method(request),chunks=[];
  for await(const chunk of request)chunks.push(chunk);
  const value={method,url:request.url,headers:request.rawHeaders,body:Buffer.concat(chunks).toString('hex'),clientPort:request.socket.remotePort};
  calls.push(value);response.end(JSON.stringify(value));
 });
 const transport=new MockMethodTransport(server,enabled);
 t.after(async()=>{
  transport.close();server.closeAllConnections();
  if(server.listening)await new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve()));
 });
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
 return {server,transport,calls,port:server.address().port};
}

function raw(port,chunks){
 return new Promise((resolve,reject)=>{
  const socket=net.connect({host:'127.0.0.1',port}),parts=[];
  socket.setNoDelay(true);socket.setTimeout(1500,()=>socket.destroy(Error('Synthetic transport timed out')));
  socket.once('error',reject);socket.on('data',chunk=>parts.push(chunk));
  socket.once('end',()=>{
   const bytes=Buffer.concat(parts),at=bytes.indexOf('\r\n\r\n');
   if(at<0)return reject(Error('The transport omitted response framing'));
   const lines=bytes.subarray(0,at).toString('latin1').split('\r\n');
   const status=Number(lines.shift().split(' ')[1]),headers=Object.create(null);
   for(const line of lines){const colon=line.indexOf(':');headers[line.slice(0,colon).toLowerCase()]=line.slice(colon+1).trim();}
   resolve({status,headers,body:bytes.subarray(at+4).toString('utf8')});
  });
  socket.once('connect',async()=>{
   try{for(const chunk of chunks){if(socket.destroyed)return;socket.write(chunk);await pause(4);}}
   catch(error){socket.destroy(error);}
  });
 });
}

for(const method of ['GET','get','gEt','CuStOm','__proto__','constructor',"!#$%&'*+-.^_`|~"])
test(`method transport preserves actual token ${method} and every body/header byte`,async t=>{
 const {port,calls}=await fixture(t);
 const body=Buffer.from('9007199254740993.00\r\nGET /literal HTTP/1.1\r\n雪\u0000');
 const response=await raw(port,[method.slice(0,1),method.slice(1),' /data?space=a%20b&lower=%2f HTTP/1.1\r\n',
  'Host: local\r\nX-Literal: GET literal\r\nConnection: close\r\n',`Content-Length: ${body.length}\r\n\r\n`,body]);
 assert.equal(response.status,200,response.body);
 const actual=JSON.parse(response.body);
 assert.equal(actual.method,method);
 assert.equal(actual.url,'/data?space=a%20b&lower=%2f');
 assert.equal(actual.body,body.toString('hex'));
 assert.deepEqual(actual.headers,['Host','local','X-Literal','GET literal','Connection','close','Content-Length',String(body.length)]);
 assert.equal(calls.length,1);
});

test('split leading CRLF retains the original custom method',async t=>{
 const {port}=await fixture(t);
 const response=await raw(port,['\r','\n\r','\n','ge','t / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n']);
 assert.equal(response.status,200,response.body);assert.equal(JSON.parse(response.body).method,'get');
});

for(const headers of [
 'Content-Length: 1\r\nContent-Length: 2',
 'Content-Length: 1\r\nTransfer-Encoding: chunked',
 'Bad Header: invalid',
])test(`custom method retains the original strict parser rejection for ${headers.split(':')[0]}`,async t=>{
 const {port,calls}=await fixture(t);
 const response=await raw(port,[`get / HTTP/1.1\r\nHost: local\r\n${headers}\r\nConnection: close\r\n\r\n0\r\n\r\n`]);
 assert.equal(response.status,400,response.body);assert.equal(calls.length,0);
});

for(const token of ['bad\u0080','bad\nname','bad\r\nInjected: true'])
test(`invalid method bytes never reach an operation: ${JSON.stringify(token)}`,async t=>{
 const {port,calls}=await fixture(t);
 const response=await raw(port,[Buffer.from(`${token} / HTTP/1.1\r\nHost: local\r\n\r\n`,'latin1')]);
 assert.equal(response.status,400);assert.equal(calls.length,0);
});

test('oversized method returns bounded refusal before parsing a contract',async t=>{
 const {port,calls}=await fixture(t);
 const response=await raw(port,['X'.repeat(maximumMockMethodBytes+1)+' / HTTP/1.1\r\nHost: local\r\n\r\n']);
 assert.equal(response.status,431);assert.equal(calls.length,0);
});

test('custom-method captures announce one request per connection',async t=>{
 const {port,calls}=await fixture(t);
 const response=await raw(port,['GET / HTTP/1.1\r\nHost: local\r\nConnection: keep-alive\r\n\r\n']);
 assert.equal(response.status,200,response.body);
 assert.equal(response.headers.connection,'close');assert.equal(calls.length,1);
});

test('ordinary captures retain actual keep-alive connection reuse',async t=>{
 const {port,calls}=await fixture(t,false),agent=new http.Agent({keepAlive:true});
 t.after(()=>agent.destroy());
 for(let index=0;index<2;index++)await new Promise((resolve,reject)=>{
  const request=http.get({host:'127.0.0.1',port,agent},response=>{response.resume();response.once('end',resolve);response.once('error',reject);});
  request.once('error',reject);
 });
 assert.equal(calls.length,2);assert.equal(calls[0].clientPort,calls[1].clientPort);
});

test('shutdown cancels an unfinished method without waiting for its timeout',async t=>{
 const {port,server,transport,calls}=await fixture(t);
 const socket=net.connect({host:'127.0.0.1',port});t.after(()=>socket.destroy());
 await once(socket,'connect');socket.write('ge');await pause(12);
 const closed=once(server,'close');transport.close();server.closeAllConnections();server.close();
 let timer;
 try{await Promise.race([closed,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Method shutdown exceeded one second')),1000);})]);}
 finally{clearTimeout(timer);}
 assert.equal(calls.length,0);
});

test('an ambiguous original parser owner fails before binding a listener',()=>{
 const server=http.createServer();server.on('connection',()=>{});
 assert.throws(()=>new MockMethodTransport(server,true),error=>error.code==='mock.method.parser');
 assert.equal(server.listening,false);
});
