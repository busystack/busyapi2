const assert = require('node:assert/strict');
const {test} = require('node:test');
const {inspect, analyse, propose} = require('./dist/model.cjs');
const YAML = require('yaml');
const root = 'file:///project/root.yaml';
const resource = 'file:///project/models.json';
const document = (openapi) => ({openapi, info: {title: 'Authoring', version: '1'},
 servers: [{url: 'https://{host}/v1', variables: {host: {default: 'localhost', enum: ['localhost'], description: 'Kept'}}}],
 paths: {}, components: {schemas: {Shared: {$ref: 'models.json#/Model'}}, securitySchemes: {OAuth: {type: 'oauth2', flows: {authorizationCode: {authorizationUrl: 'https://example.test/auth',tokenUrl: 'https://example.test/token',scopes: {'read:items': 'Read'}}}}}},
 'x-payload': {$ref: 'not a reference'}});
const fixture = (openapi, json) => {
 const id = json ? root.replace('.yaml','.json') : root;
 const value = document(openapi);
 const text = json ? JSON.stringify(value, null, 2) : '# retained\r\n' + YAML.stringify(value).replaceAll('\n','\r\n');
 return {root: id, snapshot: 'snapshot', resources: [{id, generation: 3, identity: 'root', text}, {id: resource, generation: 4, identity:'models', text: JSON.stringify({Model:{type:'object',properties:Object.fromEntries(Array.from({length:251},(_,i)=>['item'+i,{type:'string'}]))}})}]};
};
for (const version of ['3.1.2', '3.2.1']) for (const json of [false, true]) {
 test(`contextual extension creation and empty schema keys ${version} ${json}`, () => {
  const input=fixture(version,json), id=input.root;
  const apply=actions=>{
   const result=propose({...input,target:{resource:id,generation:3,pointer:'/info'},actions});
   let text=input.resources[0].text;
   for(const e of [...result.edits].reverse())text=text.slice(0,e.start)+e.replacement+text.slice(e.end);
   return text;
  };
  const raw='{"$ref":"literal payload","paths":{"get":false},"n":9007199254740993,"d":1.00,"z":null}';
  const text=apply([{kind:'createData',pointer:'/info/x-authored',raw}]);
  assert(text.includes(raw));
  const changed={...input,resources:input.resources.map(r=>r.id===id?{...r,text}:r)};
  assert(!analyse(changed).references.some(r=>r.value==='literal payload'));
  assert.throws(()=>propose({...changed,target:{resource:id,generation:3,pointer:'/info'},actions:[{kind:'createData',pointer:'/info/x-authored',raw:'false'}]}),e=>e.code==='edit.collision');
  const inspectAt=pointer=>inspect({...input,resource:id,pointer});
  for(const pointer of ['', '/info','/servers/0','/servers/0/variables/host','/components','/components/schemas/Shared','/components/securitySchemes/OAuth','/components/securitySchemes/OAuth/flows','/components/securitySchemes/OAuth/flows/authorizationCode','/paths']) assert.equal(inspectAt(pointer).allowsExtensions,true,pointer);
  for(const pointer of ['/components/schemas','/components/securitySchemes','/servers/0/variables','/components/securitySchemes/OAuth/flows/authorizationCode/scopes']) assert.equal(inspectAt(pointer).allowsExtensions,false,pointer);
  const value=document(version);value.components.securitySchemes.Alias={$ref:'#/components/securitySchemes/OAuth'};
  assert.equal(inspect({...input,resources:input.resources.map(r=>r.id===id?{...r,text:JSON.stringify(value)}:r),resource:id,pointer:'/components/securitySchemes/Alias'}).allowsExtensions,false);
  const empty=apply([{kind:'create',pointer:'/components/schemas/Empty/properties/',value:{}}]);
  const result=inspect({...input,resources:input.resources.map(r=>r.id===id?{...r,text:empty}:r),resource:id,pointer:'/components/schemas/Empty/properties'});
  assert.equal(result.entries[0].name,'');assert.equal(result.entries[0].kind,'schema');
  assert(!json ? empty.startsWith('# retained\r\n') : true);
 });
}
for (const version of ['3.1.2','3.2.1']) for (const json of [false,true]) {
 test(`lazy native object contracts ${version} ${json?'JSON':'YAML'}`,()=>{
  const input=fixture(version,json), id=input.root;
  const info=inspect({...input,resource:id,pointer:'/info'});
  assert.equal(info.kind,'info'); assert.equal(info.value.title,'Authoring');
  assert.equal(info.fields.find(f=>f.name==='summary').present,false);
  assert.equal(info.fields.find(f=>f.name==='contact').type,'object');
  const server=inspect({...input,resource:id,pointer:'/servers/0'});
  assert.equal(server.kind,'server');
  assert.equal(server.fields.some(f=>f.name==='name'),version.startsWith('3.2'));
  const variable=inspect({...input,resource:id,pointer:'/servers/0/variables/host'});
  assert.equal(variable.kind,'server-variable');
  const security=inspect({...input,resource:id,pointer:'/components/securitySchemes/OAuth'});
  assert(security.fields.some(f=>f.name==='flows'));
  assert(!security.fields.some(f=>f.name==='scheme'));
  assert.equal(security.fields.some(f=>f.name==='oauth2MetadataUrl'),version.startsWith('3.2'));
  const flow=inspect({...input,resource:id,pointer:'/components/securitySchemes/OAuth/flows/authorizationCode'});
  assert.equal(flow.kind,'oauth-flow');
  const occurrence=inspect({...input,resource:id,pointer:'/components/schemas/Shared'});
  assert.equal(occurrence.references[0].target.resource,resource);
  assert.equal(occurrence.references[0].target.pointer,'/Model');
  const shared=inspect({...input,resource,pointer:'/Model/properties',offset:250});
  assert.equal(shared.count,251);assert.equal(shared.entries.length,1);assert.equal(shared.entries[0].name,'item250');
  assert.equal(shared.entries[0].kind,'schema');
  assert.equal(shared.entries[0].required,false);
  assert.equal(shared.ownerSchema.pointer,'/Model');
  const required=propose({...input,target:{resource,generation:4,pointer:'/Model/properties',range:shared.range},actions:[{kind:'setRequired',pointer:'/Model',name:'item250',required:true}]});
  let modelText=input.resources[1].text;for(const e of required.edits)modelText=modelText.slice(0,e.start)+e.replacement+modelText.slice(e.end);
  assert.deepEqual(JSON.parse(modelText).Model.required,['item250']);
  const changed={...input,resources:[input.resources[0],{...input.resources[1],text:modelText}]};
  assert.deepEqual(propose({...changed,target:{resource,generation:4,pointer:'/Model/properties'},actions:[{kind:'setRequired',pointer:'/Model',name:'item250',required:true}]}).edits,[]);
  assert.throws(()=>propose({...changed,target:{resource,generation:4,pointer:'/Model/properties'},actions:[{kind:'setRequired',pointer:'/Model',name:'missing',required:true}]}),e=>e.code==='schema.property.missing');
  assert.throws(()=>inspect({...input,resource:id,pointer:'/x-payload'}),e=>e.code==='inspect.context');
  const result=propose({...input,target:{resource:id,generation:3,pointer:'/info',range:info.range},actions:[{kind:'set',pointer:'/info/summary',value:'Native summary'}]});
  let edited=input.resources[0].text;for(const e of result.edits)edited=edited.slice(0,e.start)+e.replacement+edited.slice(e.end);
  assert(edited.includes('Native summary'));assert(edited.includes('not a reference'));
  if(!json){assert(edited.startsWith('# retained\r\n'));assert(!/(?<!\r)\n/.test(edited));}
 });
}
test('absent, false, zero and null are distinct; no-op and collision leave exact source',()=>{
 const input=fixture('3.2.1',true);const info=inspect({...input,resource:input.root,pointer:'/info'});
 assert.deepEqual(propose({...input,target:{resource:input.root,generation:3,pointer:'/info',range:info.range},actions:[{kind:'set',pointer:'/info/title',value:'Authoring'}]}).edits,[]);
 assert.throws(()=>propose({...input,target:{resource:input.root,generation:3,pointer:'/info'},actions:[{kind:'create',pointer:'/info/title',value:'replacement'}]}),e=>e.code==='edit.collision');
 for(const raw of ['false','0','null','900719925474099312345']){
  const result=propose({...input,target:{resource:input.root,generation:3,pointer:'/info'},actions:[{kind:'setData',pointer:'/info/x-data',raw}]});
  let text=input.resources[0].text;for(const e of result.edits)text=text.slice(0,e.start)+e.replacement+text.slice(e.end);
  assert(text.includes(raw));
 }
});
test('version/location field legality and effective defaults do not invent authored values',()=>{
 for(const version of ['3.1.2','3.2.1']){
  const input=fixture(version,true),value=document(version);
  value.paths['/items']={get:{parameters:[{name:'q',in:'query',schema:{type:'string'}}]}};
  value.components.headers={H:{description:'Header',schema:{type:'string'}}};
  value.tags=[{name:'tag'}];
  value.components.examples={E:{value:{$ref:'literal data'}}};
  value.components.schemas.Local={type:'object',xml:{},discriminator:{propertyName:'kind'}};
  input.resources[0].text=JSON.stringify(value);
  const parameter=inspect({...input,resource:input.root,pointer:'/paths/~1items/get/parameters/0'});
  const style=parameter.fields.find(f=>f.name==='style');
  assert.equal(style.effectiveDefault,'form');assert.equal(style.present,false);
  assert.deepEqual(style.options,['form','spaceDelimited','pipeDelimited','deepObject']);
  assert.equal(parameter.fields.find(f=>f.name==='explode').effectiveDefault,true);
  assert.deepEqual(parameter.fields.find(f=>f.name==='content').blockedBy,['schema']);
  const header=inspect({...input,resource:input.root,pointer:'/components/headers/H'});
  assert(!header.fields.some(f=>['name','in'].includes(f.name)));
  assert.equal(header.fields.find(f=>f.name==='explode').effectiveDefault,false);
  const tag=inspect({...input,resource:input.root,pointer:'/tags/0'});
  assert.equal(tag.fields.some(f=>f.name==='parent'),version.startsWith('3.2'));
  const example=inspect({...input,resource:input.root,pointer:'/components/examples/E'});
  assert.equal(example.fields.some(f=>f.name==='serializedValue'),version.startsWith('3.2'));
  const xml=inspect({...input,resource:input.root,pointer:'/components/schemas/Local/xml'});
  assert.equal(xml.kind,'xml');
  assert.equal(xml.fields.some(f=>f.name==='nodeType'),version.startsWith('3.2'));
  if(version.startsWith('3.2')) assert.deepEqual(xml.fields.find(f=>f.name==='nodeType').options,['element','attribute','text','cdata','none']);
  const discriminator=inspect({...input,resource:input.root,pointer:'/components/schemas/Local/discriminator'});
  assert.equal(discriminator.fields.some(f=>f.name==='defaultMapping'),version.startsWith('3.2'));
 }
});
test('native string collections retain literal tags, scopes and server enum choices as data',()=>{
 for(const version of ['3.1.2','3.2.1']) for(const json of [false,true]) {
  const input=fixture(version,json), value=document(version);
  value.security=[{OAuth:['read:items','$ref','😀 line\nsecond']}];
  value.paths['/items']={get:{tags:['public','$ref']}};
  value.components.schemas.Data={enum:[false,0,null,{$ref:'literal'}]};
  input.resources[0].text=json?JSON.stringify(value):YAML.stringify(value);
  for(const pointer of ['/security/0/OAuth','/paths/~1items/get/tags','/servers/0/variables/host/enum']){
   const page=inspect({...input,resource:input.root,pointer});
   assert.equal(page.kind,'string-array');
   assert(page.entries.every(e=>e.kind==='data' && typeof e.value==='string'));
   const result=propose({...input,target:{resource:input.root,generation:3,pointer,range:page.range},actions:[{kind:'create',pointer:pointer+'/'+page.count,value:'literal $ref\n😀'}]});
   let text=input.resources[0].text;for(const e of result.edits)text=text.slice(0,e.start)+e.replacement+text.slice(e.end);
   const actual=json?JSON.parse(text):YAML.parse(text);
   assert.equal(actual.security[0].OAuth[1],'$ref');
   assert.deepEqual(actual.components.schemas.Data.enum,[false,0,null,{$ref:'literal'}]);
   assert.equal(analyse({...input,resources:[{...input.resources[0],text},input.resources[1]]}).references.some(r=>r.value==='literal'||r.value==='literal $ref\n😀'),false);
  }
 }
});
test('conditional refinements retain types and distinguish example representation pairs',()=>{
 for(const version of ['3.1.2','3.2.1'])for(const json of [false,true]){
  const input=fixture(version,json),value=document(version);
  value.components.examples={E:{value:false}};
  value.paths['/items']={get:{parameters:[{in:'path',name:'id',content:{'text/plain':{}}}]}};
  const update=()=>input.resources[0].text=json?JSON.stringify(value):YAML.stringify(value);
  const fields=pointer=>inspect({...input,resource:input.root,pointer}).fields;
  update();
  let parameter=fields('/paths/~1items/get/parameters/0');
  assert.deepEqual(parameter.find(f=>f.name==='required').options,[true]);
  assert.equal(parameter.find(f=>f.name==='required').required,true);
  assert(!Object.hasOwn(parameter.find(f=>f.name==='required'),'effectiveDefault'));
  assert.deepEqual(fields('/components/examples/E').find(f=>f.name==='externalValue').blockedBy,['value']);
  if(version.startsWith('3.2')){
   assert.deepEqual(fields('/components/examples/E').find(f=>f.name==='dataValue').blockedBy,['value']);
   assert.deepEqual(fields('/components/examples/E').find(f=>f.name==='serializedValue').blockedBy,['value']);
   value.components.examples.E={dataValue:{$ref:'literal payload'},serializedValue:'<value>😀</value>'};update();
   let example=fields('/components/examples/E');
   assert.deepEqual(example.find(f=>f.name==='dataValue').blockedBy,[]);
   assert.deepEqual(example.find(f=>f.name==='serializedValue').blockedBy,[]);
   assert.deepEqual(example.find(f=>f.name==='value').blockedBy,['dataValue','serializedValue']);
   assert.deepEqual(example.find(f=>f.name==='externalValue').blockedBy,['serializedValue']);
   value.components.examples.E={dataValue:0,externalValue:'not fetched'};update();
   assert.deepEqual(fields('/components/examples/E').find(f=>f.name==='dataValue').blockedBy,[]);
   assert.deepEqual(fields('/components/examples/E').find(f=>f.name==='serializedValue').blockedBy,['externalValue']);
   const media=value.paths['/items'].get.parameters[0].content['text/plain'];
   media.encoding={};update();
   let f=fields('/paths/~1items/get/parameters/0/content/text~1plain').find(f=>f.name==='prefixEncoding');
   assert.equal(f.type,'array');assert.equal(f.prohibited,true);assert.deepEqual(f.blockedBy,['encoding']);
   delete media.encoding;media.prefixEncoding=[];media.itemEncoding={};update();
   f=fields('/paths/~1items/get/parameters/0/content/text~1plain').find(f=>f.name==='encoding');
   assert.deepEqual(f.blockedBy,['prefixEncoding','itemEncoding']);
   value.paths['/items'].get.parameters[0]={in:'querystring',name:'whole',content:{'text/plain':{}}};update();
   f=fields('/paths/~1items/get/parameters/0').find(f=>f.name==='schema');
   assert.equal(f.prohibited,true);assert.deepEqual(f.blockedBy,['in','content']);
   value.paths['/items'].get.parameters[0]={in:'cookie',name:'cookie',style:'cookie',schema:{type:'array'}};update();
   f=fields('/paths/~1items/get/parameters/0').find(f=>f.name==='explode');
   assert.equal(f.type,'boolean');assert.equal(f.effectiveDefault,true);assert.deepEqual(f.options,[true]);
   value.paths['/items'].get.parameters[0].content={'application/json':{schema:{}}};update();
   assert.deepEqual(fields('/paths/~1items/get/parameters/0').find(f=>f.name==='schema').blockedBy,['content']);
  }
 }
});
test('absent nested component collections remain virtual until explicitly created at their captured owner',()=>{
 for(const version of ['3.1.2','3.2.1'])for(const json of [false,true]){
  const id='file:///project/absent.'+(json?'json':'yaml'),value={openapi:version,info:{title:'T',version:'1'},paths:{'/empty':{},'/shared':{$ref:'#/components/pathItems/Shared'}},'x-kept':{$ref:'literal'}};
  const text=json?JSON.stringify(value):'# kept\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');
  const input={root:id,snapshot:'captured',resources:[{id,generation:1,identity:'root',text}]};
  const page=inspect({...input,resource:id,pointer:'/components/schemas'});
  assert.equal(page.absent,true);assert.equal(page.parent.pointer,'');assert.equal(page.field.destinationPointer,'/components/schemas');
  assert.equal(page.kind,'schema-map');assert.equal(input.resources[0].text,text);
  const proposal=propose({...input,target:{resource:id,generation:1,pointer:page.parent.pointer,range:page.parent.range},actions:[{kind:'create',pointer:page.field.destinationPointer,value:{}}]});
  let after=text;for(const edit of proposal.edits)after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
  const data=json?JSON.parse(after):YAML.parse(after);assert.deepEqual(data.components,{schemas:{}});assert.equal(data['x-kept'].$ref,'literal');
  const pathItems=analyse(input).pathItems;
  assert.equal(pathItems.length,2);assert(pathItems.every(item=>item.resource===id&&item.value===undefined));
  assert(pathItems.some(item=>item.pointer==='/paths/~1empty'));assert(pathItems.some(item=>item.pointer==='/paths/~1shared'));
  if(version.startsWith('3.1'))assert.throws(()=>inspect({...input,resource:id,pointer:'/components/mediaTypes'}),e=>e.code==='inspect.context');
 }
});
