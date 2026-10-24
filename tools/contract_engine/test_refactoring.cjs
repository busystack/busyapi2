const assert = require('node:assert/strict');
const {test} = require('node:test');
const YAML = require('yaml');
const {planRename,planPropertyRename} = require('./dist/refactoring.cjs');
const {createGraph} = require('./dist/model.cjs');
const root='file:///project/root.yaml', part='file:///project/part.yaml';
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const explicit of [false,true])test(`ignored Reference Object siblings retain literal ownership ${version} ${json} explicit=${explicit}`,()=>{
 const id=root.replace('.yaml',json?'.json':'.yaml'),ignored='/components/responses/Ignored/content/application~1json/schema',value={openapi:version,info:{title:'Ignored ownership',version:'1'},paths:{},components:{schemas:{Old:{type:'string'},Use:{$ref:explicit?'#'+ignored:'#/components/schemas/Old'}},responses:{Bodyless:{description:'No body'},Ignored:{$ref:'#/components/responses/Bodyless',content:{'application/json':{schema:{$ref:'#/components/schemas/Old'}}}}}}},text=json?JSON.stringify(value):YAML.stringify(value),input={root:id,snapshot:'ignored-owner',resources:[{id,text,generation:1}],contexts:[{root:id,resources:[id]}],target:{resource:id,generation:1,pointer:'/components/schemas/Old'},name:'New'};
 if(explicit)assert.throws(()=>planRename(input),error=>error.code==='refactor.literal.ownership');
 else {const after=createGraph({...input,resources:apply(input,planRename(input))}).docs.get(id);assert.equal(after.dataNode(ignored+'/$ref').value,'#/components/schemas/Old');assert.equal(after.dataNode('/components/schemas/Use/$ref').value,'#/components/schemas/New');}
 assert.equal(input.resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const alias of json?[false]:[false,true])for(const stable of [false,true])test(`rename preserves dual literal/schema ownership ${version} ${json} alias=${alias} stable=${stable}`,()=>{
 const id=root.replace('.yaml',json?'.json':'.yaml'),reference=stable?'https://identities.invalid/model':'#/components/schemas/Old',payload={$ref:reference},value={openapi:version,info:{title:'Literal ownership',version:'1'},paths:{},...(alias?{'x-payload':payload}:{}),components:{schemas:{Old:{...(stable?{$id:reference}:{}),type:'string'},Literal:{const:payload},Use:{$ref:'#/components/schemas/Literal/const'}}}};
 const text=json?JSON.stringify(value):'\ufeff# retained 雪😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'),input={root:id,snapshot:'literal-owner',resources:[{id,text,generation:1}],contexts:[{root:id,resources:[id]}],target:{resource:id,generation:1,pointer:'/components/schemas/Old'},name:'New'};
 assert.deepEqual(planRename({...input,name:'Old'}).edits,[]);
 if(stable){const plan=planRename(input),after=apply(input,plan),doc=createGraph({...input,resources:after}).docs.get(id);assert.equal(doc.dataNode('/components/schemas/Literal/const/$ref').value,reference);assert(plan.usages.some(use=>use.unchangedIdentity));}
 else {const range=createGraph(input).docs.get(id).dataNode('/components/schemas/Literal/const/$ref').range;assert.throws(()=>planRename(input),error=>error.code==='refactor.literal.ownership'&&JSON.stringify(error.range)===JSON.stringify(range));}
 assert.equal(input.resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`literal payloads alone do not block ordinary structural property/component renames ${version} ${json}`,()=>{
 const id=root.replace('.yaml',json?'.json':'.yaml'),value={openapi:version,info:{title:'Literal control',version:'1'},paths:{},components:{schemas:{Old:{type:'object',properties:{old:{type:'string'}},required:['old'],examples:[{old:'authored'}]},Literal:{const:{$ref:'#/components/schemas/Old'}},Direct:{$ref:'#/components/schemas/Old'}}}},text=json?JSON.stringify(value):YAML.stringify(value),input={root:id,snapshot:'literal-control',resources:[{id,text,generation:1}],contexts:[{root:id,resources:[id]}],target:{resource:id,generation:1,pointer:'/components/schemas/Old'},name:'New'};
 const renamed=createGraph({...input,resources:apply(input,planRename(input))}).docs.get(id);
 assert.equal(renamed.dataNode('/components/schemas/Literal/const/$ref').value,'#/components/schemas/Old');assert.equal(renamed.dataNode('/components/schemas/Direct/$ref').value,'#/components/schemas/New');
 const property={...input,target:{...input.target,pointer:'/components/schemas/Old/properties/old'},name:'new'},result=createGraph({...input,resources:apply(input,planPropertyRename(property))}).docs.get(id);
 assert.deepEqual(result.dataNode('/components/schemas/Old/required').value,['new']);assert.equal(result.dataJson('/components/schemas/Old/examples'),createGraph(input).docs.get(id).dataJson('/components/schemas/Old/examples'));assert.equal(input.resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`property rename cannot retarget a definition that is also literal instance data ${version} ${json}`,()=>{
 const id=root.replace('.yaml',json?'.json':'.yaml'),value={openapi:version,info:{title:'Dual property',version:'1'},paths:{},components:{schemas:{Literal:{const:{type:'object',properties:{old:{type:'string'}},required:['old']}},Use:{$ref:'#/components/schemas/Literal/const'}}}},text=json?JSON.stringify(value):YAML.stringify(value),input={root:id,snapshot:'dual-property',resources:[{id,text,generation:1}],contexts:[{root:id,resources:[id]}],target:{resource:id,generation:1,pointer:'/components/schemas/Literal/const/properties/old'},name:'new'};
 assert.deepEqual(planPropertyRename({...input,name:'old'}).edits,[]);assert.throws(()=>planPropertyRename(input),error=>error.code==='refactor.literal.ownership');assert.equal(input.resources[0].text,text);
});
function fixture(version,json=false) {
 const id=json?root.replace('.yaml','.json'):root, fragment=json?part.replace('.yaml','.json'):part;
 const value={openapi:version,info:{title:'Rename',version:'1'},paths:{'/items':{get:{responses:{'200':{description:'OK',content:{'application/json':{schema:{$ref:'#/components/schemas/Old'},example:{$ref:'#/components/schemas/Old',name:'Old'}}}}}}}},components:{schemas:{Old:{type:'object',properties:{self:{$ref:'#/components/schemas/Old'},nested:{$id:'https://models.test/nested', $anchor:'entry',type:'string'}},'x-number':1.00},Union:{oneOf:[{$ref:'#/components/schemas/Old'}],discriminator:{propertyName:'kind'}}},securitySchemes:{Key:{type:'apiKey',in:'header',name:'X-Key'}}},security:[{Key:[]}], 'x-payload':{$ref:'#/components/schemas/Old'}};
 const external={schema:{$ref:(json?'root.json':'root.yaml')+'#/components/schemas/Old'},stable:{$ref:'https://models.test/nested#entry'}};
 const stringify=v=>json?JSON.stringify(v,null,2):YAML.stringify(v);
 let text=stringify(value);
 if(!json)text='# retained\r\n'+text.replace('    Old:',"    'Old':").replaceAll('\n','\r\n');
 return {root:id,snapshot:'captured',contexts:[{root:id,resources:[id,fragment]}],resources:[{id,generation:3,identity:'root',text},{id:fragment,generation:4,identity:'part',text:stringify(external)}],target:{resource:id,generation:3,pointer:'/components/schemas/Old'}};
}
const apply=(input,plan)=>input.resources.map(r=>{
 let text=r.text;for(const e of plan.edits.filter(e=>e.buffer===r.id).sort((a,b)=>b.start-a.start)) {assert.equal(text.slice(e.start,e.end),e.expected);text=text.slice(0,e.start)+e.replacement+text.slice(e.end);}
 return {...r,text};
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`semantic component rename ${version} ${json?'JSON':'YAML'}`,()=>{
 const input=fixture(version,json);
 // Give the fragment its real schema occurrence context through a root ref.
 const parse=json?JSON.parse:YAML.parse;
 const value=parse(input.resources[0].text);
 value.components.schemas.External={$ref:(json?'part.json':'part.yaml')+'#/schema'};
 value.components.schemas.Anchor={$ref:(json?'part.json':'part.yaml')+'#/stable'};
 const original=input.resources[0].text;
 input.resources[0].text=json?JSON.stringify(value,null,2):'# retained\r\n'+YAML.stringify(value).replace('    Old:',"    'Old':").replaceAll('\n','\r\n');
 const plan=planRename({...input,name:'New'}), resources=apply(input,plan), after=parse(resources[0].text);
 assert(after.components.schemas.New);assert(!after.components.schemas.Old);
 assert.equal(after.components.schemas.New.properties.self.$ref,'#/components/schemas/New');
 assert.equal(after.paths['/items'].get.responses['200'].content['application/json'].example.$ref,'#/components/schemas/Old');
 assert.equal(after['x-payload'].$ref,'#/components/schemas/Old');
 assert.equal(after.components.schemas.Union.discriminator.mapping.Old,'#/components/schemas/New');
 assert.equal(parse(resources[1].text).schema.$ref,(json?'root.json':'root.yaml')+'#/components/schemas/New');
 assert.equal(parse(resources[1].text).stable.$ref,'https://models.test/nested#entry');
 assert.equal(createGraph({...input,resources}).graph.issues.length,0);
 assert.equal(plan.edits.length,2);assert(plan.usages.some(u=>u.resource===resources[1].id));
 if(!json){assert(resources[0].text.startsWith('# retained\r\n'));assert(resources[0].text.includes("'New':"));assert(!/(?<!\r)\n/.test(resources[0].text));}
 assert.deepEqual(planRename({...input,name:'Old'}).edits,[]);
 assert.throws(()=>planRename({...input,name:'Union'}),e=>e.code==='edit.collision');
 assert.throws(()=>planRename({...input,name:'bad/name'}),e=>e.code==='refactor.name');
 assert.throws(()=>planRename({...input,name:'New',target:{...input.target,generation:2}}),e=>e.code==='edit.stale');
 assert.equal(input.resources[0].text.includes('New'),false);assert(original.includes('Old'));
});
test('security name connections are repaired but data keys are not',()=>{
 const input=fixture('3.2.1',true);
 input.resources=[input.resources[0]];input.contexts[0].resources=[input.root];
 const plan=planRename({...input,target:{resource:input.root,generation:3,pointer:'/components/securitySchemes/Key'},name:'Auth'});
 const after=JSON.parse(apply(input,plan)[0].text);
 assert.deepEqual(after.security,[{Auth:[]}]);assert.equal(after.components.securitySchemes.Auth.name,'X-Key');
});
test('a shared requirement with different root namespaces blocks a partial rename',()=>{
 const a='file:///project/a.json',b='file:///project/b.json',shared='file:///project/shared.json';
 const rootValue={openapi:'3.2.1',info:{title:'Multi',version:'1'},paths:{'/':{$ref:'shared.json#/Path'}},components:{securitySchemes:{Key:{type:'http',scheme:'bearer'}}}};
 const input={snapshot:'both',resources:[{id:a,text:JSON.stringify(rootValue),generation:1},{id:b,text:JSON.stringify(rootValue),generation:1},{id:shared,text:JSON.stringify({Path:{get:{security:[{Key:[]}],responses:{'204':{description:'None'}}}}}),generation:1}],contexts:[{root:a,resources:[a,shared]},{root:b,resources:[b,shared]}],target:{resource:a,generation:1,pointer:'/components/securitySchemes/Key'},name:'Renamed'};
 assert.throws(()=>planRename(input),e=>e.code==='refactor.proof');
});
test('unavailable consumers and duplicate identities are never accepted as a clean rename',()=>{
 const input=fixture('3.1.2',true),value=JSON.parse(input.resources[0].text);
 value.components.schemas.Missing={$ref:'unapproved.json#/Schema'};
 input.resources[0].text=JSON.stringify(value);
 assert.throws(()=>planRename({...input,name:'New'}),e=>e.code==='refactor.graph');
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`property rename repairs known same-instance relationships ${version} ${json?'JSON':'YAML'}`,()=>{
 const id='file:///project/properties.'+(json?'json':'yaml'), fragment='file:///project/consumer.json';
 const model={type:'object',properties:{old:{type:'string'},nested:{type:'object',properties:{old:{type:'string'}},required:['old']}},required:['old'],dependentRequired:{old:['other'],other:['old']},dependentSchemas:{old:{properties:{old:{minLength:1}},required:['old']}},if:{properties:{old:{const:'x'}}},then:{required:['old']},allOf:[{properties:{old:{maxLength:10}}}],discriminator:{propertyName:'old'},propertyNames:{pattern:'^old$'},examples:[{old:'sample'}],'x-kept':{old:{$ref:'literal'}}};
 const value={openapi:version,info:{title:'Property',version:'1'},paths:{},components:{schemas:{Model:model,Ref:{$ref:'#/components/schemas/Model/dependentSchemas/old/properties/old'},External:{$ref:'consumer.json#/Use'}}}};
 let text=json?JSON.stringify(value,null,2):'# kept\r\n'+YAML.stringify(value).replaceAll('\n','\r\n').replace('      properties:\r\n        old:',"      properties:\r\n        'old':");
 const input={snapshot:'captured',resources:[{id,text,generation:1,identity:'root'},{id:fragment,text:JSON.stringify({Use:{$ref:(json?'properties.json':'properties.yaml')+'#/components/schemas/Model/properties/old'}}),generation:2,identity:'part'}],contexts:[{root:id,resources:[id,fragment]}],target:{resource:id,generation:1,pointer:'/components/schemas/Model/properties/old'},name:'name/😀~1'};
 const plan=planPropertyRename(input),resources=apply(input,plan),actual=json?JSON.parse(resources[0].text):YAML.parse(resources[0].text),schema=actual.components.schemas.Model;
 assert.equal(plan.kind,'property-rename');assert.equal(plan.edits.length,2);
 assert.equal(schema.properties[input.name].type,'string');assert.deepEqual(schema.required,[input.name]);
 assert.deepEqual(schema.dependentRequired[input.name],['other']);assert.deepEqual(schema.dependentRequired.other,[input.name]);
 assert(schema.dependentSchemas[input.name].properties[input.name]);assert.deepEqual(schema.dependentSchemas[input.name].required,[input.name]);
 assert.equal(schema.if.properties[input.name].const,'x');assert.deepEqual(schema.then.required,[input.name]);assert(schema.allOf[0].properties[input.name]);
 assert.equal(schema.discriminator.propertyName,input.name);assert.deepEqual(schema.examples,[{old:'sample'}]);assert.equal(schema['x-kept'].old.$ref,'literal');
 assert.deepEqual(schema.properties.nested.required,['old']);assert(schema.properties.nested.properties.old);
 assert.equal(schema.propertyNames.pattern,'^old$');assert(plan.preservedNameConstraints.includes('/components/schemas/Model/propertyNames'));
 assert.equal(actual.components.schemas.Ref.$ref,'#/components/schemas/Model/dependentSchemas/name~1😀~01/properties/name~1😀~01'.replaceAll('😀',encodeURI('😀')));
 assert(JSON.parse(resources[1].text).Use.$ref.includes('/properties/name~1'));
 assert.equal(createGraph({root:id,resources}).graph.issues.length,0);
 if(!json){assert(resources[0].text.startsWith('# kept\r\n'));assert(resources[0].text.includes("'name/😀~1':"));}
 assert.deepEqual(planPropertyRename({...input,name:'old'}).edits,[]);
 assert.throws(()=>planPropertyRename({...input,name:'nested'}),e=>e.code==='edit.collision');
 const referenced=structuredClone(value);referenced.components.schemas.Model.allOf=[{$ref:'#/components/schemas/Other'}];referenced.components.schemas.Other={type:'object'};
 const guarded={...input,resources:[{...input.resources[0],text:json?JSON.stringify(referenced):YAML.stringify(referenced)},input.resources[1]]};
 assert.throws(()=>planPropertyRename(guarded),e=>e.code==='refactor.property.reference');
});
