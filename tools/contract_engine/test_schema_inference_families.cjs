const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {suggestSchema,planSchemaSuggestion}=require('./dist/schema_suggestion.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','2.0','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function fixture(version,format,sample){
 const root='file:///p/root.'+format,legacy=version==='2.0';
 const target=legacy?'/paths/~1items/get/responses/200':'/paths/~1items/get/responses/200/content/application~1json';
 const media={example:sample},response=legacy?{description:'Read',examples:{'application/json':sample}}:{description:'Read',content:{'application/json':media}};
 const document={...(legacy?{swagger:version,produces:['application/json']}:{openapi:version}),info:{title:'Keep 雪',version:'api'},paths:{'/items':{get:{responses:{200:response}}}}};
 const text=format==='json'?JSON.stringify(document):'# Keep\r\n'+YAML.stringify(document).replaceAll('\n','\r\n');
 return {root,resource:root,snapshot:'inference-families',pointer:target+(legacy?'/examples/application~1json':'/example'),target:{resource:root,pointer:target,generation:2},resources:[{id:root,text,generation:2}]};
}
function apply(input,plan){const resources=input.resources.map(resource=>({...resource}));for(const change of plan.changes)resources.find(r=>r.id===change.resource).text=change.after;return {...input,resources};}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} null inference creates a valid native null-only schema`,async()=>{
 const input=fixture(version,format,null),before=input.resources.map(r=>r.text),plan=planSchemaSuggestion(input);
 if(version==='2.0')assert.deepEqual(plan.schema,{type:'null'});
 else if(version.startsWith('3.0.'))assert.deepEqual(plan.schema,{type:'string',nullable:true,enum:[null]});
 else assert.deepEqual(plan.schema,{type:'null'});
 const result=await evaluateSchemas(apply(input,plan));assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert(!result.findings.some(f=>f.severity==='error'||f.code==='example.schema.incompatible'),JSON.stringify(result.findings));
 assert.deepEqual(input.resources.map(r=>r.text),before);
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} nullable inference validates using its native family rules`,async()=>{
 const input=fixture(version,format,{n:0,flag:false,text:'雪'}),before=input.resources.map(r=>r.text);
 {
  const plan=planSchemaSuggestion({...input,nullable:true}),result=await evaluateSchemas(apply(input,plan));
  if(version==='2.0')assert.deepEqual(plan.schema.type,['object','null']);
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert(!result.findings.some(f=>f.severity==='error'),JSON.stringify(result.findings));
 }
 assert.deepEqual(input.resources.map(r=>r.text),before);
});
for(const format of ['yaml','json'])test(`2.0 ${format} nullable null-only inference remains native`,()=>{
 const input=fixture('2.0',format,null);assert.deepEqual(planSchemaSuggestion({...input,nullable:true}).schema,{type:['null']});
});
for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} inference cannot assume an unsupported target dialect`,()=>{
 const input=fixture(version,format,{id:0}),document=format==='json'?JSON.parse(input.resources[0].text):YAML.parse(input.resources[0].text);
 document.jsonSchemaDialect='https://unsupported.invalid/dialect';input.resources[0].text=format==='json'?JSON.stringify(document):YAML.stringify(document);
 assert.throws(()=>suggestSchema(input),e=>e.code==='suggest.dialect'&&e.kind==='unsupported');
 assert.throws(()=>planSchemaSuggestion(input),e=>e.code==='suggest.dialect');
});
for(const version of ['2.0','3.0.4'])for(const format of ['yaml','json'])test(`${version} ${format} shared modern sample is inferred for its destination family`,async()=>{
 const input=fixture(version,format,0),id='file:///p/examples.'+format;
 const document={openapi:'3.2.1',info:{title:'Examples',version:'1'},paths:{},components:{examples:{Observed:{dataValue:{nil:null,list:[0,false],empty:[]}}}}};
 input.resources.push({id,generation:1,text:format==='json'?JSON.stringify(document):YAML.stringify(document)});
 input.resource=id;input.pointer='/components/examples/Observed/dataValue';
 const plan=planSchemaSuggestion(input),nil=plan.schema.properties.nil;
 assert.deepEqual(nil,version==='2.0'?{type:'null'}:{type:'string',nullable:true,enum:[null]});
 assert.deepEqual(plan.schema.properties.empty,{type:'array',items:{}});
 if(version==='2.0')assert.deepEqual(plan.schema.properties.list,{type:'array',items:{}});
 else assert.deepEqual(plan.schema.properties.list.items,{anyOf:[{type:'integer'},{type:'boolean'}]});
 const after=apply(input,plan),root=after.resources[0],documentAfter=format==='json'?JSON.parse(root.text):YAML.parse(root.text);
 // The target's existing numeric example differs intentionally from the sample;
 // structural validity must still hold while that mismatch remains visible.
 const result=await evaluateSchemas(after);assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert(!result.findings.some(f=>f.severity==='error'),JSON.stringify(result.findings));
 assert.equal(input.resources[1].text,after.resources[1].text);
});
