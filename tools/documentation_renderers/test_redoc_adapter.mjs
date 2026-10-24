import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {graphAddressedDisplay} from './graph_display.mjs';
import {mountRedocReference,redocDescriptionText,redocAdapterIdentity} from './redoc_adapter.mjs';
const {referenceDocument}=createRequire(new URL('../contract_engine/package.json',import.meta.url))('./dist/reference_projection.cjs');
const root='https://docs.invalid/spec.json';
const labels={schemas:'Schemas',previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages,definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited'};
function presentation() {
  const text=JSON.stringify({openapi:'3.2.1',info:{title:'T',version:'1','x-logo':{url:'https://must-not-load.invalid/logo'}},paths:{},components:{schemas:{A:{$id:'https://schema.invalid/a',type:'string'},B:{$ref:'https://schema.invalid/a'}}}});
  return graphAddressedDisplay(text,referenceDocument({root,snapshot:'redoc',resources:[{id:root,text,generation:1}]}),'https://display.invalid/index.html',{addresses:'document-pointer'});
}
function fake(prepare) {
  const state={unmounted:0};
  const api={React:{createElement:(type,props,...children)=>({type,props,children}),useState:()=>{throw Error('Hooks run only inside rendered components');}},HashRouter:'Router',Redoc:'Redoc',
    prepareApiDocs:async options=>{state.request=options;return prepare?prepare(options):{specType:'openapi',document:options.spec,items:[],store:{},options:options.options};},
    createRoot:(_element,options)=>{state.rootOptions=options;return{render:value=>{state.rendered=value;},unmount:()=>state.unmounted++};}};
  return {api,state};
}
test('pinned Redoc Swagger conversion is an explicit renderer limitation and never runs',async()=>{
  const text=JSON.stringify({swagger:'2.0',info:{title:'Native Swagger',version:'1'},paths:{}});
  const input=graphAddressedDisplay(text,referenceDocument({root,snapshot:'swagger',resources:[{id:root,text,generation:1}]}),'https://display.invalid/index.html',{addresses:'document-pointer'});
  const {api,state}=fake();await assert.rejects(mountRedocReference(input,{}, {api,onError:()=>{},labels}),/redoc-swagger-conversion/);assert.equal(state.request,undefined);assert.equal(state.rendered,undefined);assert.equal(input.spec.swagger,'2.0');
});
test('Redoc uses only supplied graph pointers and supported read-only/telemetry/logo options without mutating source',async()=>{
  const input=presentation(),captured=JSON.stringify(input),{api,state}=fake(),errors=[];
  const result=await mountRedocReference(input,{}, {api,onError:code=>errors.push(code),labels});
  assert.equal(redocAdapterIdentity.packageVersion,'3.0.1');
  assert.equal(state.request.spec.components.schemas.B.$ref,'#/components/schemas/A');
  assert.equal(state.request.spec.components.schemas.A.$id,'https://schema.invalid/a');
  assert.notEqual(state.request.spec,input.spec);state.request.spec.info.title='Vendor display normalization';
  assert.equal(JSON.stringify(input),captured);
  assert.equal(state.request.options.skipBundle,true);assert.equal(state.request.specUrl,undefined);
  const props=state.rendered.children[0].props;
  assert.equal(props.options.disableTelemetry,true);assert.equal(props.telemetryConfig.disabled,true);
  assert.equal(props.telemetryConfig.beforeSend({},[]),false);assert.equal(props.options.hideDownloadButtons,true);
  // The supported low-level component has no automatic logo/branding loader;
  // the authored extension remains intact in the private preparation input.
  assert.equal(state.request.spec.info['x-logo'].url,'https://must-not-load.invalid/logo');
  assert.equal(props.spec,undefined);assert.equal(props.specUrl,undefined);assert.deepEqual(errors,[]);
  result.close();result.close();assert.equal(state.unmounted,1);
});
test('cancellation before and during preparation cannot mount a late owner',async()=>{
  const cancelled=new AbortController();cancelled.abort();const before=fake();
  await assert.rejects(mountRedocReference(presentation(),{}, {api:before.api,onError:()=>{},labels,signal:cancelled.signal}),/cancelled/);
  assert.equal(before.state.request,undefined);
  let complete;const controller=new AbortController(),during=fake(options=>new Promise(resolve=>{complete=()=>resolve({specType:'openapi',document:options.spec,items:[],store:{},options:options.options});}));
  const pending=mountRedocReference(presentation(),{}, {api:during.api,onError:()=>{},labels,signal:controller.signal});
  controller.abort();complete();await assert.rejects(pending,/cancelled/);assert.equal(during.state.rendered,undefined);
});
test('malformed/crashed adapters and React failures report a masked non-success, never an empty successful result',async()=>{
  for(const prepare of [()=>{throw Error('private source value');},()=>({specType:'openapi',items:[],options:{},store:{},document:{openapi:'3.0.0'}})]){
    const errors=[],{api,state}=fake(prepare);
    await assert.rejects(mountRedocReference(presentation(),{}, {api,onError:code=>errors.push(code),labels}),/renderer-failed/);
    assert.deepEqual(errors,['busyapi.documentation.renderer-failed']);assert.equal(state.rendered,undefined);
  }
  const errors=[],{api,state}=fake();await mountRedocReference(presentation(),{}, {api,onError:code=>errors.push(code),labels});
  state.rootOptions.onUncaughtError(Error('private source value'));assert.equal(state.unmounted,1);assert.deepEqual(errors,['busyapi.documentation.renderer-failed']);
});
test('untrusted descriptions are bounded text, not DOM tags, URLs or executable Markdoc',()=>{
  assert.equal(redocDescriptionText([{type:'paragraph',children:[{type:'text',attributes:{content:'雪😀 <img src=https://must-not-load.invalid>'}}]},{type:'image',attributes:{src:'https://must-not-load.invalid'},children:[]}]),'雪😀 <img src=https://must-not-load.invalid>\n');
  assert.equal(redocDescriptionText({type:'tag',tag:'html',attributes:{name:'img',attrs:{src:'https://must-not-load.invalid/html'}},children:[]}),'<img src="https://must-not-load.invalid/html">');
  assert.throws(()=>redocDescriptionText('x'.repeat(2*1024*1024)),/description-limit/);
  const deep=[];let parent=deep;for(let i=0;i<140;i++){const child=[];parent.push(child);parent=child;}
  assert.throws(()=>redocDescriptionText(deep),/description-limit/);
});
