const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{requestOperation}=require('./dist/execution.cjs');
const modern=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const family=version=>version==='2.0'?'2.0':version.slice(0,3);
const document=(version,extra)=>({...version==='2.0'?{swagger:version}:{openapi:version},info:{title:'Definition owners',version:'api-version'},paths:{},...extra});
const parameter=version=>({name:'Value',in:'cookie',style:family(version)==='3.2'?'cookie':'form',schema:{type:'array',items:{type:'string'}},example:['100%25','0','false','']});
const header={schema:{type:'array',items:{type:'integer'}},'x-payload':{$ref:'literal.json'}};

for(const rootVersion of modern)for(const ownerVersion of modern)for(const format of ['yaml','json'])
test(`${rootVersion} ${format} request keeps referenced ${ownerVersion} Parameter and Header families`,()=>{
 const root='file:///owners/api.'+format,shared='file:///owners/shared.'+format,alias='file:///owners/aliases.'+format;
 const operation={parameters:[{$ref:'aliases.'+format+'#/Parameter'}],responses:{200:{description:'Values',headers:{'X-Values':{$ref:'aliases.'+format+'#/Header'}}}}};
 const objects=[document(rootVersion,{paths:{'/items':{get:operation}}}),document(ownerVersion,{components:{parameters:{'Value/~':parameter(ownerVersion)},headers:{'Value/~':header}}}),{Parameter:{$ref:'shared.'+format+'#/components/parameters/Value~1~0'},Header:{$ref:'shared.'+format+'#/components/headers/Value~1~0'}}];
 const render=value=>format==='yaml'?'# Keep source 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)+'\r\n';
 const resources=objects.map((value,index)=>({id:[root,shared,alias][index],generation:index+1,text:render(value)})),before=resources.map(r=>r.text);
 const input={root,snapshot:'referenced-definition-owners',resources},checked=analyse(input);
 assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.findings,[]);
 const result=requestOperation({...input,resource:root,pointer:'/paths/~1items/get'}),p=result.parameters[0],h=result.responses[0].headers[0];
 assert.equal(result.family,family(rootVersion));assert.equal(p.family,family(ownerVersion));assert.equal(p.style,parameter(ownerVersion).style);assert.equal(p.explode,true);
 assert.equal(p.source.resource,root);assert.equal(p.source.pointer,'/paths/~1items/get/parameters/0');
 assert.equal(p.definition.resource,shared);assert.equal(p.definition.pointer,'/components/parameters/Value~1~0');assert.equal(p.definition.generation,2);
 assert.equal(p.example.raw,'["100%25","0","false",""]');assert.equal(h.family,family(ownerVersion));assert.equal(h.definition.resource,shared);assert.equal(h.definition.pointer,'/components/headers/Value~1~0');
 assert.deepEqual(resources.map(r=>r.text),before);
});

for(const rootVersion of modern)for(const ownerVersion of modern)for(const format of ['yaml','json'])
test(`${rootVersion} ${format} request keeps referenced ${ownerVersion} Operation family`,()=>{
 const root='file:///owners/api.'+format,shared='file:///owners/operations.'+format;
 const objects=[document(rootVersion,{paths:{'/items':{$ref:'operations.'+format+'#/paths/~1shared'}}}),document(ownerVersion,{paths:{'/shared':{get:{parameters:[parameter(ownerVersion)],responses:{200:{description:'Values',headers:{'X-Values':header}}}}}}})];
 const resources=objects.map((value,index)=>({id:[root,shared][index],generation:index+1,text:format==='yaml'?YAML.stringify(value):JSON.stringify(value)}));
 const input={root,snapshot:'referenced-operation-owner',resources},checked=analyse(input);assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.findings,[]);
 const operation=checked.operations.find(op=>op.path==='/items'),result=requestOperation({...input,resource:operation.resource,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(result.family,family(ownerVersion));assert.equal(result.operation.path,'/items');assert.equal(result.operation.source.resource,shared);assert.equal(result.parameters[0].family,family(ownerVersion));assert.equal(result.parameters[0].explode,true);assert.equal(result.responses[0].headers[0].family,family(ownerVersion));
});
