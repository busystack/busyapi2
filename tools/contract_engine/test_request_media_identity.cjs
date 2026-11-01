const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {requestOperation,requestFormMediaTypes,requestMultipartEncoding}=require('./dist/execution.cjs');
const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function packet(version,format,multipart){
 const legacy=version==='2.0',selected=multipart?'multipart/form-data':'application/x-www-form-urlencoded; charset=utf-8';
 const other=multipart?'Multipart/Form-Data':'Application/X-WWW-Form-Urlencoded; charset=utf-8';
 const weak={schema:{type:'object',properties:{payload:{type:'string'},note:{type:'string'}}}};
 const strong={schema:{type:'object',required:['note'],properties:{payload:{type:'object',properties:{n:{type:'number'}}},note:{type:'string'}}}};
 const operation={...(legacy?{parameters:[{name:'note',in:'formData',type:'string',required:true}]}:{requestBody:{content:{[other]:weak,[selected]:strong}}}),responses:{204:{description:'No payload'}}};
 const value={...(legacy?{swagger:version,consumes:[other,selected]}:{openapi:version}),info:{title:'Captured media',version:'unrelated'},paths:{'/form':{post:operation}}};
 const root='file:///captured-media/'+version+'/api.'+format,text=format==='json'?JSON.stringify(value):'# Retain exact declaration spelling\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
 return {input:{root,resource:root,pointer:'/paths/~1form/post',snapshot:version+format+multipart,resources:[{id:root,text,generation:3}]},selected,other,text};
}
for(const version of versions)for(const format of ['json','yaml'])for(const multipart of version==='2.0'?[false]:[false,true])test(`${version} ${format} ${multipart?'multipart':'urlencoded'} preflight retains the explicit declaration identity`,async()=>{
 const {input,selected,other,text}=packet(version,format,multipart),plan=requestOperation(input);
 const sources=plan.requestBody.content.map(item=>item.mediaType);assert.deepEqual(sources,[other,selected]);
 const args={...input,mediaType:selected,parts:multipart?['payload']:['note'],choices:multipart?{payload:'application/json'}:{},files:[]};
 const result=requestFormMediaTypes(args);assert.equal(result.identity,plan.identity);
 if(multipart){
  assert.equal(result.types.payload,'application/json');
  const first=requestFormMediaTypes({...args,mediaType:other,choices:{payload:'text/plain'}});assert.equal(first.types.payload,'text/plain');
  const encoding=await requestMultipartEncoding({...input,mediaType:selected,parts:[{name:'payload',kind:'other'}],files:[]});
  assert(encoding.parts.payload.other);assert.equal(encoding.identity,plan.identity);
 }else{assert.deepEqual(Object.keys(result.types),[]);assert.deepEqual(result.files,[]);}
 const nonAuthored=selected.toUpperCase();
 assert.throws(()=>requestFormMediaTypes({...args,mediaType:nonAuthored}),error=>error.code==='mock.content-type.ambiguous'&&error.kind==='unsupported');
 assert.throws(()=>requestFormMediaTypes({...args,mediaType:undefined}),error=>error.code==='request.form.content-type');
 assert.equal(input.resources[0].text,text);
});

for(const version of ['3.0.4','3.2.1'])test(`${version} wire-only mock matching still refuses equal-specificity entries`,{timeout:20000},async t=>{
 const {mockStart,startMock,mockRequest}=require('./mock_test_capture.cjs');
 const {input,selected,text}=packet(version,'json',false),{port}=await startMock(t,mockStart(text,{},input.root));
 const response=await mockRequest(port,'/form','note=value',{mediaType:selected});
 assert.equal(response.status,501,response.text);
 assert.match(response.text,/Equally specific|ambiguous/);
});
