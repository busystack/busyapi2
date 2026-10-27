const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{requestMultipartEncoding,requestOperation,requestFormMediaTypes}=require('./dist/execution.cjs');
const versions=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function packet(version,format,kind,name='payload',union=false){
 const root='file:///approved/api.'+format,external='file:///approved/part.'+format;
 const schema={type:union?['string','array']:'string',contentEncoding:'base64',...(union?{items:{type:'string',contentEncoding:'base64'}}:{})};
 const remote=kind.startsWith('external-'),anchor=['one-dynamic-anchor','external-dynamic-anchor'].includes(kind)?{$dynamicAnchor:'part'}:kind.includes('anchor')?{$anchor:'part'}:{};
 const part={...anchor,...schema},ref=(remote?'part.'+format:'')+(kind.endsWith('pointer')?'#/components/schemas/Part':kind.includes('anchor')?'#part':'');
 const field={$dynamicRef:ref};
 const value={openapi:version,info:{title:'Bindings 雪',version:'api-version'},paths:{'/upload':{post:{requestBody:{content:{'multipart/form-data':{schema:{type:'object',properties:Object.fromEntries([[name,field]])},encoding:Object.fromEntries([[name,{contentType:'application/octet-stream'}]])}}},responses:{204:{description:'Done'}}}}},components:{schemas:remote?{}:{Part:part}},'x-exact':'EXACT','x-payload':{$dynamicAnchor:'part',$dynamicRef:'missing.json',contentEncoding:'base16'}};
 let shared;
 if(remote){
  if(kind.endsWith('pointer'))shared={components:{schemas:{Part:part}}};else shared=part;
 }
 if(kind==='static-anchor-with-dynamic-peer'){
  field.$dynamicRef='#part';value.components.schemas.Other={$id:'other', $dynamicAnchor:'part',type:'string',contentEncoding:'base16'};
 }
 const encode=value=>(format==='yaml'?'# Keep captured reference spelling\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
 return {root,resource:root,pointer:'/paths/~1upload/post',snapshot:'multipart-bindings-'+version+'-'+format,mediaType:'multipart/form-data',resources:[{id:root,text:encode(value),generation:2},...(shared?[{id:external,text:encode(shared),generation:3}]:[])],parts:[{name,kind:'string'}],files:[]};
}
const forms=['local-pointer','static-anchor','one-dynamic-anchor','external-root','external-anchor','external-dynamic-anchor','static-anchor-with-dynamic-peer'];
for(const version of versions)for(const format of ['yaml','json'])for(const form of forms)test(`${version} ${format} multipart ${form} uses the captured fixed annotation target`,async()=>{
 const input=packet(version,format,form),before=input.resources.map(r=>r.text),contract=analyse(input);assert.equal(contract.status,'complete',JSON.stringify(contract.findings));const result=await requestMultipartEncoding(input),transfer=result.parts.payload.string;assert.equal(transfer.encoding,'base64');assert.equal(transfer.schemaEncoded,true);assert.equal(transfer.source.resource,form.startsWith('external-')?input.resources[1].id:input.root);assert(transfer.source.pointer.endsWith('/contentEncoding'));assert(transfer.source.range[1]>transfer.source.range[0]);assert.deepEqual(input.resources.map(r=>r.text),before);
});
for(const version of versions)for(const format of ['yaml','json'])for(const kind of ['local-pointer','static-anchor','one-dynamic-anchor'])for(const shape of ['single','array'])test(`${version} ${format} ${kind} retains explicit ${shape} file hints`,async()=>{
 const input=packet(version,format,kind,'payload',true),before=input.resources.map(r=>r.text);input.parts=[];input.files=['payload'];input.fileShapes={payload:shape};const result=await requestMultipartEncoding(input);assert.equal(result.parts.payload.fileArray,shape==='array');assert.equal(result.parts.payload.string.encoding,'base64');assert.equal(result.parts.payload.string.schemaEncoded,true);
 const operation=requestOperation(input),media=operation.requestBody.content[0];assert.deepEqual(media.form.parts.payload.fileShapes,['single','array']);assert.deepEqual(input.resources.map(r=>r.text),before);
});
for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const name of ['','__proto__','constructor','雪/😀~field'])test(`${version} ${format} annotation binding retains literal part name ${JSON.stringify(name)}`,async()=>{
 const input=packet(version,format,'one-dynamic-anchor',name),result=await requestMultipartEncoding(input);assert.equal(Object.getPrototypeOf(result.parts),null);assert(Object.hasOwn(result.parts,name));assert.equal(result.parts[name].string.encoding,'base64');
});
for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} differing dynamic targets remain source-located unsupported`,async()=>{
 const input=packet(version,format,'one-dynamic-anchor'),value=YAML.parse(input.resources[0].text);value.components.schemas.Other={$id:'other', $dynamicAnchor:'part',type:'string',contentEncoding:'base16'};input.resources[0].text=format==='yaml'?YAML.stringify(value):JSON.stringify(value);const original=input.resources[0].text;await assert.rejects(requestMultipartEncoding(input),error=>error.code==='request.multipart.encoding.unsupported'&&error.kind==='unsupported'&&error.source.resource===input.root&&error.source.pointer.endsWith('/properties/payload'));assert.equal(input.resources[0].text,original);
});
for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} both reference applicators retain conflicting annotations`,async()=>{
 const input=packet(version,format,'local-pointer'),value=YAML.parse(input.resources[0].text),field=value.paths['/upload'].post.requestBody.content['multipart/form-data'].schema.properties.payload;field.$ref='#/components/schemas/Other';value.components.schemas.Other={type:'string',contentEncoding:'base16'};input.resources[0].text=format==='yaml'?YAML.stringify(value):JSON.stringify(value);await assert.rejects(requestMultipartEncoding(input),error=>error.code==='request.multipart.encoding.undefined'&&error.kind==='unsupported');
});
for(const format of ['yaml','json'])for(const [entryVersion,bodyVersion,mediaType]of [['3.2.1','3.1.2','multipart/mixed'],['3.1.2','3.2.1','multipart/form-data']])test(`${format} ${entryVersion} entry retains ${bodyVersion} named body ownership`,async()=>{
 const input=packet(entryVersion,format,'local-pointer','payload',true),value=YAML.parse(input.resources[0].text),operation=value.paths['/upload'].post,body=operation.requestBody,shared='file:///approved/body.'+format;
 body.content[mediaType]=body.content['multipart/form-data'];if(mediaType!=='multipart/form-data')delete body.content['multipart/form-data'];
 const resource={openapi:bodyVersion,info:{title:'Defining body',version:'1'},paths:{},components:{requestBodies:{Upload:body},schemas:value.components.schemas}};
 operation.requestBody={$ref:'body.'+format+'#/components/requestBodies/Upload'};value.components.schemas={};
 input.resources=[{...input.resources[0],text:format==='yaml'?YAML.stringify(value):JSON.stringify(value)},{id:shared,text:format==='yaml'?YAML.stringify(resource):JSON.stringify(resource),generation:4}];input.mediaType=mediaType;input.parts=[];input.files=['payload'];input.fileShapes={payload:'array'};
 const before=input.resources.map(resource=>resource.text),plan=requestOperation(input),selected=plan.requestBody.content[0];assert.equal(selected.family,bodyVersion.slice(0,3));assert.equal(selected.formBinding,'multipart-named');assert.deepEqual(selected.form.parts.payload.fileShapes,['single','array']);
 const projection=await requestMultipartEncoding(input);assert.equal(projection.parts.payload.fileArray,true);assert.equal(projection.parts.payload.string.source.resource,shared);
 const media=await requestFormMediaTypes({...input,parts:[],files:[{name:'payload',fallback:'application/octet-stream'}],choices:{}});assert.deepEqual(media.files,['application/octet-stream']);assert.deepEqual(input.resources.map(resource=>resource.text),before);
});
for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const topology of ['chain','recursion','escaped-pointer','resource-id','sibling'])test(`${version} ${format} multipart ${topology} retains graph resolution and annotation ownership`,async()=>{
 const input=packet(version,format,'local-pointer'),value=YAML.parse(input.resources[0].text),field=value.paths['/upload'].post.requestBody.content['multipart/form-data'].schema.properties.payload,schemas=value.components.schemas;
 let suffix='/components/schemas/Part/contentEncoding';
 if(topology==='chain'){
  schemas.Alias={$dynamicRef:'#/components/schemas/Part'};field.$dynamicRef='#/components/schemas/Alias';
 }else if(topology==='recursion'){
  schemas.Part.allOf=[{$dynamicRef:'#/components/schemas/Part'}];
 }else if(topology==='escaped-pointer'){
  schemas.Part={$defs:{'Part/~雪':schemas.Part}};field.$dynamicRef='#/components/schemas/Part/$defs/Part~1~0%E9%9B%AA';suffix='/components/schemas/Part/$defs/Part~1~0雪/contentEncoding';
 }else if(topology==='resource-id'){
  schemas.Part.$id='part-resource';field.$dynamicRef='part-resource';
 }else{
  delete schemas.Part.contentEncoding;field.contentEncoding='base64';suffix='/properties/payload/contentEncoding';
 }
 input.resources[0].text=format==='yaml'?YAML.stringify(value):JSON.stringify(value);const before=input.resources.map(resource=>resource.text),contract=analyse(input);assert.equal(contract.status,'complete',JSON.stringify(contract.findings));
 const result=await requestMultipartEncoding(input);assert.equal(result.parts.payload.string.encoding,'base64');assert.equal(result.parts.payload.string.schemaEncoded,true);assert(result.parts.payload.string.source.pointer.endsWith(suffix));assert.deepEqual(input.resources.map(resource=>resource.text),before);
});
for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const failure of ['unresolved','dialect'])test(`${version} ${format} ${failure} multipart references never become successful transfer projections`,async()=>{
 const input=packet(version,format,'local-pointer'),value=YAML.parse(input.resources[0].text);
 if(failure==='unresolved')value.paths['/upload'].post.requestBody.content['multipart/form-data'].schema.properties.payload.$dynamicRef='missing.yaml#/Part';
 else value.components.schemas.Part.$schema='https://dialects.example.invalid/unsupported';
 input.resources[0].text=format==='yaml'?YAML.stringify(value):JSON.stringify(value);const before=input.resources.map(resource=>resource.text);
 await assert.rejects(requestMultipartEncoding(input),error=>error.code===(failure==='unresolved'?'request.reference':'request.multipart.dialect.unsupported')&&error.source.resource===input.root&&error.source.range[1]>error.source.range[0]);assert.deepEqual(input.resources.map(resource=>resource.text),before);
});
for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const scoped of [false,true])test(`${version} ${format} external form anchor requires captured schema scope scoped=${scoped}`,async()=>{
 const input=packet(version,format,'one-dynamic-anchor'),value=YAML.parse(input.resources[0].text),media=value.paths['/upload'].post.requestBody.content['multipart/form-data'],part=value.components.schemas.Part;
 const schemas={Form:{$dynamicAnchor:'form',...media.schema},Part:part};media.schema={$dynamicRef:'./part.'+format+'#form'};value.components.schemas={};
 const shared=scoped?{$id:'part.'+format,$defs:schemas}:schemas;
 input.resources=[{...input.resources[0],text:format==='yaml'?YAML.stringify(value):JSON.stringify(value)},{id:'file:///approved/part.'+format,text:format==='yaml'?YAML.stringify(shared):JSON.stringify(shared),generation:3}];
 const before=input.resources.map(resource=>resource.text),contract=analyse(input);
 if(scoped){
  assert.equal(contract.status,'complete',JSON.stringify(contract.findings));const operation=requestOperation(input),result=await requestMultipartEncoding(input);assert.equal(operation.requestBody.content[0].form.shape.properties.payload.contentEncoding,'base64');assert.equal(result.parts.payload.string.encoding,'base64');assert.equal(result.parts.payload.string.source.resource,input.resources[1].id);assert.equal(result.parts.payload.string.source.pointer,'/$defs/Part/contentEncoding');
 }else{
  assert.equal(contract.status,'invalid');assert(contract.findings.some(finding=>finding.code==='reference.missing'));await assert.rejects(requestMultipartEncoding(input),error=>error.code==='request.reference'&&error.source.resource===input.root);
 }
 assert.deepEqual(input.resources.map(resource=>resource.text),before);
});
