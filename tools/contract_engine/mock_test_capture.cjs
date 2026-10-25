const {createHash}=require('node:crypto');
const {spawn}=require('node:child_process');
const {once}=require('node:events');
const path=require('node:path');
const http=require('node:http');
const assert=require('node:assert/strict');
const {deriveBundle}=require('./dist/derived_bundle.cjs');
const {schemaProducer}=require('./dist/schema_evaluation.cjs');

function mockStart(document,options={},root='file:///mock-fixture/api.json') {
 const text=typeof document==='string'?document:JSON.stringify(document);
 const capture={root,snapshot:'0'.repeat(64),resources:[{id:root,text,generation:1,identity:createHash('sha256').update(text).digest('hex')}]};
 return capturedMockStart(capture,options);
}
function capturedMockStart(capture,options={}) {
 const derived=deriveBundle({...capture,outputId:'file:///mock-fixture/busyapi-mock.json'});
 if(derived.complete!==true)throw Error('The synthetic mock fixture did not form one complete bundle');
 return {version:1,snapshot:capture.snapshot,capture,derived:{id:derived.output.id,identity:derived.output.identity},...options};
}
async function startMock(t,input,{failure=false,helper=path.join(__dirname,'dist/mock-server.cjs')}={}) {
 const child=spawn(process.execPath,[helper],{stdio:['pipe','pipe','pipe']});
 let stderr='';child.stderr.on('data',chunk=>stderr+=chunk);
 t.after(async()=>{
  if(child.exitCode===null){
   child.kill('SIGTERM');
   const deadline=setTimeout(()=>child.kill('SIGKILL'),3000);
   try{await once(child,'exit');}finally{clearTimeout(deadline);}
  }
 });
 const ready=new Promise((resolve,reject)=>{
  let output='';const deadline=setTimeout(()=>reject(Error('mock startup timed out: '+stderr)),12000);
  child.once('error',error=>{clearTimeout(deadline);reject(error);});
  child.once('exit',()=>{clearTimeout(deadline);reject(Error('mock exited before readiness: '+stderr));});
  child.stdout.on('data',chunk=>{
   output+=chunk;
   for(const line of output.split('\n')){
    if(!line)continue;
    let event;try{event=JSON.parse(line);}catch{continue;}
    if(event.event==='ready'||event.event==='failed'){
     clearTimeout(deadline);
     if(event.event==='failed'&&!failure)reject(Error(JSON.stringify(event)));else resolve(event);
    }
   }
  });
 });
 child.stdin.end(JSON.stringify(input));
 const event=await ready;
 if(!failure){
  assert.equal(event.nativeValidation.name,'hyperjump+busyapi-exact');
  assert.equal(event.nativeValidation.version,schemaProducer.version);
  assert.equal(event.nativeValidation.configuration,schemaProducer.configuration);
  assert.equal(event.nativeResponseValidation.name,'busyapi-native-response');
  assert.equal(event.nativeResponseValidation.version,'3');
  assert.equal(event.nativeResponseValidation.configuration,'response-wire-v3:'+schemaProducer.configuration);
  assert.equal(event.nativeParameterValidation.name,'busyapi-native-parameters');
  assert.equal(event.nativeParameterValidation.version,'3');
  assert.equal(event.nativeParameterValidation.configuration,'parameter-wire-v3:'+schemaProducer.configuration);
  assert.equal(event.nativeSecurityValidation.name,'busyapi-native-security');
  assert.equal(event.nativeSecurityValidation.version,'1');
  assert.equal(event.nativeSecurityValidation.configuration,'security-wire-v1:'+event.nativeValidation.configuration);
 }
 return event;
}

function mockRequest(port,route,text,{mediaType='application/json'}={}) {
 const bytes=text===undefined?undefined:Buffer.isBuffer(text)?text:Buffer.from(text);
 return new Promise((resolve,reject)=>{
  const req=http.request({host:'127.0.0.1',port,path:route,method:'POST',headers:bytes===undefined?{}:{'content-type':mediaType,'content-length':bytes.length}},res=>{
   const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.once('error',reject);
   res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,text:Buffer.concat(chunks).toString()}));
  });
  req.once('error',reject);req.end(bytes);
 });
}

module.exports={mockStart,capturedMockStart,startMock,mockRequest};
