const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml'),{createHash}=require('node:crypto');
const {planMigration}=require('./dist/migration.cjs'),{analyse}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const modern=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'],older=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'];
function capture(version,format,mode='presence'){
 const schema={type:'object',properties:{trigger:{},value:{type:'integer',enum:['EXACT']},other:{}},dependentRequired:{trigger:['value']}};
 if(mode==='multiple')schema.dependentRequired={trigger:['value','other'],value:['trigger']};
 if(mode==='unconditional')schema.required=['trigger'];
 if(mode==='tautology')schema.dependentRequired={trigger:['trigger'],value:[]};
 if(mode==='allOf')schema.allOf=[{maxProperties:2}];
 if(mode==='nullable')schema.type=['object','null'];
 if(mode==='readOnly'||mode==='writeOnly')schema.properties.value[mode]=true;
 if(mode==='recursive')schema.properties.next={$ref:'#/components/schemas/Model'};
 const doc={openapi:version,info:{title:'Dependencies 雪',version:'API-1'},paths:{},components:{schemas:{Model:schema}},'x-payload':{dependentRequired:{trigger:['opaque']},number:'EXACT',zero:0,no:false,nil:null}};
 const root='file:///approved/api.'+format,text=(format==='json'?JSON.stringify(doc):'# Preserve CRLF\r\n'+YAML.stringify(doc).replaceAll('\n','\r\n')).replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00'),identity=createHash('sha256').update(text).digest('hex');
 return{root,snapshot:identity,resources:[{id:root,text,generation:1,identity}],destination:'file:///output/dependencies/'};
}
function after(result){return{root:result.outputRoot,snapshot:result.identity,resources:result.outputs.map(r=>({id:r.id,text:r.text,generation:0,aliases:Object.entries(result.manifest.resourceMappings).filter(([,p])=>p===r.path).map(([uri])=>uri)}))};}
async function outcomes(input,pointer,samples,subject='response-body'){
 const result=await evaluateSchemas({...input,runtimeInstances:samples.map(text=>({subject,location:'application/json',text,schema:{resource:input.root,pointer}}))});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert(!result.findings.some(f=>f.severity==='error'),JSON.stringify(result.findings));return result.runtimeEvaluations.map(r=>r.valid);
}
const samples=['{}','{"trigger":false}','{"trigger":0}','{"trigger":null}','{"trigger":""}','{"trigger":false,"value":9007199254740993}','{"trigger":0,"value":9007199254740993,"other":false}','{"value":9007199254740993}','{"trigger":false,"value":9007199254740992}','null','false','0','[]','{"trigger":false,"value":9007199254740993,"next":{"trigger":0}}'];
for(const version of modern)for(const format of ['yaml','json'])for(const targetVersion of older)for(const mode of ['presence','multiple','unconditional','tautology','allOf','nullable','readOnly','writeOnly','recursive'])test(`${version} ${format} ${mode} dependencies retain presence and direction in ${targetVersion}`,async()=>{
 const input=capture(version,format,mode),original=input.resources.map(r=>r.text),result=await planMigration({...input,targetVersion});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);assert.equal(result.producerVersion,'22');const output=after(result),entry=result.outputs.find(r=>r.id===result.outputRoot),data=YAML.parse(entry.text);
 assert.equal(data.openapi,targetVersion);assert.equal(data.info.version,'API-1');assert(!Object.hasOwn(data.components.schemas.Model,'dependentRequired'));assert.equal(data['x-payload'].dependentRequired.trigger[0],'opaque');assert(entry.text.includes('9007199254740993.00'));if(format==='yaml')assert(entry.text.startsWith('# Preserve CRLF\r\n'));
 assert.equal(analyse(output).status,'complete');
 for(const subject of ['request-body','response-body']){
  const before=await outcomes(input,'/components/schemas/Model',samples,subject),actual=await outcomes(output,'/components/schemas/Model',samples,subject);assert.deepEqual(actual,before);
  if(mode==='presence')assert.deepEqual(before,[true,false,false,false,false,true,true,true,false,false,false,false,false,true]);
 }
 assert.deepEqual(input.resources.map(r=>r.text),original);
});
for(const version of modern)for(const format of ['yaml','json'])for(const mode of ['unconditional','tautology','presence'])test(`${version} ${format} ${mode} Swagger representability is evaluated explicitly`,async()=>{
 const input=capture(version,format,mode),original=input.resources[0].text,result=await planMigration({...input,targetVersion:'2.0'});
 assert.equal(result.complete,mode!=='presence',JSON.stringify(result.problems));if(result.complete){assert.equal(YAML.parse(result.outputs[0].text).swagger,'2.0');assert.deepEqual(await outcomes(after(result),'/definitions/Model',samples),await outcomes(input,'/components/schemas/Model',samples));}
 else{assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);const found=result.problems.find(p=>p.code==='migration.schema.dependency-conditional');assert(found,JSON.stringify(result.problems));assert.equal(found.reason,'implementation');assert.equal(found.pointer,'/components/schemas/Model/dependentRequired/trigger');}assert.equal(input.resources[0].text,original);
});
for(const version of modern)for(const format of ['yaml','json'])for(const name of ['雪/~','','__proto__'])test(`${version} ${format} dependency property ${JSON.stringify(name)} retains decoded names`,async()=>{
 const input=capture(version,format),resource=input.resources[0],doc=new SourceDocument(resource.text,resource.id);resource.text=doc.set('/components/schemas/Model',{type:'object',dependentRequired:{[name]:['value']},properties:{[name]:{},value:{type:'string'}}});const result=await planMigration({...input,targetVersion:'3.0.4'});assert.equal(result.complete,true,JSON.stringify(result.problems));const values=['{}',JSON.stringify({[name]:false}),JSON.stringify({[name]:false,value:''})];assert.deepEqual(await outcomes(after(result),'/components/schemas/Model',values),[true,false,true]);assert.deepEqual(await outcomes(input,'/components/schemas/Model',values),[true,false,true]);
});
for(const version of modern)for(const format of ['yaml','json'])test(`${version} ${format} dual-role dependency map blocks instead of changing referenced schema meaning`,async()=>{
 const input=capture(version,format),resource=input.resources[0],doc=new SourceDocument(resource.text,resource.id);resource.text=doc.set('/components/schemas/Use',{$ref:'#/components/schemas/Model/dependentRequired'});const before=resource.text,result=await planMigration({...input,targetVersion:'3.0.4'});assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);const found=result.problems.find(p=>p.code==='migration.schema.dependency-shared-role');assert(found,JSON.stringify(result.problems));assert.equal(found.pointer,'/components/schemas/Model/dependentRequired');assert(found.range[1]>found.range[0]);assert.equal(resource.text,before);
});
for(const mode of ['ordinary','tautology','alias'])test(`YAML ${mode} dependency comments and shared syntax retain safe ownership`,async()=>{
 const input=capture('3.2.1','yaml'),r=input.resources[0];r.text=`# Original\r\nopenapi: 3.2.1\r\ninfo: {title: Comments, version: API-1}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    Model:\r\n      type: object\r\n      dependentRequired: # Dependency map\r\n        # Trigger entry\r\n        trigger: ${mode==='alias'?'&names ':''}\r\n          # Required name\r\n          - '${mode==='tautology'?'trigger':'value'}' # Inline name\r\n      properties: {trigger: {}, value: {}}\r\n${mode==='alias'?'x-shared: *names\r\n':''}`;const original=r.text,result=await planMigration({...input,targetVersion:'3.0.4'});
 if(mode==='alias'){assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code.includes('shared')||p.code.includes('alias')),JSON.stringify(result.problems));}
 else{assert.equal(result.complete,true,JSON.stringify(result.problems));const text=result.outputs[0].text;for(const comment of ['# Original','# Dependency map','# Trigger entry','# Required name','# Inline name'])assert.equal(text.split(comment).length-1,1,comment+'\n'+text);assert(text.includes('      properties: {trigger: {}, value: {}}\r\n'));}
 assert.equal(r.text,original);
});
for(const version of modern)for(const format of ['yaml','json'])test(`${version} ${format} captured external dependency schema retains recursion and resource ownership`,async()=>{
 const input=capture(version,format,'recursive'),r=input.resources[0],doc=new SourceDocument(r.text,r.id),model='file:///approved/model.yaml';
 const text=doc.dataJson('/components/schemas/Model').replaceAll('#/components/schemas/Model','#');
 r.text=doc.set('/components/schemas/Model',{$ref:'./model.yaml'});input.resources.push({id:model,text:'# External owner\r\n$schema: https://json-schema.org/draft/2020-12/schema\r\n'+'allOf:\r\n  - '+text+'\r\n',generation:2});
 const original=input.resources.map(r=>r.text),result=await planMigration({...input,targetVersion:'3.0.4'});assert.equal(result.complete,true,JSON.stringify(result.problems));assert(result.outputs.some(r=>r.text.includes('# External owner')));assert.deepEqual(await outcomes(after(result),'/components/schemas/Model',samples),await outcomes(input,'/components/schemas/Model',samples));assert.deepEqual(input.resources.map(r=>r.text),original);
});
for(const format of ['yaml','json'])for(const invalid of [false,[],{trigger:false},{trigger:['value','value']},{trigger:[0]}])test(`${format} malformed dependencies ${JSON.stringify(invalid)} cannot publish a successful conversion`,async()=>{
 const input=capture('3.1.2',format),r=input.resources[0];r.text=new SourceDocument(r.text,r.id).set('/components/schemas/Model/dependentRequired',invalid);const original=r.text,result=await planMigration({...input,targetVersion:'3.0.4'});assert.equal(result.complete,false);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);const found=result.problems.find(p=>p.pointer.startsWith('/components/schemas/Model'));assert(found,JSON.stringify(result.problems));assert(found.range[1]>found.range[0]);assert.equal(r.text,original);
});
for(const flag of ['readOnly','writeOnly'])test(`required-trigger dependency keeps ${flag} direction assertions separated`,async()=>{
 const input=capture('3.2.1','yaml','unconditional'),r=input.resources[0];r.text=new SourceDocument(r.text,r.id).set('/components/schemas/Model/properties/value/'+flag,true);const result=await planMigration({...input,targetVersion:'3.0.4'});assert.equal(result.complete,true,JSON.stringify(result.problems));for(const subject of ['request-body','response-body'])assert.deepEqual(await outcomes(after(result),'/components/schemas/Model',samples,subject),await outcomes(input,'/components/schemas/Model',samples,subject));
});
for(const tautology of [false,true])test(`flow dependency tautology=${tautology} retains repeated comments exactly once per authored occurrence`,async()=>{
 const input=capture('3.2.1','yaml'),r=input.resources[0];r.text=`openapi: 3.2.1\ninfo: {title: Flow, version: API-1}\npaths: {}\ncomponents:\n  schemas:\n    Model: {type: object, dependentRequired: {trigger: [\n      # Repeated authored comment\n      # Repeated authored comment\n      ${tautology?'trigger':'value'}]}, properties: {trigger: {}, value: {}}}\n`;const original=r.text,result=await planMigration({...input,targetVersion:'3.0.4'});assert.equal(result.complete,true,JSON.stringify(result.problems));const text=result.outputs[0].text;assert.equal(text.split('# Repeated authored comment').length-1,2,text);assert.deepEqual(await outcomes(after(result),'/components/schemas/Model',['{}','{"trigger":false}','{"trigger":false,"value":null}']),[true,tautology,true]);assert.equal(r.text,original);
});
for(const version of modern)for(const format of ['yaml','json'])for(const mode of ['composition','static-dynamic','chain','cycle','unseeded'])test(`${version} ${format} ${mode} dependency presence proof distinguishes faithful Swagger conversion`,async()=>{
 const input=capture(version,format),r=input.resources[0];let doc=new SourceDocument(r.text,r.id);
 if(mode==='composition'||mode==='static-dynamic'){
  r.text=doc.set('/components/schemas/Required',{required:['trigger']});doc=new SourceDocument(r.text,r.id);
  r.text=doc.set('/components/schemas/Model/'+(mode==='composition'?'allOf':'$dynamicRef'),mode==='composition'?[{$ref:'#/components/schemas/Required'}]:'#/components/schemas/Required');
 }else{
  const schema={type:'object',...(mode!=='unseeded'?{allOf:[{required:['start']}]}:{}),dependentRequired:mode==='cycle'?{start:['trigger'],trigger:['start','value']}:mode==='chain'?{start:['trigger'],trigger:['value']}:{trigger:['value'],value:['trigger']},properties:{start:{},trigger:{},value:{type:'integer',enum:['EXACT']}}};
  r.text=doc.set('/components/schemas/Model',schema).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
 }
 const original=r.text,result=await planMigration({...input,targetVersion:'2.0'});assert.equal(result.complete,mode!=='unseeded',JSON.stringify(result.problems));
 if(result.complete){const values=['{}','{"trigger":false}','{"trigger":false,"value":9007199254740993}','{"start":false}','{"start":false,"trigger":0}','{"start":false,"trigger":null,"value":9007199254740993}','{"start":false,"trigger":null,"value":9007199254740992}','null','false','0'];assert.deepEqual(await outcomes(after(result),'/definitions/Model',values),await outcomes(input,'/components/schemas/Model',values));}
 else{assert.deepEqual(result.outputs,[]);const found=result.problems.find(p=>p.code==='migration.schema.dependency-conditional');assert(found);assert.equal(found.reason,'implementation');}
 assert.equal(r.text,original);
});
