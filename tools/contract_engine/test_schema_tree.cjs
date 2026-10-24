const assert=require('node:assert/strict');
const {test}=require('node:test');
const {schemaTree}=require('./dist/schema_tree.cjs');
const {inspect}=require('./dist/model.cjs');
const YAML=require('yaml');
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`authored schema tree ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///tree/root.'+(json?'json':'yaml'),resource='file:///tree/models.json';
 const schema={type:['object','null'],required:['a/b~雪'],properties:{'a/b~雪':false,...Object.fromEntries(Array.from({length:250},(_,i)=>['p'+i,{type:'string',description:'x'.repeat(i===249?100000:1)}]))},
  allOf:[{$ref:'#/$defs/Node'},{if:{properties:{a:{const:1}}},then:{required:['a']},else:false}],
  $defs:{Node:{$dynamicAnchor:'node',type:'object',properties:{child:{$dynamicRef:'#node'}}}},
  prefixItems:[true,{type:'integer'}],items:false,additionalProperties:false,
  examples:[{$ref:'literal payload',properties:{fake:{type:'string'}}}],
  'x-custom':{properties:{fake:{type:'string'}}},unknownKeyword:{$ref:'also data'}};
 const value={openapi:version,info:{title:'Tree',version:'1'},paths:{},components:{schemas:{Local:schema,Shared:{$ref:'models.json#/Model'}}}};
 // The local recursive reference is authored relative to its actual resource.
 schema.$id='https://example.test/tree';
 const input={root,snapshot:'tree-snapshot',resources:[{id:root,text:json?JSON.stringify(value):'# retained 😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'),generation:4,identity:'root'},
  {id:resource,text:JSON.stringify({Model:{type:'array',items:{$ref:'#/Model'},'x-data':{$ref:'not a dependency'}}}),generation:8,identity:'models'}]};
 const tree=(pointer,offset=0,res=root)=>schemaTree({...input,resource:res,pointer,offset});
 const pointer='/components/schemas/Local';
 const top=tree(pointer);
 assert.equal(top.version,1);assert.equal(top.snapshot,input.snapshot);assert.equal(top.node.resource,root);assert.equal(top.node.generation,4);
 assert.deepEqual(top.node.types,['object','null']);
 assert.deepEqual(top.entries.map(e=>e.name),['properties','allOf','$defs','prefixItems','items','additionalProperties']);
 assert(top.entries.every(e=>['schema','schema-map','schema-array'].includes(e.kind)));
 const first=tree(pointer+'/properties'),last=tree(pointer+'/properties',250);
 const revealed=schemaTree({...input,resource:root,pointer:pointer+'/properties',reveal:pointer+'/properties/p249'});
 assert.equal(revealed.revealOffset,250);assert.equal(revealed.offset,0);
 assert.equal(first.count,251);assert.equal(first.entries.length,50);assert.equal(last.entries.length,1);assert.equal(last.entries[0].name,'p249');
 assert.equal(first.entries[0].name,'a/b~雪');assert.equal(first.entries[0].pointer,pointer+'/properties/a~1b~0雪');
 assert.equal(first.entries[0].boolean,false);assert.equal(first.entries[0].required,true);
 assert.equal(first.entries[0].nodeKind,'boolean');
 assert.equal(inspect({...input,resource:root,pointer:pointer+'/properties/a~1b~0雪'}).nodeKind,'boolean');
 assert(!JSON.stringify(last).includes('x'.repeat(1000)),'long descriptions are not tree payloads');
 const ref=tree(pointer+'/allOf/0');assert.equal(ref.node.childCount,0);assert.equal(ref.node.references.length,1);assert.equal(ref.node.references[0].target.pointer,pointer+'/$defs/Node');
 const dynamic=tree(pointer+'/$defs/Node/properties/child');assert.equal(dynamic.node.references[0].dynamic,true);assert.equal(dynamic.node.childCount,0);
 const condition=tree(pointer+'/allOf/1');assert.deepEqual(condition.entries.map(e=>e.name),['if','then','else']);
 assert.equal(tree(pointer+'/prefixItems').entries[0].boolean,true);
 const external=tree('/Model',0,resource);assert.equal(external.node.generation,8);assert.equal(external.entries[0].pointer,'/Model/items');
 assert.equal(tree('/components/schemas/Shared').node.references[0].target.resource,resource);
 for(const at of [pointer,pointer+'/properties',pointer+'/allOf/1/if',pointer+'/properties/a~1b~0雪'])
  assert.equal(inspect({...input,resource:root,pointer:at}).schemaTreeRoot,pointer);
 assert.equal(inspect({...input,resource,pointer:'/Model/items'}).schemaTreeRoot,'/Model');
 assert.equal(inspect({...input,resource:root,pointer:'/components/schemas'}).schemaTreeRoot,undefined);
 for(const at of [pointer+'/examples/0',pointer+'/x-custom',pointer+'/unknownKeyword','/info'])
  assert.throws(()=>tree(at),e=>e.code==='schema.tree.context');
 // Tree inspection is byte-neutral and bounded regardless of long scalar data.
 assert.equal(input.resources[0].text,json?JSON.stringify(value):'# retained 😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'));
});
