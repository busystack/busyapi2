import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createRequire} from 'node:module';
import {graphAddressedDisplay} from './graph_display.mjs';
import {redocAuthoredContent} from './redoc_content.mjs';
const {referenceDocument}=createRequire(new URL('../contract_engine/package.json',import.meta.url))('./dist/reference_projection.cjs');
const root='https://contracts.invalid/openapi.json',labels={previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages,definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited'};
const React={createElement:(type,props,...children)=>({type,props,children}),useState:()=>{throw Error('Hooks are deferred until rendering');}};
function presentation() {
  const value={openapi:'3.2.1',info:{title:'Presentation boundary',version:'1'},paths:{'/value':{additionalOperations:{COPY:{responses:{204:{description:'Bodyless'}}}}}},components:{schemas:{Boolean:false}}};
  value.paths['/value'].additionalOperations.COPY.callbacks={Same:{'{$request.body#/url}':{additionalOperations:{COPY:{summary:'Context-owned callback',responses:{204:{description:'Bodyless callback'}}}}}}};
  const text=JSON.stringify(value);
  return graphAddressedDisplay(text,referenceDocument({root,snapshot:'redoc-content',resources:[{id:root,text,generation:1}]}),'https://display.invalid/index.html',{addresses:'document-pointer'});
}
const schema=()=>({type:'link',content:{itemVariant:'schema',children:[{nodeType:'markdoc',content:[{type:'tag',tag:'schemaDefinition',attributes:{schemaRef:'#/components/schemas/Boolean'}}]}]}});
const operation=()=>({type:'link',isAdditionalOperation:true,httpPath:'/value',httpVerb:'COPY',content:{itemVariant:'httpItem',meta:{pointer:'/paths/~1value/COPY'},children:[{nodeType:'container',children:[
  {nodeType:'header',label:'Responses',showPageActions:true},{nodeType:'item-content',variant:'responses',pointer:'/paths/~1value/COPY/responses'},
],panels:[{children:[{kind:'response',examples:[{value:123}]}]}]}]}});
test('Redoc callback content retains the containing operation identity and never trusts an authored content token',()=>{
  const item=operation(),callback={nodeType:'item-content',variant:'callback',pointer:'/paths/~1value/COPY/callbacks'};
  item.content.children.push({nodeType:'container',children:[callback],panels:[]});
  const adapted=redocAuthoredContent(React,presentation(),[item],labels),token=adapted.items[0].content.children[1].children[0].content;
  assert.equal(adapted.render(token).props.pointer,'/paths/~1value/additionalOperations/COPY/callbacks');
  assert.equal(adapted.render({}),undefined);
  callback.pointer='/paths/~1other/COPY/callbacks';
  assert.throws(()=>redocAuthoredContent(React,presentation(),[item],labels),/content-source/);
});
test('public Redoc content nodes use proved coordinates and exact native fields without changing source or preparation output',()=>{
  const input=presentation(),items=[schema(),operation()],captured=JSON.stringify(items),source=JSON.stringify(input);
  const adapted=redocAuthoredContent(React,input,items,labels);
  assert.equal(JSON.stringify(items),captured);assert.equal(JSON.stringify(input),source);
  assert.equal(adapted.items[1].content.meta.pointer,'/paths/~1value/additionalOperations/COPY');
  const definition=adapted.items[0].content.children[0].content,response=adapted.items[1].content.children[0].children[1].content;
  assert.equal(adapted.render(definition).props.pointer,'/components/schemas/Boolean');
  assert.equal(adapted.render(response).props.pointer,'/paths/~1value/additionalOperations/COPY/responses');
  assert.deepEqual(adapted.items[1].content.children[0].panels,[]);
  assert.equal(adapted.items[1].content.children[0].children[0].showPageActions,false);
  assert.equal(adapted.render({}),undefined);assert.equal(adapted.render(JSON.parse(JSON.stringify(definition))),undefined);
  // Authored tags are never interpreted as native/render capabilities.
  const authored={nodeType:'markdoc',content:[{type:'tag',tag:'schemaDefinition',attributes:{schemaRef:'#/components/schemas/Boolean'}}]};
  const page=operation();page.content.children[0].children.push(authored);
  const untouched=redocAuthoredContent(React,input,[page],labels).items[0].content.children[0].children[2];
  assert.equal(untouched,authored);assert.equal(adapted.render(untouched.content),undefined);
});
test('unknown/mismatched renderer ownership fails closed rather than guessing by name, path or operationId',()=>{
  for(const mutate of [
    item=>{item.httpPath='/missing';},item=>{item.httpVerb='copy';},item=>{item.isAdditionalOperation=false;},
    item=>{item.content.children[0].children[1].pointer='/paths/~1other/COPY/responses';},
  ]){
    const item=operation();mutate(item);
    assert.throws(()=>redocAuthoredContent(React,presentation(),[item],labels),/content-source/);
  }
  const item=schema();item.content.children[0].content[0].attributes.schemaRef='#/info';
  assert.throws(()=>redocAuthoredContent(React,presentation(),[item],labels),/content-source/);
  assert.throws(()=>redocAuthoredContent(React,presentation(),[],{}),/labels/);
});
for(const version of ['3.1.2','3.2.1'])for(const webhooks of [false,true])test(`referenced Path Item operation uses its captured definition, not a guessed local operation ${version} webhooks=${webhooks}`,()=>{
  const additional=version.startsWith('3.2'),method=additional?'COPY':'get',group=webhooks?'webhooks':'paths';
  const object={responses:{204:{description:'Shared bodyless response'}}},path=additional?{additionalOperations:{[method]:object}}:{[method]:object};
  const value={openapi:version,info:{title:'Shared ownership',version:'1'},paths:{},[group]:{'/value':{$ref:'#/components/pathItems/First'}},components:{pathItems:{First:{$ref:'#/components/pathItems/Owner'},Owner:path}}};
  const text=JSON.stringify(value),input=graphAddressedDisplay(text,referenceDocument({root,snapshot:'redoc-shared-content',resources:[{id:root,text,generation:1}]}),'https://display.invalid/index.html',{addresses:'document-pointer'});
  const display=`/${group}/~1value/${method}`,owner='/components/pathItems/Owner/'+(additional?'additionalOperations/':'')+method;
  const item={type:'link',isAdditionalOperation:additional,isWebhook:webhooks,httpPath:'/value',httpVerb:method,content:{itemVariant:'httpItem',meta:{pointer:display},children:[{nodeType:'item-content',variant:'responses',pointer:display+'/responses'}]}};
  const before=JSON.stringify(item),adapted=redocAuthoredContent(React,input,[item],labels);
  assert.equal(adapted.items[0].content.meta.pointer,owner);
  assert.equal(adapted.render(adapted.items[0].content.children[0].content).props.pointer,owner+'/responses');
  assert.equal(JSON.stringify(item),before);
  item.httpVerb=additional?'copy':'post';
  assert.throws(()=>redocAuthoredContent(React,input,[item],labels),/content-source/);
});
test('public CE routes disambiguate logical contexts deterministically, retain tag aliases and avoid existing route collisions',()=>{
 const value={openapi:'3.2.1',info:{title:'Route identities',version:'1'},paths:{'/one':{$ref:'#/components/pathItems/Shared'},'/two':{$ref:'#/components/pathItems/Shared'}},components:{pathItems:{Shared:{get:{operationId:'same',responses:{204:{description:'No body'}}}}}}};
 const text=JSON.stringify(value),projection=referenceDocument({root,snapshot:'routes',resources:[{id:root,text,generation:1}]}),input=graphAddressedDisplay(text,projection,'https://display.invalid/index.html',{addresses:'document-pointer'});
 const context=projection.sections.find(section=>section.source.pointer==='/components/pathItems/Shared/get').contexts[0];
 const collision='/busyapi-operation/'+context.navigationId;
 const item=path=>({type:'link',httpPath:path,httpVerb:'get',routeSlug:'/same',link:'/same',content:{itemVariant:'httpItem',meta:{pointer:'/paths/'+path.replaceAll('/','~1')+'/get'},children:[]}});
 const first=item('/one'),second=item('/two'),alias=item('/one');
 const items=[{type:'group',items:[first,second]},{type:'group',items:[alias]},{type:'link',routeSlug:collision,link:collision}],before=JSON.stringify(items);
 const adapted=redocAuthoredContent(React,input,items,labels).items;
 assert.equal(adapted[0].items[0].routeSlug,collision+'-1');
 assert.equal(adapted[1].items[0].routeSlug,adapted[0].items[0].routeSlug,'Tag aliases of one logical operation retain one route');
 assert.notEqual(adapted[0].items[0].routeSlug,adapted[0].items[1].routeSlug);
 assert.equal(adapted[0].items[0].link,adapted[0].items[0].routeSlug);
 assert.equal(adapted[2].routeSlug,collision,'An existing unrelated presentation link is never rewritten');
 const reversed=redocAuthoredContent(React,input,[second,first,alias,items[2]],labels).items;
 assert.equal(reversed[0].routeSlug,adapted[0].items[1].routeSlug);assert.equal(reversed[1].routeSlug,adapted[0].items[0].routeSlug);
 const alone=redocAuthoredContent(React,input,[first,alias],labels).items;
 assert.deepEqual(alone.map(item=>item.routeSlug),['/same','/same'],'Grouping alone does not create a route collision');
 assert.equal(JSON.stringify(items),before);assert.equal(input.canonicalText,text);
 assert.throws(()=>redocAuthoredContent(React,input,[{...first,link:'/unrelated'},second],labels),/route-owner/);
});
