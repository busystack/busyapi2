const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {deriveBundle}=require('./dist/derived_bundle.cjs');
const bytes=Buffer.from([0,255,128]);
async function run(format,schema,{type='application/octet-stream',body=bytes,reusable=false,form=false}={}){
 const root='file:///swagger-binary/api.'+format;
 const response={description:'Original file response',schema};
 const value={swagger:'2.0',info:{title:'Original',version:'3.2.1'},produces:[type],paths:{'/file':{get:{responses:{200:reusable?{$ref:'#/responses/File'}:response}}}},...(reusable?{responses:{File:response}}:{})};
 const text=format==='json'?JSON.stringify(value):'# Keep 雪 and CRLF\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
 const at='/paths/~1file/get/responses/200';
 return evaluateSchemas({root,snapshot:format+type,resources:[{id:root,text,generation:1}],runtimeInstances:[{subject:'response-body',location:type,mediaType:type,mediaBase64:true,text:body.toString('base64'),...(form?{form:{resource:root,pointer:at},schema:{resource:root,pointer:at+'/schema'}}:{media:{resource:root,pointer:at}})}]});
}
function result(value,valid){
 assert.equal(value.complete,true,JSON.stringify(value.runtimeFindings));
 assert.equal(value.runtimeEvaluations.every(item=>item.complete===true&&item.valid===true),valid,JSON.stringify(value.runtimeFindings));
}
for(const format of ['yaml','json'])test(`Swagger ${format} file responses validate byte framing without JSON assertions`,async()=>{
 for(const type of ['application/octet-stream','application/xml','application/json'])for(const body of [bytes,Buffer.alloc(0)]){
  const value=await run(format,{type:'file'},{type,body});result(value,true);
  assert.equal(value.runtimeEvaluations[0].syntax,'file-entity-bytes');
 }
 result(await run(format,{type:'file'},{reusable:true}),true);
});
for(const format of ['yaml','json'])test(`Swagger ${format} ordinary binary schemas retain their Draft 4 string model`,async()=>{
 for(const schema of [{},{type:'string'},{type:'string',format:'binary',minLength:3,maxLength:3},{enum:['\u0000ÿ\u0080']}])result(await run(format,schema),true);
 for(const schema of [{type:'integer'},{type:'string',maxLength:2},{enum:[null]}])result(await run(format,schema),false);
});
for(const format of ['yaml','json'])test(`Swagger ${format} file responses retain opaque bytes for MIME types that otherwise select a form decoder`,async()=>{
 for(const type of ['application/x-www-form-urlencoded','multipart/form-data; boundary=Fixture'])for(const body of [bytes,Buffer.alloc(0),Buffer.from('not a form')]){
  const checked=await run(format,{type:'file'},{type,body,form:true});result(checked,true);
  assert.equal(checked.runtimeEvaluations[0].syntax,'file-entity-bytes');
 }
});
for(const format of ['yaml','json'])test(`Swagger ${format} absent response schema means no response content`,async()=>{
 result(await run(format,undefined,{body:Buffer.alloc(0)}),true);
 const value=await run(format,undefined);result(value,false);
 assert(value.runtimeFindings.some(finding=>finding.code==='runtime.response.body.forbidden'));
});

for(const format of ['yaml','json'])test(`Swagger ${format} an absent response schema needs no inferred Content-Type`,async()=>{
 const root='file:///swagger-binary/no-content.'+format,at='/paths/~1file/get/responses/200';
 const value={swagger:'2.0',info:{title:'Original',version:'1'},produces:['application/json'],paths:{'/file':{get:{responses:{200:{description:'No content'}}}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),input={root,snapshot:'untyped-response',resources:[{id:root,text,generation:1}]};
 for(const body of [Buffer.alloc(0),bytes]){
  const checked=await evaluateSchemas({...input,runtimeInstances:[{subject:'response-body',location:'body',text:body.toString('base64'),mediaBase64:true,media:{resource:root,pointer:at}}]});
  result(checked,body.length===0);assert.equal(checked.runtimeEvaluations[0].syntax,'no-response-content');
 }
});

for(const format of ['yaml','json'])test(`Swagger ${format} file references ignore siblings and retain unresolved failures`,async()=>{
 const root='file:///swagger-binary/references.'+format,at='/paths/~1file/get/responses/200';
 const encode=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);
 for(const [schema,target,valid]of [[{$ref:'#/responses/Other/schema',type:'file'},{type:'string'},false],[{$ref:'#/responses/Other/schema'},{type:'file'},true],[{$ref:'#/responses/Missing/schema',type:'file'},{type:'string'},undefined],[{$ref:'#/responses/Other/schema'},{$ref:'#/responses/Other/schema'},undefined]]){
  const value={swagger:'2.0',info:{title:'Original',version:'1'},produces:['application/json'],paths:{'/file':{get:{responses:{200:{description:'File context',schema}}}}},responses:{Other:{description:'Referenced schema',schema:target}}};
  const input={root,snapshot:'reference-siblings',resources:[{id:root,text:encode(value),generation:1}]};
  const plan=requestOperation({...input,resource:root,pointer:'/paths/~1file/get'}),projected=plan.responses[0].content[0].schema;
  if(valid===undefined){assert.equal(projected.file,false);assert.equal(typeof projected.fileIssue?.code,'string');}else{assert.equal(projected.file,valid);assert.equal(projected.fileIssue,undefined);}
  const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'response-body',location:'application/json',mediaType:'application/json',mediaBase64:true,text:bytes.toString('base64'),media:{resource:root,pointer:at}}]});
  if(valid===undefined){assert.equal(result.complete,false);assert(result.runtimeEvaluations.every(item=>item.valid===false&&item.complete===false));}
  else if(valid)assert(result.runtimeEvaluations.every(item=>item.complete===true&&item.valid===true),JSON.stringify(result));
  else assert(result.runtimeEvaluations.every(item=>item.valid===false),JSON.stringify(result));
 }
});

for(const format of ['yaml','json'])test(`Swagger ${format} ordinary media cannot reinterpret query parameters as body owners`,async()=>{
 const root='file:///swagger-binary/query.'+format;
 const value={swagger:'2.0',info:{title:'Query owner',version:'1'},paths:{'/file':{get:{parameters:[{name:'q',in:'query',type:'string'}],responses:{200:{description:'Empty'}}}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value);
 const result=await evaluateSchemas({root,snapshot:'invalid-owner',resources:[{id:root,text,generation:1}],runtimeInstances:[{subject:'request-body',location:'body',mediaType:'application/octet-stream',mediaBase64:true,text:bytes.toString('base64'),media:{resource:root,pointer:'/paths/~1file/get/parameters/0'}}]});
 assert.equal(result.complete,false);assert(result.runtimeFindings.some(finding=>finding.detailCode==='runtime.media.owner'&&finding.kind==='unsupported'));
});

for(const format of ['yaml','json'])test(`Swagger ${format} file is restricted to formData parameters and response schema roots`,async()=>{
 const root='file:///swagger-binary/file-context.'+format,at='/paths/~1file/get/responses/200';
 for(const schema of [{type:'object',properties:{data:{type:'file'}}},{$ref:'#/definitions/Invalid'}]){
  const value={swagger:'2.0',info:{title:'Invalid file context',version:'1'},produces:['application/octet-stream'],paths:{'/file':{get:{responses:{200:{description:'Invalid file',schema}}}}},definitions:{Invalid:{type:'file'}}};
  const text=format==='json'?JSON.stringify(value):YAML.stringify(value);
  const checked=await evaluateSchemas({root,snapshot:'file-context',resources:[{id:root,text,generation:1}],runtimeInstances:[{subject:'response-body',location:'body',mediaType:'application/octet-stream',mediaBase64:true,text:bytes.toString('base64'),media:{resource:root,pointer:at}}]});
  assert(checked.findings.some(finding=>finding.code==='schema.keyword.invalid'),JSON.stringify(checked));
  assert(checked.runtimeEvaluations.every(item=>item.valid===false&&item.complete===false),JSON.stringify(checked));
 }
});

for(const format of ['yaml','json'])test(`Swagger ${format} external file schemas inherit the response occurrence through chained escaped references`,async()=>{
 const root='file:///swagger-binary/external.'+format,fragment='file:///swagger-binary/file.'+format,at='/paths/~1file/get/responses/200';
 const encode=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);
 for(const nested of [false,true]){
  const value={swagger:'2.0',info:{title:'External file',version:'1'},produces:['application/octet-stream'],paths:{'/file':{get:{responses:{200:{description:'External file',schema:{$ref:'./file.'+format+(nested?'#/Alias':'')}}}}}}};
  const external=nested?{Alias:{$ref:'#/file~1~0'},'file/~':{type:'file'}}:{type:'file'};
  const resources=[{id:root,text:encode(value),generation:1},{id:fragment,text:encode(external),generation:2}],original=JSON.stringify(resources),input={root,snapshot:'external-file',resources};
  const plan=requestOperation({...input,resource:root,pointer:'/paths/~1file/get'});assert.equal(plan.responses[0].content[0].schema.file,true);
  const checked=await evaluateSchemas({...input,runtimeInstances:[{subject:'response-body',location:'body',mediaType:'application/octet-stream',mediaBase64:true,text:bytes.toString('base64'),media:{resource:root,pointer:at}}]});
  result(checked,true);assert.deepEqual(checked.findings,[]);assert.equal(checked.runtimeEvaluations[0].syntax,'file-entity-bytes');
  const bundled=deriveBundle({...input,outputId:'file:///swagger-binary/bundle.json'});assert.equal(bundled.complete,true);
  assert.equal(JSON.parse(bundled.output.text).swagger,'2.0');
  const derived=await evaluateSchemas({root:bundled.output.id,snapshot:'bundled-external-file',resources:[{id:bundled.output.id,text:bundled.output.text,generation:1}],runtimeInstances:[{subject:'response-body',location:'body',mediaType:'application/octet-stream',mediaBase64:true,text:bytes.toString('base64'),media:{resource:bundled.output.id,pointer:at}}]});
  result(derived,true);assert.deepEqual(derived.findings,[]);assert.equal(derived.runtimeEvaluations[0].syntax,'file-entity-bytes');
  assert.equal(JSON.stringify(resources),original);
 }
});

for(const format of ['yaml','json'])test(`Swagger ${format} sharing a response file fragment cannot permit body or nested file schemas`,async()=>{
 const root='file:///swagger-binary/shared.'+format,fragment='file:///swagger-binary/file.'+format;
 const ref={$ref:'./file.'+format},response={description:'Response root',schema:ref};
 const value={swagger:'2.0',info:{title:'Shared file context',version:'1'},consumes:['application/octet-stream'],produces:['application/octet-stream'],paths:{
  '/file':{get:{responses:{200:response}}},
  '/body':{post:{parameters:[{name:'body',in:'body',schema:ref}],responses:{204:{description:'Empty'}}}},
  '/nested':{get:{responses:{200:{description:'Nested',schema:{type:'object',properties:{file:ref}}}}}},
 }};
 const encode=value=>format==='json'?JSON.stringify(value):YAML.stringify(value),resources=[{id:root,text:encode(value),generation:1},{id:fragment,text:encode({type:'file'}),generation:2}];
 const checked=await evaluateSchemas({root,snapshot:'shared-file-context',resources,runtimeInstances:[{subject:'request-body',location:'body',mediaType:'application/octet-stream',mediaBase64:true,text:bytes.toString('base64'),media:{resource:root,pointer:'/paths/~1body/post/parameters/0'}}]});
 for(const pointer of ['/paths/~1body/post/parameters/0/schema/$ref','/paths/~1nested/get/responses/200/schema/properties/file/$ref'])assert(checked.findings.some(finding=>finding.code==='schema.file.context'&&(finding.occurrencePointer??finding.pointer)===pointer&&finding.range[1]>finding.range[0]),JSON.stringify(checked.findings));
 assert(checked.runtimeEvaluations.every(item=>item.valid===false&&item.complete===false),JSON.stringify(checked.runtimeEvaluations));
});
