const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse,inspect}=require('./dist/model.cjs');
const pointer='/paths/~1xml/get/responses/200/content/application~1xml/schema';
function input(version,format,schema,components,external) {
 const root='file:///contracts/api.'+format,value={openapi:version,info:{title:'XML names 雪',version:'1'},paths:{'/xml':{get:{responses:{200:{description:'XML',content:{'application/xml':{schema}}}}}}},...(components?{components}:{})};
 const text=format==='yaml'?'# Keep XML\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value),resources=[{id:root,text,generation:0},...(external?[{id:'file:///contracts/definitions.'+format,text:format==='yaml'?YAML.stringify(external):JSON.stringify(external),generation:0}]:[])];
 return {root,snapshot:version+'-'+format,resources};
}
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const nodeType of ['element','attribute']) {
 test(`${version} ${format} explicit XML ${nodeType} has a located missing-name diagnostic`,()=>{
  const params=input(version,format,{type:'string',xml:{nodeType}}),before=JSON.stringify(params),result=analyse(params),issues=result.findings.filter(f=>f.code==='xml.name.required');
  assert.equal(result.status,'invalid');assert.equal(result.complete,true);assert.equal(issues.length,1);const issue=issues[0];assert.equal(issue.pointer,pointer+'/xml');assert.equal(issue.resource,params.root);assert.equal(issue.category,'openapi');assert(issue.range[1]>issue.range[0]);assert(params.resources[0].text.slice(...issue.range).includes(nodeType));assert.equal(JSON.stringify(params),before);
 });
 for(const provided of [false,true])test(`${version} ${format} XML ${nodeType} inline name provided=${provided}`,()=>{
  const params=input(version,format,{type:'string',xml:{nodeType,...(provided?{name:'document'}:{})}}),result=analyse(params);assert.equal(result.findings.some(f=>f.code==='xml.name.required'),!provided);const page=inspect({...params,resource:params.root,pointer:pointer+'/xml'});assert.equal(page.fields.find(f=>f.name==='name').required,true);
 });
 for(const position of ['component','property','items','prefixItems','nestedItems'])test(`${version} ${format} XML ${nodeType} infers only typed ${position} names`,()=>{
  const child={type:'string',xml:{nodeType}},name='clé/雪 ~😀',item=position==='prefixItems'?{type:'array',prefixItems:[child]}:position==='nestedItems'?{type:'array',items:{type:'array',items:child}}:{type:'array',items:child};
  const model=position==='component'?child:{type:'object',properties:{[name]:position==='property'?child:item}};
  const params=input(version,format,{$ref:'#/components/schemas/Model'},{schemas:{Model:model}}),result=analyse(params);assert(!result.findings.some(f=>f.code==='xml.name.required'),JSON.stringify(result.findings));assert.equal(result.status,'complete');
 });
 for(const location of ['allOf','defs','arrayItems','external'])test(`${version} ${format} XML ${nodeType} cannot invent a ${location} name`,()=>{
  const child={type:'string',xml:{nodeType}},model=location==='allOf'?{allOf:[child]}:location==='defs'?{$defs:{Named:child}}:location==='arrayItems'?{type:'array',items:child}:{$ref:'definitions.'+format+'#/Named'};
  const params=input(version,format,{$ref:'#/components/schemas/Model'},{schemas:{Model:model}},location==='external'?{Named:child}:undefined),result=analyse(params),issues=result.findings.filter(f=>f.code==='xml.name.required');assert.equal(issues.length,1,JSON.stringify(result.findings));assert.equal(issues[0].resource,location==='external'?'file:///contracts/definitions.'+format:params.root);
 });
}
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const nodeType of ['text','cdata','none'])test(`${version} ${format} XML ${nodeType} needs no node name`,()=>{
 const params=input(version,format,{type:'string',xml:{nodeType}}),result=analyse(params);assert.equal(result.status,'complete');assert(!result.findings.some(f=>f.code==='xml.name.required'));
});
for(const version of ['3.0.0','3.0.4','3.1.0','3.1.2'])for(const format of ['yaml','json'])test(`${version} ${format} legacy XML metadata retains its family rules`,()=>{
 const params=input(version,format,{type:'string',xml:{attribute:true}}),result=analyse(params);assert.equal(result.status,'complete');assert(!result.findings.some(f=>f.code==='xml.name.required'));
});
for(const format of ['yaml','json'])test(`Swagger ${format} XML annotations remain native legacy metadata`,()=>{
 const root='file:///contracts/swagger.'+format,value={swagger:'2.0',info:{title:'Legacy XML',version:'1'},paths:{'/xml':{get:{responses:{200:{description:'XML',schema:{type:'string',xml:{attribute:true}}}}}}}};
 const text=format==='yaml'?YAML.stringify(value):JSON.stringify(value),result=analyse({root,snapshot:'swagger-xml',resources:[{id:root,text,generation:0}]});assert.equal(result.status,'complete');assert(!result.findings.some(f=>f.code==='xml.name.required'));
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} XML-looking instance and extension payloads stay literal`,()=>{
 const params=input(version,format,{type:'object',example:{components:{schemas:{Fake:{xml:{nodeType:'element'}}}}},'x-literal':{xml:{nodeType:'attribute'}}}),before=JSON.stringify(params),result=analyse(params);assert.equal(result.status,'complete');assert.equal(JSON.stringify(params),before);assert(!result.findings.some(f=>f.code==='xml.name.required'));
});
for(const dialect of ['https://spec.openapis.org/oas/3.2/dialect/base#','https://spec.openapis.org/oas/3.2/dialect/2025-09-17','https://spec.openapis.org/oas/3.2/dialect/2026-02-26','https://json-schema.org/draft/2020-12/schema','https://unknown.invalid/dialect'])test(`3.2 XML annotation policy respects supported versus unknown dialect ${dialect}`,()=>{
 const params=input('3.2.1','json',{$schema:dialect,type:'string',xml:{nodeType:'element'}}),result=analyse(params),supported=!dialect.includes('unknown');assert.equal(result.findings.some(f=>f.code==='xml.name.required'),supported);if(!supported){assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='dialect.unsupported'));}
});
