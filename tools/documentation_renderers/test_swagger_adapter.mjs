import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {graphAddressedDisplay} from './graph_display.mjs';
import {additionalMethodIdentity, additionalMethodToken, readOnlySwaggerConfiguration, swaggerAdapterIdentity, busyApiSwaggerPlugin} from './swagger_adapter.mjs';
const {referenceDocument}=createRequire(new URL('../contract_engine/package.json',import.meta.url))('./dist/reference_projection.cjs');
const labels={previousPage:'Previous page',nextPage:'Next page',page:(page,pages)=>`${page}/${pages}`};

test('source controls bind after Swagger plugin registration and retain the captured owner index',()=>{
  const text='{"openapi":"3.2.1","info":{"title":"Source","version":"1"},"paths":{}}',root='https://display.invalid/index.html';
  const presentation=graphAddressedDisplay(text,referenceDocument({root,snapshot:'source',resources:[{id:root,text,generation:1}]}),root),received=[];
  let configuration={};
  const React={Fragment:'fragment',createContext:()=>({}),createElement:(type,props,...children)=>({type,props,children})};
  const plugin=busyApiSwaggerPlugin({React,Im:{fromJS:()=>{}},fn:{resolveSubtree:()=>{}},getConfigs:()=>configuration});
  configuration=readOnlySwaggerConfiguration(presentation,{onError:()=>{},labels:{...labels,source:'View source',sourceOwner:'View original owner'},sourceActions:[{index:0,pointer:'',role:'node',authored:true}],onSource:index=>received.push(index)});
  const info=plugin.wrapComponents.InfoContainer('Original')({}),control=info.children[1],view=control.type(control.props),button=view.type(view.props);
  assert.equal(button.type,'button');assert.equal(button.props['data-busyapi-source'],'0');button.props.onClick();assert.deepEqual(received,[0]);
});

test('additional view identities cannot shadow fixed methods or another authored token', () => {
  const methods = ['get', 'GET', 'COPY', 'copy', '__busyapi_additional_434f5059', "-!#$%&'*+.^_`|~012Az"];
  const identities = methods.map(additionalMethodIdentity);
  assert.equal(new Set(identities).size, methods.length);
  for (let index = 0; index < methods.length; index++) assert.equal(additionalMethodToken(identities[index]), methods[index]);
  for (const fixed of ['get', 'post', 'query', '', '__busyapi_additional_', '__busyapi_additional_0', '__busyapi_additional_gg', '__busyapi_additional_00']) assert.equal(additionalMethodToken(fixed), undefined);
  for (const invalid of ['', '雪', 'bad method', 'x'.repeat(257)]) assert.throws(() => additionalMethodIdentity(invalid));
});
test('whole-document display resolution caches exact input, preserves false/absence, rejects lost or stale results and reports failures',async()=>{
  const raw={openapi:'3.2.1',info:{title:'Input',version:'1'},paths:{},components:{schemas:{False:false}}};
  const frame=value=>({toJS:()=>structuredClone(value),get:key=>value[key],hasIn:path=>{
    let at=value;for(const key of path){if(at===null||typeof at!=='object'||!Object.hasOwn(at,key))return false;at=at[key];}return true;
  }});
  let current=frame(raw),calls=0,fault,release,started,strategies,displayUri='https://display.invalid/captured.json';
  const waitForStart=()=>new Promise(resolve=>{started=resolve;});
  const failures=[];
  const system={Im:{fromJS:()=>{}},React:{createElement:()=>{},createContext:()=>({})},
    getConfigs:()=>({uncaughtExceptionHandler:error=>failures.push(error.message),busyApiPresentation:()=>({displayUri}),busyApiResolveStrategies:strategies}),
    specSelectors:{specJson:()=>current},fn:{resolveSubtree:async(spec,path,options)=>{
      calls++;assert.deepEqual(path,[]);assert.equal(options.baseDoc,displayUri);assert.throws(()=>options.requestInterceptor({url:'https://must-not-load.invalid'}));
      if(fault==='wait')await new Promise(done=>{release=done;started();});
      if(fault==='crash')throw Error('synthetic-private-content');
      if(fault==='empty')return {};
      if(fault==='lost')delete spec.components;
      return {spec,errors:fault==='errors'?[{message:'not a clean result'}]:[]};
    }}};
  const adapter=busyApiSwaggerPlugin(system);
  assert.equal((await adapter.fn.resolveSubtree({},['components','schemas','False'],{})).spec,false);
  assert.equal((await adapter.fn.resolveSubtree({},['servers'],{})).spec,undefined);
  assert.equal(calls,1);assert.deepEqual(failures,[]);
  strategies=[];
  assert.equal((await adapter.fn.resolveSubtree({},['components','schemas','False'],{})).spec,false);assert.equal(calls,2);
  for(const problem of ['crash','empty','errors','lost']) {
    fault=problem;current=frame(raw);
    await assert.rejects(adapter.fn.resolveSubtree({},['components','schemas','False'],{}),/busyapi.documentation.(resolver-failed|target)/);
  }
  fault='wait';current=frame(raw);
  const firstStarted=waitForStart();
  const pending=adapter.fn.resolveSubtree({},['components','schemas','False'],{});
  await firstStarted;
  current=frame({...raw,info:{title:'Replacement',version:'1'}});release();
  await assert.rejects(pending,/busyapi.documentation.stale/);
  fault='wait';current=frame(raw);
  const identityStarted=waitForStart();
  const identityPending=adapter.fn.resolveSubtree({},['components','schemas','False'],{});
  await identityStarted;
  displayUri='https://display.invalid/next.json';release();await assert.rejects(identityPending,/busyapi.documentation.stale/);
  fault='wait';current=frame(raw);
  const strategyStarted=waitForStart(),strategyPending=adapter.fn.resolveSubtree({},[],{});
  await strategyStarted;strategies=[];release();await assert.rejects(strategyPending,/busyapi.documentation.stale/);
  assert(failures.includes('busyapi.documentation.stale'));assert(!failures.some(value=>value.includes('private-content')));
  assert.throws(()=>adapter.fn.fetch({url:'https://must-not-call.invalid'}),/read-only/);
  assert.throws(()=>adapter.fn.execute({}),/read-only/);
  const synchronous=busyApiSwaggerPlugin({...system,fn:{resolveSubtree:()=>{throw Error('private synchronous fault');}}});
  await assert.rejects(synchronous.fn.resolveSubtree({},[],{}),/busyapi.documentation.resolver-failed/);
});
test('configuration is read-only without converting or mutating the supplied contract', () => {
  for (const openapi of ['3.1.2', '3.2.1']) {
    const spec = Object.freeze({openapi, info: Object.freeze({title: 'T', version: '1'}), paths: Object.freeze({})});
    const text=JSON.stringify(spec),root='https://display.invalid/index.html',projection=referenceDocument({root,snapshot:'configuration',resources:[{id:root,text,generation:1}]}),presentation=graphAddressedDisplay(text,projection,root);
    const errors = [], configuration = readOnlySwaggerConfiguration(presentation, {labels,onError:code=>errors.push(code)});
    assert.equal(configuration.spec, presentation.spec);assert.equal(configuration.busyApiPresentation(),presentation);assert.deepEqual(configuration.supportedSubmitMethods, []);
    for (const key of ['persistAuthorization', 'tryItOutEnabled', 'queryConfigEnabled', 'withCredentials']) assert.equal(configuration[key], false);
    assert.equal(configuration.validatorUrl, null);assert.equal(configuration.configUrl, null);
    assert.deepEqual(configuration.urls, []);assert.equal(configuration.url, '');
    assert.throws(() => configuration.requestInterceptor({url: 'https://must-not-load.invalid'}), /busyapi.documentation.read-only/);
    configuration.uncaughtExceptionHandler(Error('busyapi.documentation.read-only'));
    configuration.uncaughtExceptionHandler(Error('synthetic-sensitive-source'));
    assert.deepEqual(errors,['busyapi.documentation.read-only','busyapi.documentation.renderer-failed']);
    assert.throws(()=>readOnlySwaggerConfiguration(presentation),/busyapi.documentation.error-owner/);
    const pointers=graphAddressedDisplay(text,projection,root,{addresses:'document-pointer'});
    assert.throws(()=>readOnlySwaggerConfiguration(pointers,{labels,onError:()=>{}}),/busyapi.documentation.projection/);
  }
  assert.throws(() => readOnlySwaggerConfiguration({openapi:'3.0.4'}));
  assert.equal(swaggerAdapterIdentity.packageVersion, '5.33.2');
});
