import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {graphAddressedDisplay} from './graph_display.mjs';
import {swaggerLocatedContent} from './swagger_content.mjs';
const {referenceDocument}=createRequire(new URL('../contract_engine/package.json',import.meta.url))('./dist/reference_projection.cjs');
const root='https://contracts.invalid/openapi.json';
const labels={schemas:'Schemas',webhooks:'Webhooks',previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages,definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited'};
const React={Fragment:'fragment',createElement:(type,props,...children)=>({type,props,children}),useState:()=>{throw Error('Presentation hooks are deferred until rendering');}};
const specPath=parts=>({toArray:()=>parts});
function fixture(version){
  const value={openapi:version,info:{title:'Source coordinates',version:'1'},paths:{'/p':{
    parameters:[{name:'filter',in:'query',schema:{type:'string'}},{name:'Filter',in:'query',schema:{type:'string'}}],
    post:{parameters:[{name:'filter',in:'query',schema:{type:'integer'}}],requestBody:{$ref:'#/components/requestBodies/Shared'},responses:{204:{description:'Bodyless'}}},
  }},components:{requestBodies:{Shared:{content:{'application/json':{schema:{$ref:'#/components/schemas/False'}}}}},schemas:{False:false}},
    webhooks:{Incoming:{post:{responses:{204:{description:'Webhook bodyless'}}}}}};
  value.paths['/p'].post.callbacks={Received:{$ref:'#/components/callbacks/Stored'}};
  value.components.callbacks={Stored:{'{$request.body#/url}':{post:{responses:{204:{description:'Callback bodyless'}}},
    ...(version.startsWith('3.2.')?{additionalOperations:{COPY:{responses:{204:{description:'Additional callback bodyless'}}}}}:{})}}};
  const text=JSON.stringify(value),projection=referenceDocument({root,snapshot:'located-content',resources:[{id:root,text,generation:1}]}),presentation=graphAddressedDisplay(text,projection,'https://display.invalid/index.html');
  const hooks=swaggerLocatedContent({React,Im:{fromJS:value=>Object.freeze({...value}),List:values=>values},getConfigs:()=>({busyApiPresentation:()=>presentation,busyApiLabels:labels})},()=>null);
  return {text,presentation,hooks};
}
for(const version of ['3.1.2','3.2.1'])test(`located Swagger ${version} schema views follow established ownership, never names or payload keys`,()=>{
  const {text,presentation,hooks}=fixture(version),before=JSON.stringify(presentation);
  const schema=hooks.Model(null)({specPath:specPath(['paths','/p','post','requestBody','content','application/json','schema'])});
  assert.equal(schema.props.pointer,'/components/requestBodies/Shared/content/application~1json/schema');
  assert.equal(hooks.Model(null)({specPath:specPath(['components','schemas','False'])}).props.pointer,'/components/schemas/False');
  assert.throws(()=>hooks.Model(null)({specPath:specPath(['info'])}),/content-source/);
  assert.throws(()=>hooks.Model(null)({name:'False',schema:false}),/content-source/);
  const callbacks=hooks.Callbacks(null)({specPath:specPath(['paths','/p','post','callbacks'])});
  assert.equal(callbacks.props.pointer,'/paths/~1p/post/callbacks');
  assert.throws(()=>hooks.Callbacks(null)({specPath:specPath(['info'])}),/content-source/);
  assert.throws(()=>hooks.Callbacks(null)({callbacks:{Received:{}}}),/content-source/);
  const models=hooks.Models(null)();assert.equal(models.children[1].props.pointer,'/components/schemas');
  const layout=hooks.BaseLayout('Original')({}),webhooks=layout.children[1].type();
  assert.equal(webhooks===null,version.startsWith('3.1.'));
  if(webhooks)assert.equal(webhooks.children[1].props.pointer,'/webhooks');
  assert.equal(JSON.stringify(presentation),before);assert.equal(presentation.canonicalText,text);
});
test('effective parameters retain case-sensitive overrides and a non-forgeable captured row owner',()=>{
  const {hooks,presentation}=fixture('3.2.1'),before=JSON.stringify(presentation);
  const parameters=hooks.parameters('Original')({specPath:specPath(['paths','/p','post','parameters'])}).props.parameters;
  assert.equal(parameters.length,2);assert.deepEqual(new Set(parameters.map(value=>value.name)),new Set(['filter','Filter']));
  const row=hooks.parameterRow(null)({rawParam:parameters.find(value=>value.name==='Filter')});
  const entry=row.children[0].children[0].props.entries[0];
  assert.equal(entry.inherited,true);assert.equal(entry.source.pointer,'/paths/~1p/parameters/1');
  assert.throws(()=>hooks.parameterRow(null)({rawParam:{...parameters[0]}}),/content-source/);
  assert.throws(()=>hooks.parameters('Original')({specPath:specPath(['paths','/p','post','responses'])}),/content-source/);
  assert.equal(JSON.stringify(presentation),before);
});
