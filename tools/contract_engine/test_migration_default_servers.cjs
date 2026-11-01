const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const dist=process.env.BUSYAPI_DEFAULT_SERVER_DIST||require('node:path').join(__dirname,'dist');
const {analyse}=require(dist+'/model.cjs'),{planMigration}=require(dist+'/migration.cjs');
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const targetVersion of ['3.0.4','3.1.2','3.2.1'])for(const servers of [undefined,[]])test(`${version} ${format} implicit Server ${servers?'empty':'absent'} survives migration to ${targetVersion}`,async()=>{
 const root='https://contracts.example.invalid/source/api.'+format,value={openapi:version,info:{title:'Implicit Server',version:'API-1'},...(servers?{servers}:{}),paths:{'/items':{get:{responses:{204:{description:'No body'}}}}}},text=format==='json'?JSON.stringify(value,null,2):'# Keep implicit Server\n'+YAML.stringify(value);
 const input={root,snapshot:'implicit-server',resources:[{id:root,text,generation:3}]},result=await planMigration({...input,targetVersion,destination:'file:///output/default/'});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);
 const output=result.outputs.find(output=>output.id===result.outputRoot),converted=YAML.parse(output.text);
 assert.equal(converted.openapi,targetVersion);assert.deepEqual(converted.paths,value.paths);
 assert.equal(new URL(converted.servers[0].url,output.id).href,new URL('/',root).href);
 assert.equal(analyse({root:output.id,snapshot:'target',resources:[{id:output.id,text:output.text,generation:0}]}).status,'complete');
 if(format==='yaml')assert(output.text.includes('# Keep implicit Server'));
 assert.equal(input.resources[0].text,text);
});
for(const format of ['yaml','json'])for(const reverse of [false,true])test(`${format} implicit Servers retain independent mixed-root retrievals reverse=${reverse}`,async()=>{
 const root='https://first.example.invalid/source/api.'+format,child='https://second.example.invalid/shared/child.'+format;
 const values=[{openapi:'3.0.4',info:{title:'First API',version:'API-1'},paths:{'/items':{get:{responses:{204:{description:'First no body'}}}}}},{openapi:'3.1.2',info:{title:'Second API',version:'API-2'},servers:[],paths:{'/items':{get:{responses:{204:{description:'No body'}}}}}}];
 const resources=values.map((value,index)=>({id:index?child:root,text:format==='json'?JSON.stringify(value,null,2):YAML.stringify(value),generation:index+1}));
 if(reverse)resources.reverse();const before=resources.map(resource=>resource.text),input={root,snapshot:'mixed',resources},result=await planMigration({...input,targetVersion:'3.2.1',destination:'file:///output/mixed/'});
 for(const entry of [root,child])assert.equal(analyse({...input,root:entry}).status,'complete');
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);
 for(const [title,origin]of [['First API','https://first.example.invalid/'],['Second API','https://second.example.invalid/']]){
  const output=result.outputs.find(output=>{if(!output.id.endsWith('.'+format))return false;return YAML.parse(output.text).info.title===title;});assert(output,title);
  const converted=YAML.parse(output.text);assert.equal(converted.openapi,'3.2.1');assert.equal(converted.servers[0].url,origin);
 }
 assert.deepEqual(resources.map(resource=>resource.text),before);
});
for(const format of ['yaml','json'])for(const reverse of [false,true])test(`${format} legacy cross-family Path Item refusal remains explicit reverse=${reverse}`,async()=>{
 const root='https://first.example.invalid/source/api.'+format,child='https://second.example.invalid/shared/child.'+format;
 const values=[{openapi:'3.0.4',info:{title:'First API',version:'API-1'},paths:{'/items':{$ref:child+'#/paths/~1items'}}},{openapi:'3.1.2',info:{title:'Second API',version:'API-2'},servers:[],paths:{'/items':{get:{responses:{204:{description:'No body'}}}}}}];
 const resources=values.map((value,index)=>({id:index?child:root,text:format==='json'?JSON.stringify(value,null,2):YAML.stringify(value),generation:index+1}));
 if(reverse)resources.reverse();const before=resources.map(resource=>resource.text),input={root,snapshot:'mixed',resources},result=await planMigration({...input,targetVersion:'3.2.1',destination:'file:///output/mixed/'});
 assert.equal(analyse(input).complete,false);assert(analyse(input).findings.some(finding=>finding.code==='reference.family.unsupported'));
 assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(problem=>problem.code==='migration.validation.incomplete'&&problem.reason==='source-incomplete'));
 assert.deepEqual(resources.map(resource=>resource.text),before);
});
for(const alias of [false,true])test(`YAML implicit Server alias=${alias} retains physical ownership`,async()=>{
 const root='https://contracts.example.invalid/alias.yaml',text='openapi: 3.0.4\ninfo: {title: "Aliased default", version: "1"}\nx-held: &held []\nservers: '+(alias?'*held':'[]')+'\nx-copy: *held\npaths: {/items: {get: {responses: {"204": {description: "No body"}}}}}\n',input={root,snapshot:'alias',resources:[{id:root,text,generation:1}]},result=await planMigration({...input,targetVersion:'3.1.2',destination:'file:///output/alias/'});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));
 const output=result.outputs.find(output=>output.id===result.outputRoot),converted=YAML.parse(output.text);
 assert.deepEqual(converted['x-held'],[]);assert.deepEqual(converted['x-copy'],[]);
 assert(output.text.includes('x-held: &held []\n'));assert(output.text.includes('x-copy: *held\n'));
 assert.equal(converted.servers[0].url,'https://contracts.example.invalid/');
 if(alias)assert(result.presentationChanges.some(change=>change.resource===root&&change.pointer==='/servers'));
 assert.equal(input.resources[0].text,text);
});
for(const format of ['yaml','json'])test(`3.2 ${format} implicit Server uses captured retrieval rather than $self`,async()=>{
 const root='file:///approved/api.'+format,retrieval='https://retrieval.example.invalid/source/api.'+format,identity='https://logical.example.invalid/identity',value={openapi:'3.2.1',$self:identity,info:{title:'Logical identity',version:'API-1'},paths:{'/items':{get:{responses:{204:{description:'No body'}}}}}},text=format==='json'?JSON.stringify(value,null,2):YAML.stringify(value),resources=[{id:root,aliases:[retrieval],text,generation:7}],result=await planMigration({root,snapshot:'logical-default',resources,targetVersion:'3.2.1',destination:'file:///output/logical/'});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);
 const output=result.outputs.find(output=>output.id===result.outputRoot),converted=YAML.parse(output.text);
 assert.equal(converted.$self,identity);assert.equal(converted.servers[0].url,new URL('/',retrieval).href);assert.notEqual(converted.servers[0].url,new URL('/',identity).href);
 assert.equal(resources[0].text,text);assert.deepEqual(resources[0].aliases,[retrieval]);
});
