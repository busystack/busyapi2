const {test}=require('node:test');
const assert=require('node:assert/strict');
const net=require('node:net');
const zlib=require('node:zlib');
const {exactProxyResponse}=require('./dist/mock_exact_proxy.cjs');

async function fixture(t,handle,allowReset=false){
 const sockets=new Set(),requests=[];
 const server=net.createServer(socket=>{
  sockets.add(socket);socket.once('close',()=>sockets.delete(socket));
  socket.on('error',error=>{if(!allowReset||error.code!=='ECONNRESET')throw error;});
  let bytes=Buffer.alloc(0),done=false;
  socket.on('data',chunk=>{
   if(done)return;bytes=Buffer.concat([bytes,chunk]);const at=bytes.indexOf('\r\n\r\n');if(at<0)return;
   const head=bytes.subarray(0,at).toString('latin1'),length=Number(/\r\ncontent-length:\s*(\d+)/i.exec('\r\n'+head)?.[1]??0);
   if(bytes.length<at+4+length)return;done=true;
   requests.push({line:head.split('\r\n')[0],body:bytes.subarray(at+4,at+4+length)});
   handle(socket,requests.at(-1));
  });
 });
 t.after(async()=>{for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 return {target:new URL(`http://127.0.0.1:${server.address().port}/data?raw=%2f&flag`),requests};
}

function reply(socket,body,encoding){
 socket.end(Buffer.concat([Buffer.from('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'+
  (encoding?`Content-Encoding: ${encoding}\r\n`:'')+`Content-Length: ${body.length}\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nConnection: close\r\n\r\n`),body]));
}

const plain=Buffer.from('{"number":9007199254740993.00,"text":"雪","empty":"","false":false}');
for(const method of ['head','connect','query','PURGE','MiXeD!'])
test(`exact proxy treats ${method} as the original case-sensitive method`,{timeout:2000},async t=>{
 const {target,requests}=await fixture(t,socket=>reply(socket,plain));
 const body=Buffer.from('9007199254740993.00');
 const response=await exactProxyResponse(target,method,new Headers(),body,4096);
 assert.deepEqual(response.wire,plain);assert.deepEqual(response.decoded,plain);
 assert.equal(requests[0].line,`${method} /data?raw=%2f&flag HTTP/1.1`);
 assert.deepEqual(requests[0].body,body);
});

for(const [encoding,encode]of [
 [undefined,value=>value],['gzip',zlib.gzipSync],['deflate',zlib.deflateSync],['br',zlib.brotliCompressSync],
 ['gzip, br',value=>zlib.brotliCompressSync(zlib.gzipSync(value))],
])test(`exact proxy retains ${encoding??'identity'} wire bytes and a distinct validated view`,async t=>{
 const wire=encode(plain),{target,requests}=await fixture(t,socket=>reply(socket,wire,encoding));
 const body=Buffer.from('9007199254740993.00');
 const response=await exactProxyResponse(target,'get',new Headers({'content-type':'application/json'}),body,4096);
 assert.equal(response.status,200);assert.deepEqual(response.wire,wire);assert.deepEqual(response.decoded,plain);
 assert.deepEqual(response.headers.getSetCookie(),['a=1','b=2']);
 assert.equal(requests[0].line,'get /data?raw=%2f&flag HTTP/1.1');assert.deepEqual(requests[0].body,body);
});

for(const [encoding,payload,code]of [
 ['busyapi-synthetic',plain,'mock.proxy.encoding.unsupported'],
 ['gzip, gzip, gzip, gzip, gzip',plain,'mock.proxy.encoding.limit'],
 ['gzip',Buffer.from('malformed'),'mock.proxy.encoding.invalid'],
])test(`exact proxy refuses ${code} without a successful decoded response`,async t=>{
 const {target}=await fixture(t,socket=>reply(socket,payload,encoding));
 await assert.rejects(exactProxyResponse(target,'trace',new Headers(),undefined,4096),error=>error.code===code&&error.kind===(code.endsWith('.invalid')?undefined:'unsupported'));
});

for(const [encoding,payload,code]of [
 [undefined,Buffer.alloc(257,120),'mock.proxy.wire.limit'],
 ['gzip',zlib.gzipSync(Buffer.alloc(4096,120)),'mock.proxy.decoded.limit'],
])test(`exact proxy enforces ${code} on real received data`,async t=>{
 const {target}=await fixture(t,socket=>reply(socket,payload,encoding));
 await assert.rejects(exactProxyResponse(target,'get',new Headers(),undefined,256),error=>error.code===code&&error.kind==='unsupported');
});

test('exact proxy cancellation closes a stalled real upstream response',async t=>{
 let entered,closed;
 const gate=new Promise(resolve=>entered=resolve),retired=new Promise(resolve=>closed=resolve);
 const {target,requests}=await fixture(t,socket=>{
  socket.once('close',closed);
  socket.write('HTTP/1.1 200 OK\r\nContent-Length: 999\r\nConnection: close\r\n\r\npartial');entered();
 },true);
 const cancellation=new AbortController();
 const pending=exactProxyResponse(target,'gEt',new Headers(),undefined,4096,cancellation.signal);
 const rejected=assert.rejects(pending,error=>error.name==='AbortError'||error.code==='ABORT_ERR');
 await gate;cancellation.abort();await rejected;
 let timer;
 try{await Promise.race([retired,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Cancelled upstream did not close')),1000);})]);}
 finally{clearTimeout(timer);}
 assert.equal(requests[0].line,'gEt /data?raw=%2f&flag HTTP/1.1');
});

test('a cancelled exact proxy never contacts the upstream',async t=>{
 const {target,requests}=await fixture(t,socket=>reply(socket,plain));
 const cancellation=new AbortController();cancellation.abort();
 await assert.rejects(exactProxyResponse(target,'get',new Headers(),undefined,4096,cancellation.signal),error=>error.name==='AbortError'||error.code==='ABORT_ERR');
 assert.equal(requests.length,0);
});
