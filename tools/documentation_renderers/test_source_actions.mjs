import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {graphAddressedDisplay,hasPresentationCoordinate} from './graph_display.mjs';
import {documentationSourceControl,documentationSourceFactory} from './source_actions.mjs';
const {referenceDocument}=createRequire(new URL('../contract_engine/package.json',import.meta.url))('./dist/reference_projection.cjs');
const React={createElement:(type,props,...children)=>({type,props,children})};
function input() {
  const root='https://contracts.invalid/input.json',text='{"openapi":"3.2.1","info":{"title":"Sources","version":"1"},"paths":{},"components":{"schemas":{"Boolean":false,"Alias":{"$ref":"#/components/schemas/Boolean"}}}}';
  return graphAddressedDisplay(text,referenceDocument({root,snapshot:'source-controls',resources:[{id:root,text,generation:1}]}),'https://display.invalid/index.html');
}
const labels={source:'View source · 雪😀',sourceOwner:'View original owner'};
const action=(pointer,role='node',index=0,authored=true)=>({index,pointer,role,authored});
test('opaque controls preserve role/occurrence ownership, distinguish generated owners and capture immutable actions before async rendering',()=>{
  const presentation=input(),table=[action('/components/schemas/Alias'),action('/components/schemas/Alias/$ref','field',1),action('/components/schemas/Alias/$ref','reference',2),action('/components/schemas/Boolean','node',3,false)],captured=JSON.stringify(presentation),received=[],mutableLabels={...labels};
  const factory=documentationSourceFactory(presentation,{sourceActions:table,onSource:index=>received.push(index),labels:mutableLabels});
  table[0].index=99;table[1].pointer='/elsewhere';mutableLabels.source='Changed';
  const Source=factory(React);
  for(const [pointer,role,index]of [['/components/schemas/Alias','node',0],['/components/schemas/Alias/$ref','field',1],['/components/schemas/Alias/$ref','reference',2]]) {
    const button=Source({pointer,role});assert.equal(button.type,'button');assert.equal(button.props['aria-label'],labels.source);
    assert.equal(button.props['data-busyapi-source'],String(index));assert.equal(button.props['data-busyapi-source-authored'],'true');button.props.onClick();
  }
  const generated=Source({pointer:'/components/schemas/Boolean'});assert.equal(generated.props['aria-label'],labels.sourceOwner);generated.props.onClick();
  assert.deepEqual(received,[0,1,2,3]);assert(received.every(Number.isSafeInteger));
  assert.equal(Source({pointer:'/missing'}),null);assert.equal(Source({pointer:'/components/schemas/Alias/$ref',role:'node'}),null);
  assert.equal(JSON.stringify(presentation),captured);assert(!JSON.stringify(generated).includes('contracts.invalid'));
  assert.equal(documentationSourceControl(React,presentation,{}),undefined);
});
test('missing/ambiguous/malformed/extra authority and unknown display coordinates cannot install source controls',()=>{
  const presentation=input(),valid=action('/components/schemas/Alias');
  for(const sourceActions of [[{...valid,resource:'file:///private'}],[{...valid,index:0.5}],[{...valid,index:1}],[{...valid,authored:'true'}],[{...valid,role:'path'}],[{...valid,pointer:'/missing'}],[valid,{...valid,index:1}],[{...valid,pointer:'/components/schemas/~2'}],[action('/components/schemas/Alias/$ref')],new Array(200001)]) {
    assert.throws(()=>documentationSourceFactory(presentation,{sourceActions,onSource:()=>{},labels}),/busyapi.documentation.(source-|pointer)/);
  }
  assert.throws(()=>documentationSourceFactory(presentation,{sourceActions:[valid],labels}),/source-owner/);
  assert.throws(()=>documentationSourceFactory(presentation,{sourceActions:[valid],onSource:()=>{},labels:{source:'Source'}}),/labels/);
  assert.throws(()=>hasPresentationCoordinate({...presentation},'','node'),/projection/);
  assert(hasPresentationCoordinate(presentation,'/components/schemas/Alias','node'));
  assert(hasPresentationCoordinate(presentation,'/components/schemas/Alias/$ref','reference'));
});
