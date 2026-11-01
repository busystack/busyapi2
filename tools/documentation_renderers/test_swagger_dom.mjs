// Development-only DOM qualification. Uses the retained exact probe lock;
// Playwright/Chromium and the probe dependencies are not production assets.
import assert from 'node:assert/strict';
import {before, after, test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {swaggerAdapterIdentity, additionalMethodIdentity} from './swagger_adapter.mjs';
import {authoredDocument} from './test_fixtures/authored_document.mjs';
import {compileSwaggerModule} from './swagger_module_build.mjs';
import {readAuthoredPanels} from './test_authored_reader.mjs';

const require = createRequire(new URL('../probes/m2/package.json', import.meta.url));
const {chromium} = require('playwright');
const engine = createRequire(new URL('../contract_engine/package.json', import.meta.url));
const {deriveBundle} = engine('./dist/derived_bundle.cjs'),{build}=engine('esbuild');
const {referenceDocument} = createRequire(new URL('../contract_engine/package.json', import.meta.url))('./dist/reference_projection.cjs');
const {referenceDisplay} = engine('./dist/reference_display.cjs');
const {pathContexts}=engine('../../fixtures/compatibility/reference_display.cjs');
const packageRoot = new URL('../probes/m2/node_modules/swagger-ui-dist/', import.meta.url);
const packageInfo = JSON.parse(await readFile(new URL('package.json', packageRoot), 'utf8'));
assert.equal(packageInfo.version, swaggerAdapterIdentity.packageVersion);
assert.equal(packageInfo.license, 'Apache-2.0');
const origin = 'http://busyapi-doc-test.invalid';
// Qualify the supported npm browser-module path independently from the
// historical self-contained distribution. The optional tree is build input,
// never a project/runtime resolver or an alternative semantic implementation.
const moduleTree=process.env.BUSYAPI_TEST_SWAGGER_MODULE_TREE;
const ordinaryRequests=moduleTree?[origin+'/index.html']:[origin+'/index.html',origin+'/swagger_entry.mjs'];
let browser,source;
before(async () => {
  source=(moduleTree?await compileSwaggerModule({directory:moduleTree}):await build({entryPoints:[fileURLToPath(new URL('./swagger_entry.mjs',import.meta.url))],
    nodePaths:[fileURLToPath(new URL('../probes/m2/node_modules',import.meta.url))],
    bundle:true,write:false,format:'esm',platform:'browser',target:'es2022',define:{'process.env.NODE_ENV':'"production"'},logLevel:'silent'})).outputFiles[0].text;
  browser = await chromium.launch({headless:true, chromiumSandbox:true,
    ...(process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE ? {executablePath:process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE} : {})});
});
after(async () => { await browser?.close(); });

async function open(text, projection, displayUri, sourceActions) {
  projection??=referenceDocument({root:origin+'/index.html',snapshot:'swagger-inline',resources:[{id:origin+'/index.html',text,generation:1}]});
  const context = await browser.newContext({serviceWorkers:'block'});
  context.setDefaultTimeout(10000);
  const page = await context.newPage(), requests = [], denied = [], errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if(message.type()==='error')errors.push(message.text()); });
  page.on('popup', () => errors.push('Unexpected popup'));
  await context.route('**/*', route => {
    const url = route.request().url();requests.push(url);
    if(url===origin+'/index.html')return route.fulfill({contentType:'text/html',
      headers:{'Content-Security-Policy':"default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'"},
      body:'<!doctype html><html><head></head><body><div id="reference"></div></body></html>'});
    if(url===origin+'/swagger_entry.mjs')return route.fulfill({contentType:'text/javascript',body:source});
    denied.push(url);return route.abort('blockedbyclient');
  });
  await page.goto(origin+'/index.html');
  if(moduleTree)await page.addScriptTag({content:source});
  else await page.addScriptTag({path:fileURLToPath(new URL('swagger-ui-bundle.js', packageRoot))});
  await page.addStyleTag({path:moduleTree?path.join(moduleTree,'node_modules/swagger-ui/dist/swagger-ui.css'):fileURLToPath(new URL('swagger-ui.css', packageRoot))});
  await page.evaluate(async ({text, projection,displayUri,sourceActions,module}) => {
    window.busyapiDocumentationFailures=[];window.busyapiTestFailureDetails=[];window.busyapiSourceRequests=[];
    const options={...(sourceActions?{sourceActions,onSource:index=>window.busyapiSourceRequests.push(index)}:{}),labels:{source:'View source',sourceOwner:'View original owner',schemas:'Schemas',webhooks:'Webhooks',definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited',previousPage:'Previous page',nextPage:'Next page',page:(page,pages)=>`${page}/${pages}`},onError:code=>window.busyapiDocumentationFailures.push(code)};
    if(module){
      window.busyapiReference=await BusyApiSwagger.mount(text,projection,document.getElementById('reference'),options);
      window.ui=busyapiReference.system;window.busyapiPresentation=ui.getConfigs().busyApiPresentation();return;
    }
    const {configuration:configure}=await import('/swagger_entry.mjs');
    const configuration=configure(text,projection,displayUri??window.location.href,options);
    window.busyapiPresentation=configuration.busyApiPresentation();
    configuration.plugins.unshift(system=>{const original=system.fn.resolveSubtree;return {fn:{resolveSubtree:async(...args)=>{try {const result=await original(...args);if(result.errors?.length)window.busyapiTestFailureDetails.push(JSON.stringify(result.errors.map(error=>({name:error.name,message:error.message,cause:error.cause?.message}))));return result;}catch(error){window.busyapiTestFailureDetails.push(String(error?.name)+': '+String(error?.message)+' '+String(error?.stack).slice(0,700));throw error;}}}};});
    const report=configuration.uncaughtExceptionHandler;
    configuration.uncaughtExceptionHandler=error=>{window.busyapiTestFailureDetails.push(String(error?.stack??error).slice(0,700));report(error);};
    window.ui=window.SwaggerUIBundle({...configuration, dom_id:'#reference'});
  }, {text,projection,displayUri,sourceActions,module:Boolean(moduleTree)});
  await page.locator('.swagger-ui .info').waitFor();
  return {context, page, requests, denied, errors};
}
async function completeText(page) {
  // Swagger 5.33 virtualizes operations/models. Visit the full document rather
  // than accepting an initial page-load/version-banner sentinel.
  const seen = new Set();
  for(let count=0; count<50; count++) {
    await page.evaluate(()=>{for(const branch of document.querySelectorAll('[data-busyapi-authored-branch]'))branch.open=true;});
    seen.add(await page.locator('body').innerText());
    await page.evaluate(() => window.scrollTo(0, (window.scrollY+500)%(Math.max(1,document.documentElement.scrollHeight-window.innerHeight+1))));
    await page.waitForTimeout(30);
  }
  // Schema and authored Example Value are separate real controls. Inspect both
  // instead of treating a collapsed/inactive example as rendered content.
  for(const tab of await page.getByRole('tab',{name:'Example Value',exact:true}).all()) {
    await tab.click();
    seen.add(await page.locator('body').innerText());
  }
  // The pinned renderer has separate callback/parameter tabs. Visit the real
  // controls, not hidden DOM text, then restore the request/parameter surface.
  for(const tab of await page.locator('.tab-header .tab-item').filter({hasText:/^Callbacks$/}).elementHandles()){
    if(!await tab.evaluate(node=>node.isConnected))continue;
    await tab.click();seen.add(await readAuthoredPanels(page));
  }
  for(const tab of await page.locator('.tab-header .tab-item').filter({hasText:/^Parameters$/}).elementHandles())if(await tab.evaluate(node=>node.isConnected))await tab.click();
  return [...seen].join('\n');
}
for(const version of ['3.1.2','3.2.1'])test(`Swagger ${version} shared Operation uses the distinct logical Path Item parameter owner`,async()=>{
  const input=pathContexts(version),before=input.resources.map(resource=>resource.text),display=referenceDisplay({...input,outputId:'https://derived.invalid/reference.json'}),document=await open(display.output.text,display.projection);
  try {
    await completeText(document.page);
    const operations=document.page.locator('.opblock');assert.equal(await operations.count(),2);
    for(const operation of await operations.all()){
      const path=await operation.locator('.opblock-summary-path').innerText(),owner=path.includes('/one/')?'one':'two',other=owner==='one'?'two':'one';
      const content=await operation.innerText();assert(content.includes(owner+' parameter owner'),'Wrong inherited source for '+path+' '+content);
      assert(!content.includes(other+' parameter owner'),'Another logical operation must not supply inherited parameters');
      assert.equal(await operation.locator('[data-busyapi-parameter-source]').count(),1);
    }
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
    assert.deepEqual(input.resources.map(resource=>resource.text),before);
  }finally{await document.context.close();}
});
if(moduleTree)test('browser-module owner unmounts the actual React root and can reopen without duplicate content',async()=>{
  const text=JSON.stringify({openapi:'3.2.1',info:{title:'Owned module root',version:'1'},paths:{'/owned':{get:{summary:'Owned operation',responses:{204:{description:'Bodyless'}}}}}}),
    root=origin+'/index.html',projection=referenceDocument({root,snapshot:'module-owner',resources:[{id:root,text,generation:1}]}),document=await open(text,projection);
  try{
    for(let pass=0;pass<3;pass++){
      await document.page.locator('.swagger-ui .info').waitFor();
      const title=document.page.locator('.swagger-ui .info .title');
      await title.waitFor();assert.equal(await title.count(),1);
      assert((await title.innerText()).includes('Owned module root'));
      await document.page.evaluate(()=>{busyapiReference.close();busyapiReference.close();});
      assert.equal(await document.page.locator('#reference').evaluate(element=>element.childElementCount),0);
      if(pass<2)await document.page.evaluate(async({text,projection})=>{
        busyapiReference=await BusyApiSwagger.mount(text,projection,document.getElementById('reference'),{
          labels:{source:'View source',sourceOwner:'View original owner',schemas:'Schemas',webhooks:'Webhooks',definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited',previousPage:'Previous page',nextPage:'Next page',page:(page,pages)=>`${page}/${pages}`},
          onError:code=>busyapiDocumentationFailures.push(code),
        });
        ui=busyapiReference.system;
      },{text,projection});
    }
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);
    assert.deepEqual(await document.page.evaluate(()=>busyapiDocumentationFailures),[]);
  }finally{await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`Swagger ${version} original-source controls use captured roles, not repeated names or payload paths`,async()=>{
  const operation={summary:'Repeated visible name',responses:{200:{description:'Value',content:{'application/json':{schema:false,example:{$ref:'literal 雪😀'}}}}}};
  const secondPointer=version.startsWith('3.2.')?'additionalOperations/COPY':'post';
  const text=JSON.stringify({openapi:version,info:{title:'Source controls',version:'1'},paths:{'/first':{get:operation},'/second':version.startsWith('3.2.')?{additionalOperations:{COPY:operation}}:{post:operation}}});
  const root=origin+'/index.html',projection=referenceDocument({root,snapshot:'source-controls',resources:[{id:root,text,generation:1}]}),sourceActions=[
    {index:0,pointer:'',role:'node',authored:false},
    {index:1,pointer:'/paths/~1first/get',role:'node',authored:true},
    {index:2,pointer:'/paths/~1second/'+secondPointer,role:'node',authored:true},
    {index:3,pointer:'/paths/~1first/get/responses/200/content/application~1json/example',role:'field',authored:true},
  ],document=await open(text,projection,undefined,sourceActions);
  try {
    await completeText(document.page);
    for(const index of [0,1,2,3]) {
      const button=document.page.locator(`[data-busyapi-source="${index}"]`).first();
      assert(await button.count()>0,'Missing source index '+index+' '+JSON.stringify(document.errors)+' '+JSON.stringify(await document.page.evaluate(()=>({errors:window.busyapiDocumentationFailures,detail:window.busyapiTestFailureDetails,buttons:[...document.querySelectorAll('[data-busyapi-source]')].map(button=>button.outerHTML.slice(0,200)),body:document.body.innerText.slice(0,2000)}))));
      await button.click();
    }
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiSourceRequests),[0,1,2,3]);
    assert.equal(await document.page.locator('[data-busyapi-source="0"]').first().getAttribute('aria-label'),'View original owner');
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
    assert.equal(await document.page.evaluate(()=>window.busyapiPresentation.canonicalText),text);
  }finally{await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`Swagger ${version} authored relationships and exact schema constraints remain visible`,async()=>{
  const source=authoredDocument(version),document=await open(source);
  try{
    const text=await completeText(document.page),diagnostic=JSON.stringify({errors:document.errors,denied:document.denied,body:text.slice(0,3500)});
    for(const sentinel of ['Authored operation sentinel','Webhook incoming sentinel','Callback received sentinel','Response header sentinel','literal example sentinel','Tree property sentinel','Composition sentinel','9007199254740993.00'])
      assert(text.includes(sentinel),'Missing authored '+sentinel+' '+diagnostic);
    if(version.startsWith('3.2.')){
      for(const sentinel of ['Additional authored operation sentinel','Sequential media sentinel','Serialized sequence sentinel','itemSchema',
        'Webhook QUERY inventory sentinel','Webhook COPY inventory sentinel','Callback QUERY inventory sentinel','Callback COPY inventory sentinel',
        'Callback content sentinel','literal nested callback payload','900719925474099312345678901.00'])assert(text.includes(sentinel),'Missing authored '+sentinel+' '+diagnostic);
      const pointer='/paths/~1authored/additionalOperations/COPY/responses/200/content/application~1json-seq/itemSchema';
      assert(await document.page.locator(`[data-busyapi-authored-content="${pointer}"]`).count()>0,'Sequential item schema must be displayed in its own media occurrence');
    }
    assert(!text.includes('9007199254740992'),'A rounded schema constraint is not the authored value');
    assert.equal(await document.page.evaluate(()=>busyapiPresentation.canonicalText),source);
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);assert.deepEqual(await document.page.evaluate(()=>busyapiDocumentationFailures),[]);
  }finally{await document.context.close();}
});
for(const family of ['31','32'])test(`read-only Swagger ${family}: real rich immutable content, source paths and no ordinary requests`, async () => {
  const root='https://contracts.invalid/root.json';
  const spec=await readFile(new URL(`../../fixtures/compatibility/oas${family}.json`, import.meta.url), 'utf8');
  const schema=await readFile(new URL('../../fixtures/compatibility/schema.json', import.meta.url), 'utf8');
  const resources=[{id:root,text:spec,generation:1},{id:'https://contracts.invalid/schema.json',text:schema,generation:1}];
  const frozen=resources.map(resource=>resource.text), bundle=deriveBundle({root,resources,snapshot:'swagger-rich-'+family,outputId:'https://derived.invalid/openapi.json'});
  const projection=referenceDocument({root:bundle.output.id,snapshot:'swagger-rich-'+family,resources:[{id:bundle.output.id,text:bundle.output.text,generation:1}]});
  const document=await open(bundle.output.text,projection);
  try {
    const text=await completeText(document.page);
    const diagnostic=await document.page.evaluate(()=>({failures:window.busyapiDocumentationFailures,details:window.busyapiTestFailureDetails,body:document.body.innerText.slice(0,5000)}));
    for(const sentinel of ['Compatibility operation sentinel','Schema property sentinel','payload data'])assert(text.includes(sentinel),'Missing '+sentinel+' '+JSON.stringify(diagnostic));
    if(family==='32')for(const sentinel of ['QUERY sentinel','COPY sentinel'])assert(text.includes(sentinel),'Missing '+sentinel);
    const selected=await document.page.evaluate(()=>{
      const system=ui.getSystem();
      return {schemas:system.specSelectors.selectSchemas(), operations:system.specSelectors.taggedOperations().toJS()};
    });
    assert.equal(selected.schemas.Boolean,true);
    const operations=Object.values(selected.operations).flatMap(tag=>tag.operations);
    if(family==='32')assert(operations.some(operation=>JSON.stringify(operation.specPath)===JSON.stringify(['paths','/things','additionalOperations','COPY'])));
    assert.equal(await document.page.getByRole('button',{name:/^(authorize|try it out|execute)$/i}).count(),0);
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[],JSON.stringify(await document.page.evaluate(()=>window.busyapiTestFailureDetails)));
    assert.deepEqual(await document.page.evaluate(()=>ui.getSystem().errSelectors.allErrors().toJS()),[]);
    assert.deepEqual(document.requests,ordinaryRequests);
    assert.equal(await document.page.evaluate(()=>window.busyapiPresentation.canonicalText),bundle.output.text);
    assert.deepEqual(resources.map(resource=>resource.text),frozen);
  } finally {await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`logical ${version} display identity is distinct from page transport and never grants retrieval`,async()=>{
  const value={openapi:version,info:{title:'Logical display',version:'1'},paths:{'/logical':{get:{responses:{200:{description:'Logical result',content:{'application/json':{schema:{$ref:'https://schemas.invalid/root#/$defs/Value'},example:{value:'exact'}}}}}}}},components:{schemas:{Root:{$id:'https://schemas.invalid/root',$defs:{Value:{type:'object',properties:{value:{type:'string',description:'Logical schema sentinel'}}}}}}}};
  const source=JSON.stringify(value),document=await open(source,undefined,'https://busyapi-display.invalid/captured/document.json');
  try {
    const text=await completeText(document.page);assert(text.includes('Logical schema sentinel'));
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[],JSON.stringify(await document.page.evaluate(()=>window.busyapiTestFailureDetails)));
    assert.deepEqual(await document.page.evaluate(()=>ui.getSystem().errSelectors.allErrors().toJS()),[]);
    assert.deepEqual(document.requests,ordinaryRequests);
    assert.equal(await document.page.evaluate(()=>busyapiPresentation.canonicalText),source);
  }finally{await document.context.close();}
});
for(const family of ['31','32'])test(`read-only Swagger ${family}: actual minimal operation, schema, example and version content`,async()=>{
  const source=await readFile(new URL(`../../fixtures/compatibility/oas${family}-minimal.json`,import.meta.url),'utf8');
  const document=await open(source);
  try {
    const text=await completeText(document.page);
    for(const sentinel of ['Compatibility operation sentinel','Schema property sentinel','fixture'])assert(text.includes(sentinel),'Missing '+sentinel);
    if(family==='32')for(const sentinel of ['QUERY sentinel','COPY sentinel'])assert(text.includes(sentinel),'Missing '+sentinel);
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
    assert.deepEqual(await document.page.evaluate(()=>ui.getSystem().errSelectors.allErrors().toJS()),[]);
  } finally {await document.context.close();}
});

test('fixed and additional same-name methods have distinct identities, correct tag groups and stable refreshes', async () => {
  const operation=(operationId,summary)=>({operationId,summary,tags:['A','B'],responses:{204:{description:'Bodyless'}}});
  const value={openapi:'3.2.1',info:{title:'Repeated names',version:'1'},paths:{'/same':{get:operation('standard','standard sentinel'),additionalOperations:{get:operation('custom','lowercase sentinel'),COPY:operation('copy','copy sentinel')}}},components:{schemas:{False:false,True:true}}};
  const document=await open(JSON.stringify(value));
  try {
    const verify=async()=>{
      const groups=await document.page.evaluate(()=>ui.getSystem().specSelectors.taggedOperations().toJS());
      for(const name of ['A','B']) {
        assert.equal(groups[name].operations.length,3);
        assert.equal(new Set(groups[name].operations.map(operation=>JSON.stringify(operation.specPath))).size,3);
        const custom=groups[name].operations.find(operation=>operation.method===additionalMethodIdentity('get'));
        assert.equal(custom.operation.operationId,'custom');assert.deepEqual(custom.specPath,['paths','/same','additionalOperations','get']);
      }
      const meta=await document.page.evaluate(identity=>({
        fixed:ui.getSystem().specSelectors.operationWithMeta('/same','get').get('operationId'),
        custom:ui.getSystem().specSelectors.operationWithMeta('/same',identity).get('operationId'),
        boolean:ui.getSystem().specSelectors.selectSchemas().False,
        fixedData:ui.getSystem().specSelectors.operationWithMeta('/same','get').toJS(),
        customData:ui.getSystem().specSelectors.operationWithMeta('/same',identity)?.toJS(),
        actual:ui.getSystem().specSelectors.specJsonWithResolvedSubtrees().getIn(['paths','/same','get'])?.toJS(),
      }),additionalMethodIdentity('get'));
      assert.equal(meta.fixed,'standard',JSON.stringify(meta));assert.equal(meta.custom,'custom',JSON.stringify(meta));assert.equal(meta.boolean,false);
    };
    await verify();
    for(let index=0;index<3;index++) {
      await document.page.evaluate(value=>ui.getSystem().specActions.updateJsonSpec(value),value);
      await document.page.waitForTimeout(50);await verify();
    }
    await document.page.locator('[data-busyapi-additional-method="get"]').first().waitFor();
    assert.equal(await document.page.locator('[data-busyapi-additional-method="get"]').first().innerText(),'get');
    await completeText(document.page);
    for(const boolean of ['false','true']) {
      const authored=document.page.locator('[data-busyapi-boolean-schema="'+boolean+'"]').first();
      await authored.waitFor();assert.equal(await authored.innerText(),boolean);
    }
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[],JSON.stringify(await document.page.evaluate(()=>window.busyapiTestFailureDetails)));
    assert.deepEqual(await document.page.evaluate(()=>ui.getSystem().errSelectors.allErrors().toJS()),[]);
  } finally {await document.context.close();}
});

test('description HTML/images stay text and action dispatch cannot authorize or execute a request', async () => {
  const value={openapi:'3.2.1',info:{title:'Untrusted descriptions',version:'1',description:'![remote](https://must-not-load.invalid/image) <img src="https://must-not-load.invalid/html" onerror="window.executed=true">'},
    servers:[{url:'https://must-not-call.invalid'}],security:[{Key:[]}],components:{securitySchemes:{Key:{type:'apiKey',in:'header',name:'X-Key'}}},paths:{'/x':{get:{responses:{204:{description:'None'}}}}}};
  const document=await open(JSON.stringify(value));
  try {
    const actions=await document.page.evaluate(()=>{
      const codes=[];
      for(const action of [()=>ui.getSystem().specActions.execute({pathName:'/x',method:'get'}),()=>ui.getSystem().authActions.authorize({Key:{value:'synthetic-not-secret'}})]) {
        codes.push(action());
      }
      return {codes,executed:window.executed,authorized:ui.getSystem().authSelectors.authorized().size,failures:window.busyapiDocumentationFailures};
    });
    assert.deepEqual(actions.codes,[null,null],JSON.stringify(actions));
    assert.deepEqual(actions.failures,['busyapi.documentation.read-only','busyapi.documentation.read-only'],JSON.stringify(actions));
    assert.equal(actions.executed,undefined);assert.equal(actions.authorized,0);
    assert.equal(await document.page.locator('#reference img,#reference script,#reference iframe').count(),0);
    assert.equal(await document.page.getByRole('button',{name:/^(authorize|try it out|execute)$/i}).count(),0);
    assert((await document.page.locator('body').innerText()).includes('must-not-load.invalid'));
    await document.page.waitForTimeout(100);
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
  } finally {await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`authored ${version} samples keep exact numbers, named/definition ownership and null/false/zero/empty values`,async()=>{
  const examples={Large:{value:{integer:111,decimal:222,$ref:'literal payload',text:'雪😀'}},False:{value:false},Zero:{value:0},Null:{value:null},Empty:{value:''},Shared:{$ref:'#/components/examples/Stored'}};
  if(version.startsWith('3.2')){examples.Data={dataValue:{integer:111}};examples.Serialized={serializedValue:'雪😀\n9007199254740993.00\n'};}
  const value={openapi:version,info:{title:'Exact examples',version:'1'},paths:{'/exact':{get:{responses:{200:{description:'Examples',content:{'application/json':{schema:{},examples}}}}}}},components:{examples:{Stored:{value:{shared:111}}}}};
  const source=JSON.stringify(value).replaceAll('111','9007199254740993.00').replaceAll('222','1.00000000000000000001');
  const document=await open(source);
  try {
    await document.page.getByRole('tab',{name:'Example Value',exact:true}).click();
    const select=document.page.getByRole('combobox').filter({has:document.page.getByRole('option',{name:'Large',exact:true})});
    const expected={Large:'{"integer":9007199254740993.00,"decimal":1.00000000000000000001,"$ref":"literal payload","text":"雪😀"}',False:'false',Zero:'0',Null:'null',Empty:'""',Shared:'{"shared":9007199254740993.00}'};
    if(version.startsWith('3.2')){expected.Data='{"integer":9007199254740993.00}';expected.Serialized='雪😀\n9007199254740993.00\n';}
    for(const [name,text]of Object.entries(expected)) {
      await select.selectOption(name);
      await document.page.waitForFunction(text=>document.querySelector('[data-busyapi-authored-value]')?.textContent===text,text,{timeout:4000});
      const actual=document.page.locator('[data-busyapi-authored-value]');
      assert.equal(await actual.count(),1);assert.equal(await actual.textContent(),text);
      const pointer=await actual.getAttribute('data-busyapi-authored-value');
      assert.equal(pointer,name==='Shared'?'/components/examples/Stored/value':'/paths/~1exact/get/responses/200/content/application~1json/examples/'+name+'/'+(name==='Data'?'dataValue':name==='Serialized'?'serializedValue':'value'));
    }
    assert.equal(await document.page.evaluate(()=>window.busyapiPresentation.canonicalText),source);
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[],JSON.stringify(await document.page.evaluate(()=>window.busyapiTestFailureDetails)));
    assert.deepEqual(await document.page.evaluate(()=>ui.getSystem().errSelectors.allErrors().toJS()),[]);
  } finally {await document.context.close();}
});
test('large authored examples expose every Unicode-safe page without a generated or truncated replacement',async()=>{
  const long='a'.repeat(8189)+'雪😀'+('text\n'.repeat(4000));
  const media={schema:{type:'string'},examples:{Long:{serializedValue:long}}};
  const response={description:'Long',content:{'text/plain':media}};
  const value={openapi:'3.2.1',info:{title:'Paged examples',version:'1'},paths:{'/long':{get:{responses:{200:response}}}}};
  const source=JSON.stringify(value),document=await open(source);
  try {
    await document.page.getByRole('tab',{name:'Example Value',exact:true}).click();
    const actual=document.page.locator('[data-busyapi-authored-value]');await actual.waitFor();
    let captured='';
    const next=document.page.getByRole('button',{name:'Next page',exact:true});
    for(let page=0;page<10;page++) {
      const chunk=await actual.textContent();assert(chunk.length<=8193);
      assert(!/^[\uDC00-\uDFFF]/u.test(chunk));assert(!/[\uD800-\uDBFF]$/u.test(chunk));captured+=chunk;
      if(await next.isDisabled())break;
      await next.click();
    }
    assert.equal(captured,long);assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
  } finally {await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`request media ${version} preserves exact numeric and JSON-string examples through real schema/example tabs`,async()=>{
  const text=JSON.stringify({openapi:version,info:{title:'Request media ownership',version:'1'},paths:{'/request':{post:{
    requestBody:{content:{'application/json':{schema:{type:'integer'},example:'EXACT'},'text/plain':{schema:{type:'string'},example:'serialized 雪😀'}}},
    responses:{204:{description:'Bodyless'}}}}}}).replace('"EXACT"','9007199254740993.0'),document=await open(text);
  try{
    const media=document.page.locator('select').filter({has:document.page.locator('option[value="text/plain"]')});
    await media.waitFor();
    assert.equal(await media.count(),1);
    for(const [name,expected]of [['application/json','9007199254740993.0'],['text/plain','"serialized 雪😀"']]){
      await media.selectOption(name);
      const tab=document.page.getByRole('tab',{name:'Example Value',exact:true});await tab.click();
      const pointer='/paths/~1request/post/requestBody/content/'+name.replace('/','~1')+'/example';
      await document.page.waitForFunction(({pointer,expected})=>[...document.querySelectorAll('[data-busyapi-authored-value]')].some(node=>node.getAttribute('data-busyapi-authored-value')===pointer&&node.textContent===expected),{pointer,expected});
      assert.equal(await document.page.locator('[data-busyapi-authored-value]').textContent(),expected);
    }
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);
    assert.deepEqual(await document.page.evaluate(()=>busyapiDocumentationFailures),[]);
  }finally{await document.context.close();}
});
test('media switching retains absent schemas, inline booleans and authored null without inventing a body or sample',async()=>{
  const content={
    'application/json':{examples:{Null:{value:null}}},
    'application/false+json':{schema:false,example:false},
    'application/true+json':{schema:true,example:0},
    'text/plain':{examples:{Text:{serializedValue:'Plain 雪😀\n'}}},
  };
  const value={openapi:'3.2.1',info:{title:'Media ownership',version:'1'},paths:{'/media':{get:{responses:{200:{description:'Content',content},204:{description:'Bodyless'}}}}}};
  const source=JSON.stringify(value),document=await open(source);
  try {
    const media=document.page.getByRole('combobox',{name:'Media Type',exact:true});
    for(const [name,text]of [['application/json','null'],['application/false+json','false'],['application/true+json','0'],['text/plain','Plain 雪😀\n']]) {
      await media.selectOption(name);
      await document.page.waitForFunction(text=>document.querySelector('[data-busyapi-authored-value]')?.textContent===text,text,{timeout:4000});
      assert.equal(await document.page.locator('[data-busyapi-authored-value]').count(),1);
      if(name.includes('false')||name.includes('true')) {
        const boolean=name.includes('false')?'false':'true';
        assert.equal(await document.page.locator('[data-busyapi-schema-source]').innerText(),'schema: '+boolean);
      }else assert.equal(await document.page.locator('[data-busyapi-schema-source]').count(),0);
    }
    assert.equal(await document.page.evaluate(()=>window.busyapiPresentation.canonicalText),source);
    assert.equal(await document.page.evaluate(()=>ui.getSystem().fn.getSampleSchema({type:'string',format:'password'})),undefined);
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[],JSON.stringify(await document.page.evaluate(()=>window.busyapiTestFailureDetails)));
    assert.deepEqual(await document.page.evaluate(()=>ui.getSystem().errSelectors.allErrors().toJS()),[]);
  } finally {await document.context.close();}
});
