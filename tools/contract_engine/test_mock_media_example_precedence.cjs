const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const exact={HIGH:'9007199254740993.00',LOW:'9007199254740992.00',OTHER:'9007199254740997.00'};
function render(value,format){
 let text=format==='yaml'?'# Keep precedence and exact values\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value);
 for(const [name,number]of Object.entries(exact))text=text.replaceAll('"'+name+'"',number).replaceAll(name,number);
 return text;
}
function send(port,path,prefer){return new Promise((resolve,reject)=>{
 const request=http.get({host:'127.0.0.1',port,path,headers:prefer?{prefer}:{}},response=>{
  const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,bytes:Buffer.concat(chunks)}));
 });request.once('error',reject);
});}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} authored media examples override schema suggestions without numeric loss`,{timeout:30000},async t=>{
 const legacy=version==='2.0',modern=version.startsWith('3.1')||version.startsWith('3.2');
 const schema={type:'integer',example:'HIGH',...(modern?{examples:['HIGH']}:{})};
 const response=name=>({description:'Authored examples',...(legacy?{schema,examples:{'application/json':'LOW'}}:{content:{'application/json':{schema,examples:name==='default'?{default:{value:'LOW'}}:{Alpha:{value:'LOW'},Beta:{value:'OTHER'}}}}})});
 const document={...(legacy?{swagger:version,produces:['application/json']}:{openapi:version}),info:{title:'Media precedence',version:'business'},paths:{'/named':{get:{responses:{200:response('named')}}},'/default':{get:{responses:{200:response('default')}}}}};
 const input=mockStart(render(document,format),{},'file:///controlled/precedence.'+format),before=JSON.stringify(input.capture),{port}=await startMock(t,input);
 for(const [path,prefer,expected]of [['/named',undefined,exact.LOW],['/default',undefined,exact.LOW],...(!legacy?[['/named','example=Beta',exact.OTHER],['/default','example=default',exact.LOW]]:[])]){
  const response=await send(port,path,prefer);assert.equal(response.status,200,response.bytes.toString());assert.deepEqual(response.bytes,Buffer.from(expected),path+' '+(prefer??''));
  assert.equal(Number(response.headers['content-length']),Buffer.byteLength(expected));assert.equal(response.headers['busyapi-response-validation-complete'],'true');assert.deepEqual(JSON.parse(response.headers['sl-violations']??'[]'),[]);
 }
 assert.equal(JSON.stringify(input.capture),before);
});
