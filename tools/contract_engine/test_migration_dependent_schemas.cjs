const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs'),{analyse}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs'),{SourceDocument}=require('./dist/document.cjs');
const modern=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'],older=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'];
const samples=['null','false','0','""','[]','{}','{"trigger":false}','{"trigger":0}','{"trigger":null}','{"trigger":""}','{"trigger":false,"value":9007199254740993}','{"trigger":0,"value":9007199254740992}','{"value":9007199254740992}'];
function capture(version,format,mode='untyped'){
 const child={type:'object',required:['value'],properties:{value:{type:'integer',enum:['EXACT']}}};
 const schema={dependentSchemas:{trigger:mode==='false'?false:mode==='true'?true:child}};
 if(mode==='object'||mode==='required'||mode==='required-ref')schema.type='object';
 if(mode==='nullable')schema.type=['object','null'];
 if(mode==='required')schema.required=['trigger'];
 if(mode==='composition')schema.allOf=[{maxProperties:2}];
 if(mode==='recursive')child.properties.next={$ref:'#/components/schemas/Model'};
 if(mode==='escaped')schema.dependentSchemas=Object.fromEntries(['trig/~雪','__proto__',''].map(name=>[name,child]));
 if(mode==='nested')schema.dependentSchemas.trigger={dependentSchemas:{nested:child}};
 if(mode==='static-dynamic')schema.dependentSchemas.trigger={$dynamicRef:'#/components/schemas/Constraint'};
 if(mode==='required-ref')schema.allOf=[{$ref:'#/components/schemas/Required'}];
 if(mode==='empty')schema.dependentSchemas={};
 const document={openapi:version,info:{title:'Conditional schema 雪',version:'API-1'},paths:{},components:{schemas:{Model:schema,...(mode==='static-dynamic'?{Constraint:child}:{}),...(mode==='required-ref'?{Required:{required:['trigger']}}:{})}},'x-literal':{dependentSchemas:{trigger:false},exact:'EXACT',nil:null,empty:'',no:false,zero:0}};
 const root='file:///approved/api.'+format,text=(format==='json'?JSON.stringify(document):'# Keep CRLF 雪\r\n'+YAML.stringify(document,{aliasDuplicateObjects:false}).replaceAll('\n','\r\n')).replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
 return{root,snapshot:'captured-'+version+'-'+format+'-'+mode,resources:[{id:root,text,generation:1,identity:'owned'}],destination:'file:///output/dependent-schemas/'};
}
function after(result){return{root:result.outputRoot,snapshot:result.identity,resources:result.outputs.map(output=>({id:output.id,text:output.text,generation:0,aliases:Object.entries(result.manifest.resourceMappings).filter(([,path])=>path===output.path).map(([uri])=>uri)}))};}
async function outcomes(input,pointer,values=samples,subject='response-body'){
 const result=await evaluateSchemas({...input,runtimeInstances:values.map(text=>({subject,location:'application/json',text,schema:{resource:input.root,pointer}}))});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert(!result.findings.some(finding=>finding.severity==='error'),JSON.stringify(result.findings));return result.runtimeEvaluations.map(result=>result.valid);
}
async function faithful(input,targetVersion,values=samples){
 const original=input.resources.map(resource=>resource.text),result=await planMigration({...input,targetVersion});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);assert.equal(result.producerVersion,'30');assert(result.changes.length>0);
 const output=after(result),data=YAML.parse(result.outputs.find(output=>output.id===result.outputRoot).text),pointer=targetVersion==='2.0'?'/definitions/Model':'/components/schemas/Model';
 assert.equal(data.swagger??data.openapi,targetVersion);assert.equal(data.info.version,'API-1');assert.deepEqual(data['x-literal'].dependentSchemas,{trigger:false});assert(result.outputs.some(output=>output.text.includes('9007199254740993.00')));assert(!Object.hasOwn(data.swagger?data.definitions.Model:data.components.schemas.Model,'dependentSchemas'));
 assert.equal(analyse(output).status,'complete');
 for(const subject of ['request-body','response-body'])assert.deepEqual(await outcomes(output,pointer,values,subject),await outcomes(input,'/components/schemas/Model',values,subject));
 assert.deepEqual(input.resources.map(resource=>resource.text),original);return{result,output,pointer};
}
for(const version of modern)for(const format of ['yaml','json'])for(const targetVersion of older)for(const mode of ['untyped','object','nullable','false','true'])test(`${version} ${format} ${mode} dependentSchemas retains whole-instance conditions in ${targetVersion}`,async()=>{
 const input=capture(version,format,mode),{result}=await faithful(input,targetVersion);
 if(mode==='untyped')assert.deepEqual(await outcomes(input,'/components/schemas/Model'),[true,true,true,true,true,true,false,false,false,false,true,false,true]);
 if(format==='yaml')assert(result.outputs[0].text.startsWith('# Keep CRLF 雪\r\n'));
});
for(const version of modern)for(const format of ['yaml','json'])for(const mode of ['required','required-ref','untyped','object'])test(`${version} ${format} ${mode} dependentSchemas distinguishes faithful Swagger targets`,async()=>{
 const input=capture(version,format,mode);
 if(mode.startsWith('required'))await faithful(input,'2.0');
 else{const original=input.resources[0].text,result=await planMigration({...input,targetVersion:'2.0'});assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);const finding=result.problems.find(problem=>problem.code==='migration.schema.dependency-conditional');assert(finding,JSON.stringify(result.problems));assert.equal(finding.reason,'implementation');assert.equal(finding.pointer,'/components/schemas/Model/dependentSchemas/trigger');assert(finding.range[1]>finding.range[0]);assert.equal(input.resources[0].text,original);}
});
for(const format of ['yaml','json'])for(const mode of ['composition','recursive','nested','static-dynamic','escaped','empty'])test(`${format} ${mode} dependentSchemas keeps composition and source ownership`,async()=>{
 const values=[...samples,'{"trigger":false,"value":9007199254740993,"next":{"trigger":null}}','{"trigger":false,"nested":0}','{"trigger":false,"nested":0,"value":9007199254740993}','{"trig/~雪":false}','{"__proto__":0}','{"":null}','{"__proto__":false,"value":9007199254740993}'];
 await faithful(capture('3.2.1',format,mode),'3.0.4',values);
});
for(const format of ['yaml','json'])test(`${format} independently referenced dependent schema follows its moved owner`,async()=>{
 const input=capture('3.1.2',format),resource=input.resources[0];resource.text=new SourceDocument(resource.text,resource.id).set('/components/schemas/Alias',{$ref:'#/components/schemas/Model/dependentSchemas/trigger'});
 const {output}=await faithful(input,'3.0.4');assert.deepEqual(await outcomes(output,'/components/schemas/Alias'),await outcomes(input,'/components/schemas/Alias'));
});
for(const format of ['yaml','json'])test(`${format} external conditional schema retains exact content and repaired references`,async()=>{
 const input=capture('3.2.1',format),resource=input.resources[0],external='file:///approved/shared.json';resource.text=new SourceDocument(resource.text,resource.id).set('/components/schemas/Model/dependentSchemas/trigger',{$ref:'shared.json#/Constraint'});
 input.resources.push({id:external,text:'{"Constraint":{"required":["value"],"properties":{"value":{"enum":[9007199254740993.00]}}}}\r\n',generation:2,identity:'shared'});await faithful(input,'3.0.4');
});
for(const format of ['yaml','json'])for(const value of [false,[],{trigger:0},{trigger:null}])test(`${format} malformed dependentSchemas ${JSON.stringify(value)} cannot publish`,async()=>{
 const input=capture('3.1.2',format),resource=input.resources[0];resource.text=new SourceDocument(resource.text,resource.id).set('/components/schemas/Model/dependentSchemas',value);const original=resource.text,result=await planMigration({...input,targetVersion:'3.0.4'});
 assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert.deepEqual(result.changes,[]);assert(result.problems.some(problem=>problem.resource===resource.id&&problem.pointer.startsWith('/components/schemas/Model')&&problem.range[1]>problem.range[0]));assert.equal(resource.text,original);
});
test('independent map schema interpretation is a located blocker instead of a guessed context split',async()=>{
 const input=capture('3.1.2','json'),resource=input.resources[0];resource.text=new SourceDocument(resource.text,resource.id).set('/components/schemas/Map',{$ref:'#/components/schemas/Model/dependentSchemas'});const original=resource.text,result=await planMigration({...input,targetVersion:'3.0.4'});
 assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(problem=>problem.pointer==='/components/schemas/Model/dependentSchemas'));assert.equal(resource.text,original);
});
for(const flow of [false,true])test(`YAML flow=${flow} conditional schema retains repeated comments once per authored occurrence`,async()=>{
 const input=capture('3.2.1','yaml'),resource=input.resources[0];
 resource.text='openapi: 3.2.1\r\ninfo: {title: Comments, version: API-1}\r\npaths: {}\r\nx-literal: {dependentSchemas: {trigger: false}, exact: 9007199254740993.00}\r\ncomponents:\r\n  schemas:\r\n    Model:\r\n      dependentSchemas: '+(flow?'{\r\n        # Repeated conditional comment\r\n        # Repeated conditional comment\r\n        trigger: {required: [value]}}\r\n':'\r\n        # Repeated conditional comment\r\n        # Repeated conditional comment\r\n        trigger: {required: [value]}\r\n');
 const {result}=await faithful(input,'3.0.4');assert.equal(result.outputs[0].text.split('# Repeated conditional comment').length-1,2,result.outputs[0].text);
});
for(const placement of ['key','value'])test(`YAML ${placement} comments move once and comment-looking strings remain values`,async()=>{
 const input=capture('3.1.2','yaml'),resource=input.resources[0],literal='# Repeated conditional comment';
 const child='{required: [value], description: "'+literal+'"}';
 resource.text='openapi: 3.1.2\r\ninfo: {title: Comments, version: API-1}\r\npaths: {}\r\nx-literal: {dependentSchemas: {trigger: false}, exact: 9007199254740993.00}\r\ncomponents:\r\n  schemas:\r\n    Model:\r\n      dependentSchemas:\r\n'+(placement==='key'?'        trigger: # Repeated conditional comment\r\n          # Repeated conditional comment\r\n          '+child+'\r\n':'        trigger: '+child+' # Repeated conditional comment\r\n        # Repeated conditional comment\r\n');
 const {result}=await faithful(input,'3.0.4'),text=result.outputs[0].text,doc=new SourceDocument(text,result.outputRoot);
 assert.equal(doc.comments('',true).filter(range=>text.slice(...range)===literal).length,2,text);
 assert.equal([...doc.nodes.values()].filter(node=>node.pointer.endsWith('/description')&&node.value===literal).length,1,text);
});
test('YAML shared conditional schema cannot be rewritten through an ambiguous alias',async()=>{
 const input=capture('3.1.2','yaml'),resource=input.resources[0];resource.text='openapi: 3.1.2\ninfo: {title: Shared, version: API-1}\npaths: {}\ncomponents:\n  schemas:\n    Model:\n      dependentSchemas:\n        trigger: &held {required: [value]}\n    Independent: *held\n';
 const original=resource.text,result=await planMigration({...input,targetVersion:'3.0.4'});assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(problem=>problem.range[1]>problem.range[0]&&problem.resource===resource.id));assert.equal(resource.text,original);
});
