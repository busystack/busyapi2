const assert=require('node:assert/strict'),{test}=require('node:test');
const base=process.env.BUSYAPI_FORM_DOWNGRADE_BASELINE||__dirname;
const {planMigration}=require(base+'/dist/migration.cjs');
const {SourceDocument}=require(base+'/dist/document.cjs');
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const style of format==='yaml'?['block','flow']:['json'])for(const query of [true,false]){
 test(`${version} ${format} ${style} query=${query} primitive URL-encoded form downgrade retains source values and native request invariants`,async()=>{
  const root='file:///approved/api.'+format;
  const document={openapi:version,info:{title:'Form 雪',version:'unrelated'},servers:[{url:'https://api.invalid'}],paths:{'/items':{post:{parameters:[{name:'tenant',in:'query',schema:{type:'string'}}],requestBody:{required:true,content:{'application/x-www-form-urlencoded':{schema:{type:'object',required:['name'],properties:{count:{type:'integer',minimum:0,default:0},name:{type:'string',minLength:1,description:'Name 雪'},flag:{type:'boolean',default:false},exact:{type:'integer',enum:['EXACT']}}}}}},responses:{204:{description:'No body'}}}}}};
  if(!query)delete document.paths['/items'].post.parameters;
  const YAML=require(base+'/node_modules/yaml');
  const serialized=style==='block'?YAML.stringify(document).replace('EXACT','9007199254740993.00'):JSON.stringify(document,null,2).replace('"EXACT"','9007199254740993.00');
  const text=format==='json'?serialized:style==='block'?'# Keep form source\r\n'+serialized.replaceAll('\n','\r\n'):'# Keep form source\r\n'+Object.entries(document).map(([name,value])=>name+': '+JSON.stringify(value)).join('\r\n').replace('"EXACT"','9007199254740993.00')+'\r\n';
  const input={root,snapshot:'form-downgrade-'+version+'-'+format,targetVersion:'2.0',destination:'file:///output/review/',resources:[{id:root,text,generation:1,identity:'source'}]};
  const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.status,'faithfully-convertible');assert.equal(input.resources[0].text,text);assert.equal(result.invariants.requests,'effective-url-serialization-security-and-media');
  const output=result.outputs.find(resource=>resource.id===result.outputRoot);assert(output);const doc=new SourceDocument(output.text,output.id);
  assert.equal(doc.node('/swagger').value,'2.0');assert(!doc.nodes.has('/openapi'));assert(!doc.nodes.has('/paths/~1items/post/requestBody'));
  assert.deepEqual(doc.node('/paths/~1items/post/consumes').value,['application/x-www-form-urlencoded']);
  const parameters=doc.node('/paths/~1items/post/parameters').value;
  assert.deepEqual(parameters.map(p=>[p.in,p.name]),[...(query?[['query','tenant']]:[]),['formData','count'],['formData','name'],['formData','flag'],['formData','exact']]);
  const offset=query?1:0;
  assert.equal(parameters[offset].required===true,false);assert.equal(parameters[offset+1].required,true);assert.equal(parameters[offset+2].required===true,false);
  assert.equal(parameters[offset].default,0);assert.equal(parameters[offset+2].default,false);assert.equal(parameters[offset+1].minLength,1);assert.equal(parameters[offset+1].description,'Name 雪');
  assert.equal(doc.dataJson('/paths/~1items/post/parameters/'+(offset+3)+'/enum/0'),'9007199254740993.00');
  if(format==='yaml')assert(output.text.startsWith('# Keep form source\r\n'));
 });
}
for(const format of ['yaml','json'])for(const variant of ['closed','body-description','object-field','binary-field','optional-required','missing-required-flag','schema-consumer']){
 test(`${format} ${variant} form mapping reports an exact blocker and never publishes a partial result`,async()=>{
  const root='file:///approved/api.'+format,media='application/x-www-form-urlencoded';
  const schema={type:'object',required:['name'],properties:{name:{type:'string'}}};
  const body={required:true,content:{[media]:{schema}}};
  const document={openapi:'3.0.4',info:{title:'Located refusal',version:'1'},servers:[{url:'https://api.invalid'}],paths:{'/items':{post:{requestBody:body,responses:{204:{description:'No body'}}}}}};
  let code;
  if(variant==='closed'){schema.additionalProperties=false;code='migration.form.object-constraint';}
  if(variant==='body-description'){body.description='Keep this group description';code='migration.form.body-metadata';}
  if(variant==='object-field'){schema.properties.name={type:'object'};code='migration.form.field-type';}
  if(variant==='binary-field'){schema.properties.name.format='binary';code='migration.form.binary';}
  if(variant==='optional-required'){body.required=false;code='migration.form.presence';}
  if(variant==='missing-required-flag'){delete body.required;code='migration.form.presence';}
  if(variant==='schema-consumer'){document.components={schemas:{Use:{$ref:'#/paths/~1items/post/requestBody/content/application~1x-www-form-urlencoded/schema'}}};code='migration.form.schema-consumer';}
  const YAML=require(base+'/node_modules/yaml'),text=format==='json'?JSON.stringify(document):YAML.stringify(document),resources=[{id:root,text,generation:1}];
  const result=await planMigration({root,snapshot:'refusal',resources,targetVersion:'2.0',destination:'file:///output/review/'});
  assert.equal(result.complete,false);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
  assert(result.problems.some(p=>p.code===code&&p.resource===root&&p.pointer&&p.range[1]>p.range[0]),JSON.stringify(result.problems));
  assert.equal(resources[0].text,text);
 });
}

for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json']){
 test(`${version} ${format} explicit primitive array encodings preserve Swagger collection rules`,async()=>{
  const root='file:///approved/api.'+format,media='application/x-www-form-urlencoded';
  const properties=Object.fromEntries(['multi','csv','ssv','pipes'].map(name=>[name,{type:'array',minItems:1,maxItems:4,uniqueItems:true,items:{type:'string',minLength:1,enum:['one','two']}}]));
  const encoding={multi:{style:'form'},csv:{explode:false},ssv:{style:'spaceDelimited',explode:false},pipes:{style:'pipeDelimited',allowReserved:false}};
  const document={openapi:version,info:{title:'Arrays',version:'1'},servers:[{url:'https://api.invalid'}],paths:{'/items':{post:{requestBody:{required:true,content:{[media]:{schema:{type:'object',required:['multi'],properties},encoding}}},responses:{204:{description:'No body'}}}}}};
  const YAML=require(base+'/node_modules/yaml'),text=format==='json'?JSON.stringify(document):YAML.stringify(document);
  const result=await planMigration({root,snapshot:'arrays',targetVersion:'2.0',destination:'file:///output/review/',resources:[{id:root,text,generation:1}]});
  assert.equal(result.complete,true,JSON.stringify(result.problems));
  const output=result.outputs.find(resource=>resource.id===result.outputRoot),doc=new SourceDocument(output.text,output.id);
  const parameters=doc.node('/paths/~1items/post/parameters').value;
  assert.deepEqual(parameters.map(p=>[p.name,p.type,p.collectionFormat]),['multi','csv','ssv','pipes'].map(name=>[name,'array',name]));
  for(const parameter of parameters){assert.equal(parameter.allowEmptyValue,true);assert.equal(parameter.minItems,1);assert.equal(parameter.maxItems,4);assert.equal(parameter.uniqueItems,true);assert.deepEqual({...parameter.items},properties.multi.items);}
 });
}
for(const variant of ['unstyled','reserved','exploded-delimited','nested','item-description','item-reference','encoding-extension','content-encoding','separator-in-item','unbounded-separated'])test(`array form ${variant} never claims faithful conversion`,async()=>{
 const root='file:///approved/api.yaml',media='application/x-www-form-urlencoded',property={type:'array',items:{type:'string'}},rule={style:'form'};
 const content={schema:{type:'object',required:['values'],properties:{values:property}},encoding:{values:rule}};
 const document={openapi:variant==='unstyled'?'3.2.1':'3.0.4',info:{title:'Arrays',version:'1'},servers:[{url:'https://api.invalid'}],paths:{'/items':{post:{requestBody:{required:true,content:{[media]:content}},responses:{204:{description:'No body'}}}}}};
 if(variant==='unstyled')delete content.encoding;
 if(variant==='reserved')rule.allowReserved=true;
 if(variant==='exploded-delimited'){rule.style='spaceDelimited';rule.explode=true;}
 if(variant==='nested')property.items={type:'array',items:{type:'string'}};
 if(variant==='item-description')property.items.description='Do not drop';
 if(variant==='item-reference'){document.components={schemas:{Value:{type:'string'}}};property.items={$ref:'#/components/schemas/Value'};}
 if(variant==='encoding-extension')rule['x-keep']='metadata';
 if(variant==='content-encoding')content.encoding.values={contentType:'application/json'};
 if(variant==='separator-in-item'){rule.explode=false;property.items.enum=['one,two'];}
 if(variant==='unbounded-separated')rule.explode=false;
 const text=require(base+'/node_modules/yaml').stringify(document),resources=[{id:root,text,generation:1}];
 const result=await planMigration({root,snapshot:'array-refusal',resources,targetVersion:'2.0',destination:'file:///output/review/'});
 assert.equal(result.complete,false);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
 assert(result.problems.some(p=>p.code.startsWith('migration.form.')&&p.resource===root&&p.pointer&&p.range[1]>p.range[0]),JSON.stringify(result.problems));assert.equal(resources[0].text,text);
});
