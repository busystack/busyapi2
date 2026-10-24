// Development-only native WebKit fixture staging. Never installed/exported.
// Supplied candidate assets and canonical graph snapshots, no runtime loader.
import assert from 'node:assert/strict';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {compileSwaggerModule} from './swagger_module_build.mjs';
const output=path.resolve(process.argv[2]??'');
assert(/^\/tmp\/busyapi-documentation-native-[^/]+\/renderer-assets$/.test(output));
const engine=createRequire(new URL('../contract_engine/package.json',import.meta.url));
const {deriveBundle}=engine('./dist/derived_bundle.cjs'),{referenceDocument}=engine('./dist/reference_projection.cjs'),{build}=engine('esbuild');
const {SourceDocument,RawJsonValue}=engine('./dist/document.cjs');
const swaggerModuleTree=process.env.BUSYAPI_TEST_SWAGGER_MODULE_TREE;
const swagger=(swaggerModuleTree?await compileSwaggerModule({directory:swaggerModuleTree,format:'esm'}):await build({entryPoints:[fileURLToPath(new URL('./swagger_entry.mjs',import.meta.url))],nodePaths:[fileURLToPath(new URL('../probes/m2/node_modules',import.meta.url))],bundle:true,write:false,format:'esm',platform:'browser',target:'es2022',define:{'process.env.NODE_ENV':'"production"'},logLevel:'silent'})).outputFiles[0].text;
const redoc=(await build({entryPoints:[fileURLToPath(new URL(process.env.BUSYAPI_DOCUMENTATION_TEST_TRACE==='1'?'./test_redoc_native_entry.mjs':'./redoc_entry.mjs',import.meta.url))],nodePaths:[fileURLToPath(new URL('../probes/m2/node_modules',import.meta.url))],bundle:true,write:false,format:'esm',platform:'browser',target:'es2022',define:{'process.env.NODE_ENV':'"production"'},logLevel:'silent'})).outputFiles[0].text;
for(const renderer of ['swagger','redoc'])for(const family of ['31','32']){
  const directory=path.join(output,renderer+'-'+family);await mkdir(directory,{recursive:true});
  const root='https://contracts.invalid/root.json',original=await readFile(new URL(`../../fixtures/compatibility/oas${family}.json`,import.meta.url),'utf8'),schema=await readFile(new URL('../../fixtures/compatibility/schema.json',import.meta.url),'utf8');
  let text=original;
  if(family==='32') {
    const document=new SourceDocument(text,root);
    text=document.set('/paths/~1things/additionalOperations/COPY/responses/200/content',
      new RawJsonValue('{"application/json":{"schema":false,"example":{"$ref":"additional-operation literal payload","large":9007199254740993.00}}}'));
  }
  if(renderer==='redoc') {
    // Augment only the temporary native fixture through the production CST.
    // Never round-trip these deliberate numeric lexemes through JS numbers.
    const changes=[
      ['/components/schemas/BusyApiNativeFalse',false],
      ['/components/schemas/BusyApiNativePrecise',new RawJsonValue('{"type":"integer","minimum":9007199254740993,"examples":[9007199254740993.0]}')],
      ['/paths/~1native-exact',new RawJsonValue('{"parameters":[{"name":"X-Exact","in":"header","schema":{"type":"integer","minimum":9007199254740993}}],"post":{"summary":"Native exact content sentinel","requestBody":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/BusyApiNativePrecise"},"example":9007199254740993.0},"text/plain":{"schema":{"type":"string"},"example":"serialized 雪😀"}}},"responses":{"204":{"description":"Bodyless native response"}}}}')],
    ];
    for(const [pointer,value]of changes) {
      const document=new SourceDocument(text,root);assert(!document.nodes.has(pointer));text=document.set(pointer,value);
    }
    assert(text.includes('9007199254740993.0'));assert(original!==text);
  }
  const snapshot='snapshot-1',derived=deriveBundle({root,snapshot,outputId:'https://derived.invalid/openapi.json',resources:[{id:root,text,generation:1},{id:'https://contracts.invalid/schema.json',text:schema,generation:1}]});
  const projection=referenceDocument({root:derived.output.id,snapshot,resources:[{id:derived.output.id,text:derived.output.text,generation:1}]});
  const operationPointer=projection.sections.find(section=>section.kind==='operation'&&section.source.pointer.startsWith('/paths/'))?.source.pointer;
  assert(operationPointer);
  const sourceActions=[{index:0,pointer:'',role:'node',authored:true},{index:1,pointer:operationPointer,role:'node',authored:true}];
  const assets={
    'index.html':`<!doctype html><html><head><meta charset="utf-8">${renderer==='swagger'?'<link rel="stylesheet" href="vendor.css">':''}<script type="module" src="bootstrap.mjs"></script></head><body><div id="reference"></div></body></html>`,
    'snapshot.json':JSON.stringify({text:derived.output.text,projection,sourceActions}),
    'vendor.js':renderer==='swagger'&&!swaggerModuleTree?await readFile(new URL('../probes/m2/node_modules/swagger-ui-dist/swagger-ui-bundle.js',import.meta.url),'utf8'):'',
    'vendor.css':renderer==='swagger'?await readFile(swaggerModuleTree?path.join(swaggerModuleTree,'node_modules/swagger-ui/dist/swagger-ui.css'):new URL('../probes/m2/node_modules/swagger-ui-dist/swagger-ui.css',import.meta.url),'utf8'):'',
    'graph_display.mjs':await readFile(new URL('./graph_display.mjs',import.meta.url),'utf8'),
    'source_actions.mjs':await readFile(new URL('./source_actions.mjs',import.meta.url),'utf8'),
    'adapter.mjs':renderer==='swagger'?swagger:redoc,
  };
  assets['bootstrap.mjs']=`
const report=(kind,extra={})=>window.webkit.messageHandlers.busyapiDocumentation.postMessage({version:1,snapshot:'snapshot-1',kind,...extra});
const diagnostic=value=>window.webkit.messageHandlers.busyapiFixture?.postMessage(String(value).slice(0,2000));
window.addEventListener('error',event=>{diagnostic(String(event.error?.message??event.message)+' '+String(event.error?.stack??''));report('failed',{code:'renderer-failed'});});
window.addEventListener('unhandledrejection',event=>{diagnostic(String(event.reason?.message??event.reason)+' '+String(event.reason?.stack??''));report('failed',{code:'renderer-failed'});});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
try {
  const {text,projection,sourceActions}=await(await fetch('snapshot.json')).json();
  window.capturedSource=text;window.fixtureSeen=[];window.fixtureBooleans=[];window.fixtureAuthoredValues=Object.create(null);
  const capture=()=>{
    fixtureSeen.push(document.body.innerText);
    for(const value of document.querySelectorAll('[data-busyapi-boolean-schema]'))if(value.getClientRects().length)fixtureBooleans.push(value.getAttribute('data-busyapi-boolean-schema'));
    for(const value of document.querySelectorAll('[data-busyapi-authored-value]'))if(value.getClientRects().length&&getComputedStyle(value).visibility!=='hidden') {
      const pointer=value.getAttribute('data-busyapi-authored-value'),values=fixtureAuthoredValues[pointer]??=[];
      if(!values.includes(value.textContent))values.push(value.textContent);
    }
  };
  ${renderer==='swagger'?`
  ${swaggerModuleTree?`
  window.reference=await(await import('./adapter.mjs')).mount(text,projection,document.getElementById('reference'),{sourceActions,onSource:index=>report('source',{index}),labels:{source:'View source',sourceOwner:'View original owner',schemas:'Schemas',webhooks:'Webhooks',definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited',previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages},onError:()=>report('failed',{code:'renderer-failed'})});
  window.ui=reference.system;
  `:`
  await new Promise((resolve,reject)=>{const script=document.createElement('script');script.src='vendor.js';script.onload=resolve;script.onerror=()=>reject(Error('vendor load'));document.head.append(script);});
  const configuration=(await import('./adapter.mjs')).configuration(text,projection,'https://busyapi-display.invalid/snapshot-1/document.json',{sourceActions,onSource:index=>report('source',{index}),labels:{source:'View source',sourceOwner:'View original owner',schemas:'Schemas',webhooks:'Webhooks',definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited',previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages},onError:code=>{diagnostic('Fixture owner: '+code);report('failed',{code:'renderer-failed'});}});
  configuration.plugins.unshift(system=>{const original=system.fn.resolveSubtree;return {fn:{resolveSubtree:async(...args)=>{try{const result=await original(...args);if(result.errors?.length)diagnostic('Fixture resolver: '+JSON.stringify({baseDoc:args[2]?.baseDoc,errors:result.errors.map(error=>({name:error.name,message:error.message,cause:error.cause?.message}))}));return result;}catch(error){diagnostic('Fixture resolver threw: '+error.name+': '+error.message);throw error;}}}};});
  window.ui=SwaggerUIBundle({...configuration,dom_id:'#reference'});
  `}
  for(let index=0;index<60&&!document.querySelector('.swagger-ui .info');index++)await sleep(50);
  for(let index=0;index<12;index++){for(const branch of document.querySelectorAll('[data-busyapi-authored-branch]'))branch.open=true;await sleep(40);capture();window.scrollBy(0,500);}
  for(const tab of document.querySelectorAll('[role=tab]'))if(tab.textContent==='Example Value'){tab.click();await sleep(20);capture();}
  window.fixtureShowSource=()=>window.scrollTo(0,0);
  `:`
  window.reference=await(await import('./adapter.mjs')).mount(text,projection,document.getElementById('reference'),{sourceActions,onSource:index=>report('source',{index}),labels:{source:'View source',sourceOwner:'View original owner',schemas:'Schemas',previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages,definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited'},onError:()=>report('failed',{code:'renderer-failed'})});
  let sourceRoute;
  const expand=async()=>{
    const deadline=performance.now()+2000;
    while(true) {
      for(const branch of document.querySelectorAll('[data-busyapi-authored-branch]'))branch.open=true;
      await sleep(20);
      const branches=[...document.querySelectorAll('[data-busyapi-authored-branch]')];
      if(branches.every(branch=>branch.open&&[...branch.querySelectorAll('[data-busyapi-authored-content]')].some(section=>section.getAttribute('data-busyapi-authored-content')===branch.getAttribute('data-busyapi-authored-branch'))))return;
      if(performance.now()>deadline)throw Error('fixture lazy content deadline');
    }
  };
  const slugs=new Set(['']);function visit(items){for(const item of items){if(item.routeSlug&&item.content)slugs.add(item.routeSlug);visit(item.items??[]);}}visit(reference.items);
  for(const slug of slugs){const definitions=new Set();location.hash='#/'+slug.replace(/^\\//,'');
    for(let index=0;index<12;index++){
    await sleep(40);await expand();capture();
    for(const button of document.querySelectorAll('[data-busyapi-definition]')){const target=button.getAttribute('data-busyapi-definition');if(button.isConnected&&!definitions.has(target)){definitions.add(target);button.click();break;}}
    await expand();capture();window.scrollBy(0,500);
    if(document.querySelector('[data-busyapi-source="1"]'))sourceRoute=slug;
  }}
  if(sourceRoute===undefined)throw Error('missing source control');
  window.fixtureShowSource=()=>{location.hash='#/'+sourceRoute.replace(/^\\//,'');};
  `}
  const seen=fixtureSeen.join('\\n');
  const expected=${JSON.stringify(['Compatibility operation sentinel','Schema property sentinel','payload data',...(family==='32'?['QUERY sentinel','COPY sentinel']:[]),...(renderer==='redoc'?['Native exact content sentinel','Inherited']:[])])};
  const missing=expected.filter(text=>!seen.includes(text));
  if(missing.length)throw Error('missing fixture content: '+missing.join(', '));
  // WebKit innerText includes visual-wrap line breaks. Assert complete logical
  // values at their actual visible, graph-typed field instead of a coincident
  // number/text substring elsewhere on the page. Nothing hidden counts.
  const values=${JSON.stringify([
    ...(family==='32'?[['/paths/~1things/additionalOperations/COPY/responses/200/content/application~1json/example','{"$ref":"additional-operation literal payload","large":9007199254740993.00}']]:[]),
    ...(renderer==='redoc'?[
      ['/paths/~1native-exact/post/requestBody/content/application~1json/example','9007199254740993.0'],
      ['/paths/~1native-exact/post/requestBody/content/text~1plain/example','serialized 雪😀'],
      ['/components/schemas/BusyApiNativePrecise/minimum','9007199254740993'],
      ['/components/schemas/BusyApiNativePrecise/examples','[9007199254740993.0]'],
    ]:[]),
  ])};
  for(const [pointer,value]of values)if(!fixtureAuthoredValues[pointer]?.includes(value))throw Error('missing/inexact visible fixture field: '+pointer);
  ${renderer==='redoc'?"if(!fixtureBooleans.includes('false')||seen.includes('9007199254740992'))throw Error('inexact schema content');":''}
  if([...document.querySelectorAll('button')].some(button=>/^(authorize|try it out|execute|open in .+|ask ai)$/i.test(button.textContent.trim())))throw Error('execution control');
  report('ready');
} catch(error) {diagnostic('Fixture bootstrap: '+String(error?.name)+': '+String(error?.message??error)+' '+String(error?.stack??''));report('failed',{code:'renderer-failed'});}
`;
  for(const [name,contents]of Object.entries(assets))await writeFile(path.join(directory,name),contents,{flag:'wx'});
}
