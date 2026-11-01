import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {graphAddressedDisplay,presentationNode,presentationValue,presentationSection} from './graph_display.mjs';
const require=createRequire(new URL('../contract_engine/package.json',import.meta.url));
const {referenceDocument}=require('./dist/reference_projection.cjs');
const root='https://docs.invalid/input.json';
const displayUri='https://display.invalid/index.html';
function input(value) {
  const text=JSON.stringify(value),params={root,snapshot:'display-input',resources:[{id:root,text,generation:1}]};
  return {text,projection:referenceDocument(params)};
}
for(const version of ['3.1.2','3.2.1'])test(`display coordinates ${version} come only from canonical static targets, not payload strings`,()=>{
  const value={openapi:version,info:{title:'Display',version:'1'},paths:{},components:{schemas:{
    Tree:{$id:'https://schemas.invalid/tree',$dynamicAnchor:'node',type:'object',properties:{child:{$dynamicRef:'#node'},name:{$ref:'https://schemas.invalid/value'}}},
    Value:{$id:'https://schemas.invalid/value',type:'string'},Use:{$ref:'https://schemas.invalid/tree'},
  },examples:{Payload:{value:{$ref:'https://schemas.invalid/tree',$id:'literal data'}}}},'x-data':{$ref:'https://schemas.invalid/value'}};
  const {text,projection}=input(value),captured=JSON.stringify(projection),display=graphAddressedDisplay(text,projection,displayUri);
  assert.equal(display.spec.components.schemas.Use.$ref,displayUri+'#/components/schemas/Tree');
  assert.equal(display.spec.components.schemas.Tree.properties.name.$ref,displayUri+'#/components/schemas/Value');
  assert.equal(display.spec.components.schemas.Tree.properties.child.$dynamicRef,'#node');
  assert.deepEqual(display.spec.components.examples,value.components.examples);assert.deepEqual(display.spec['x-data'],value['x-data']);
  assert.equal(display.spec.components.schemas.Tree.$id,value.components.schemas.Tree.$id);
  assert.equal(display.canonicalText,text);assert.equal(JSON.stringify(projection),captured);
  assert(display.referenceOrigins.some(reference=>reference.authored==='https://schemas.invalid/tree'&&reference.display===displayUri+'#/components/schemas/Tree'));
  assert(display.referenceOrigins.some(reference=>reference.dynamic?.anchor==='node'));
});
test('stale, unavailable and forged pointers fail before a view can be returned',()=>{
  const {text,projection}=input({openapi:'3.2.1',info:{title:'T',version:'1'},paths:{},components:{schemas:{A:{$ref:'#/components/schemas/B'},B:false}}});
  const reference=projection.sections.flatMap(section=>section.references)[0];
  reference.target.resource='https://must-not-fetch.invalid/schema';
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri),/resource-not-supplied/);
  reference.target.resource=root;reference.target.pointer='/missing';
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri),/target/);
  reference.target.pointer='/components/schemas/B';reference.value='changed';
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri),/stale-reference/);
  reference.value='#/components/schemas/B';reference.source.pointer='/components/schemas/A/~2ref';
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri),/pointer/);
  assert.equal({}.polluted,undefined);
});
test('forged operation context ownership, repeated view identities and unbounded metadata fail closed',()=>{
 const source={openapi:'3.2.1',info:{title:'Contexts',version:'1'},paths:{'/one':{$ref:'#/components/pathItems/Shared'},'/two':{$ref:'#/components/pathItems/Shared'}},components:{pathItems:{Shared:{get:{responses:{204:{description:'None'}}}}}}};
 for(const mutate of [
   contexts=>{contexts[1].navigationId=contexts[0].navigationId;},
   contexts=>{contexts[1].occurrence=contexts[0].occurrence;},
   contexts=>{contexts[0].occurrence=root+'#/components/pathItems/Shared/get';},
   contexts=>{contexts[0].pathItem.pointer='/info';},
   contexts=>{contexts[0].method='a'.repeat(257);},
   contexts=>{contexts[0].role='payload';},
   contexts=>{contexts[0].effective=Array(4).fill({name:'servers'});},
 ]) {
  const {text,projection}=input(source),contexts=projection.sections.find(section=>section.source.pointer==='/components/pathItems/Shared/get').contexts;mutate(contexts);
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri),/operation-context|effective-limit/);
 }
});
test('exact data keeps JSON lexemes, Unicode, null/false/zero/empty and definition ownership independently of display numbers',()=>{
  const value={openapi:'3.2.1',info:{title:'Exact',version:'1'},paths:{},security:[{Key:['read']},{}],components:{
    securitySchemes:{Key:{type:'apiKey',in:'header',name:'X-Key'}},
    examples:{Alias:{$ref:'#/components/examples/Data'},Data:{value:{integer:111,text:'雪😀',$ref:'literal payload'}},
      False:{value:false},Zero:{value:0},Null:{value:null},Empty:{value:''},Serialized:{serializedValue:'雪😀\n9007199254740993\n'},Absent:{summary:'No authored value'}},
  }};
  const text=JSON.stringify(value).replace('111','9007199254740993.00'),projection=referenceDocument({root,snapshot:'exact',resources:[{id:root,text,generation:1}]}),display=graphAddressedDisplay(text,projection,displayUri);
  const data=presentationValue(display,'/components/examples/Alias/value');
  assert.equal(data.raw,'{"integer":9007199254740993.00,"text":"雪😀","$ref":"literal payload"}');
  assert.equal(data.source.pointer,'/components/examples/Data/value');
  assert.equal(presentationNode(display,'/components/examples/Alias').pointer,'/components/examples/Data');
  for(const [name,raw]of [['False','false'],['Zero','0'],['Null','null'],['Empty','""']])assert.equal(presentationValue(display,'/components/examples/'+name+'/value').raw,raw);
  assert.equal(presentationValue(display,'/components/examples/Serialized/serializedValue').text,'雪😀\n9007199254740993\n');
  assert.equal(presentationValue(display,'/components/examples/Absent/value'),undefined);
  assert.deepEqual(display.spec.security,value.security);
  assert(display.referenceOrigins.some(reference=>reference.connection==='security'));
  const captured=display.referenceOrigins.find(reference=>reference.connection==='security').source.pointer;
  projection.sections.flatMap(section=>section.references).find(reference=>reference.connection==='security').source.pointer='/replacement';
  assert.equal(display.referenceOrigins.find(reference=>reference.connection==='security').source.pointer,captured);
});
test('an unseparated literal/schema occurrence cannot have its payload rewritten by a display adapter',()=>{
  const value={openapi:'3.2.1',info:{title:'Dual',version:'1'},paths:{},components:{schemas:{
    Literal:{const:{$ref:'#/components/schemas/Target'}},Consumer:{$ref:'#/components/schemas/Literal/const'},Target:{type:'string'},
  }}};
  const {text,projection}=input(value),frozen=JSON.stringify(projection);
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri),/busyapi.documentation.dual-occurrence/);
  assert.equal(JSON.stringify(projection),frozen);assert.equal(JSON.parse(text).components.schemas.Literal.const.$ref,'#/components/schemas/Target');
});
test('document-pointer presentation uses the same proved targets without altering resource/base identities',()=>{
  const value={openapi:'3.2.1',info:{title:'Pointers',version:'1'},paths:{},components:{schemas:{
    A:{$id:'https://schema.invalid/a',$anchor:'value',type:'string'},B:{$ref:'https://schema.invalid/a#value'},
  }}};
  const {text,projection}=input(value),display=graphAddressedDisplay(text,projection,displayUri,{addresses:'document-pointer'});
  assert.equal(display.addresses,'document-pointer');assert.equal(display.spec.components.schemas.B.$ref,'#/components/schemas/A');
  assert.equal(display.spec.components.schemas.A.$id,value.components.schemas.A.$id);assert.equal(display.spec.components.schemas.A.$anchor,'value');
  assert.equal(display.canonicalText,text);
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri,{addresses:'guess'}),/addresses/);
});
test('authored section pages keep reference occurrences, siblings and unknown payloads distinct from explicit definitions',()=>{
  const {text,projection}=input({openapi:'3.2.1',info:{title:'Sections',version:'1'},paths:{},components:{responses:{
    Alias:{$ref:'#/components/responses/Body',description:'Local annotation'},Body:{description:'Shared body',content:{'application/json':{schema:false,example:{$ref:'literal payload'}}}},
  }}});
  const display=graphAddressedDisplay(text,projection,displayUri),pointer='/components/responses/Alias';
  const occurrence=presentationSection(display,pointer),definition=presentationSection(display,pointer,{followReference:true});
  assert.equal(occurrence.pointer,pointer);assert.equal(definition.pointer,'/components/responses/Body');
  assert.equal(presentationValue(display,pointer+'/$ref',{followReference:false}).text,'#/components/responses/Body');
  assert.equal(presentationValue(display,pointer+'/description',{followReference:false}).text,'Local annotation');
  assert.equal(occurrence.entries.find(entry=>entry.name==='$ref').reference.target.pointer,definition.pointer);
  const captured=JSON.stringify(occurrence);
  projection.sections.find(section=>section.source.pointer===pointer).references[0].target.pointer='/forged';
  assert.equal(JSON.stringify(occurrence),captured);
  assert.throws(()=>occurrence.entries.push({}));assert.throws(()=>{occurrence.references[0].target.range[0]=9;});
  const literal=presentationSection(display,'/components/responses/Body/content/application~1json').entries.find(entry=>entry.name==='example');
  assert.equal(literal.reference,undefined);assert.equal(literal.target,undefined);
});
test('typed fields and duplicate section identities cannot bypass display work limits',()=>{
  const {text,projection}=input({openapi:'3.2.1',info:{title:'Limits',version:'1'},paths:{}});
  const first=projection.sections[0];
  projection.sections.push(first);
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri),/ambiguous/);
  projection.sections.pop();first.entries=Array(200001).fill(first.entries[0]);
  assert.throws(()=>graphAddressedDisplay(text,projection,displayUri),/field-limit/);
});
