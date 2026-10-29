const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const exact={LOW:'9007199254740992.00',HIGH:'9007199254740993.00'};
function render(value,format){
 let text=format==='yaml'?'# Keep negotiated examples\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value);
 for(const [name,number]of Object.entries(exact))text=text.replaceAll('"'+name+'"',number).replaceAll(name,number);
 return text;
}
function send(port,path,prefer){return new Promise((resolve,reject)=>{
 const request=http.get({host:'127.0.0.1',port,path,headers:prefer?{prefer}:{}},response=>{
  const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,bytes:Buffer.concat(chunks)}));
 });request.once('error',reject);
});}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} exact media values follow the actual invalid-request negotiation`,{timeout:30000},async t=>{
 const legacy=version==='2.0',paths={};
 for(const collision of [false,true]){
  const values={first:{...(!collision?{marker:'first'}:{}),amount:'LOW'},other:{...(!collision?{marker:'other'}:{}),amount:'HIGH'}};
  const response=()=>({description:'Negotiated response',...(legacy?{schema:{type:'integer',example:'HIGH'},examples:{'application/json':'LOW'}}:{content:{'application/json':{schema:{type:'object',example:values.other},examples:Object.fromEntries(Object.entries(values).map(([name,value])=>[name,{value}]))}}})});
  paths['/'+collision]={get:{parameters:[{name:'id',in:'query',required:true,...(legacy?{type:'string'}:{schema:{type:'string'}})}],responses:{200:response(),422:response()}}};
 }
 const document={...(legacy?{swagger:version,produces:['application/json']}:{openapi:version}),info:{title:'Negotiated exact values',version:'business'},paths};
 const input=mockStart(render(document,format),{},'file:///controlled/negotiated.'+format),before=JSON.stringify(input.capture),{port}=await startMock(t,input);
 for(const collision of [false,true])for(const header of [false,true])for(const [valid,name,code,status,chosen]of legacy
  ?[[true,'application/json',undefined,200,'first'],[false,undefined,undefined,422,'first'],[false,'application/json',undefined,422,'first'],[false,'application/json',422,422,'first']]
  :[[true,'other',undefined,200,'other'],[false,undefined,undefined,422,'first'],[false,'other',undefined,422,'first'],[false,'other',422,422,'other'],[false,'other',200,422,'first'],[false,'other',400,422,'other']]){
  const controls=[...(name===undefined?[]:[(header?'example':'__example')+'='+name]),...(code===undefined?[]:[(header?'code':'__code')+'='+code])];
  const query=[...(valid?['id=ok']:[]),...(!header?controls:[])],route='/'+collision+(query.length?'?'+query.join('&'):'');
  const response=await send(port,route,header&&controls.length?controls.join(', '):undefined);
  const expected=legacy?exact.LOW:JSON.stringify({...(!collision?{marker:chosen}:{}),amount:chosen==='first'?'LOW':'HIGH'}).replace('"LOW"',exact.LOW).replace('"HIGH"',exact.HIGH);
  const context=route+' Prefer='+(header?controls.join(', '):'');
  assert.equal(response.status,status,context+': '+response.bytes);assert.deepEqual(response.bytes,Buffer.from(expected),context);
  assert.equal(Number(response.headers['content-length']),Buffer.byteLength(expected));assert.equal(response.headers['busyapi-response-validation-complete'],'true');
  const violations=JSON.parse(response.headers['sl-violations']??'[]');
  if(valid)assert.deepEqual(violations,[]);else assert(violations.some(value=>Array.isArray(value.location)&&value.location[0]==='request'&&value.severity==='Error'),context+': '+JSON.stringify(violations));
 }
 assert.equal(JSON.stringify(input.capture),before);
});
