// Development browser qualification only. No Playwright/browser/probe packages
// are installed as BusyAPI or documentation-export assets by these tests.
import assert from 'node:assert/strict';
import {before,after,test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {redocAdapterIdentity} from './redoc_adapter.mjs';
import {authoredDocument} from './test_fixtures/authored_document.mjs';
const probe=createRequire(new URL('../probes/m2/package.json',import.meta.url));
const engine=createRequire(new URL('../contract_engine/package.json',import.meta.url));
const {chromium}=probe('playwright'),{build}=engine('esbuild'),{deriveBundle}=engine('./dist/derived_bundle.cjs'),{referenceDisplay}=engine('./dist/reference_display.cjs'),{referenceDocument}=engine('./dist/reference_projection.cjs');
const {pathContexts}=engine('../../fixtures/compatibility/reference_display.cjs');
const metadata=probe('redoc/package.json');assert.equal(metadata.version,redocAdapterIdentity.packageVersion);assert.equal(metadata.license,'MIT');
const origin='http://busyapi-redoc-test.invalid';let browser,bundle;
before(async()=>{
  // Additional exports are test-only diagnostics of generated fixtures. No
  // vendor bundle is edited and no project data is logged by the application.
  bundle=(await build({stdin:{contents:"export * from './redoc_entry.mjs'; export {prepareApiDocs} from 'redoc'; export {default as React} from 'react'; export {graphAddressedDisplay} from './graph_display.mjs'; export {redocAuthoredContent} from './redoc_content.mjs';",resolveDir:fileURLToPath(new URL('./',import.meta.url))},nodePaths:[fileURLToPath(new URL('../probes/m2/node_modules',import.meta.url))],bundle:true,write:false,format:'esm',platform:'browser',define:{'process.env.NODE_ENV':'"production"'},logLevel:'silent'})).outputFiles[0].text;
  browser=await chromium.launch({headless:true,chromiumSandbox:true,...(process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE?{executablePath:process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE}:{})});
});
after(async()=>{await browser?.close();});
async function open(text,projection,sourceActions) {
  projection??=referenceDocument({root:origin+'/index.html',snapshot:'redoc-inline',resources:[{id:origin+'/index.html',text,generation:1}]});
  const context=await browser.newContext({serviceWorkers:'block'}),page=await context.newPage(),requests=[],denied=[],errors=[];
  page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});page.on('popup',()=>errors.push('Unexpected popup'));
  await context.route('**/*',route=>{
    const url=route.request().url();requests.push(url);
    if(url===origin+'/index.html')return route.fulfill({contentType:'text/html',headers:{'Content-Security-Policy':"default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'"},body:'<!doctype html><html><head></head><body><div id="reference"></div></body></html>'});
    if(url===origin+'/redoc_entry.mjs')return route.fulfill({contentType:'text/javascript',body:bundle});
    denied.push(url);return route.abort('blockedbyclient');
  });
  await page.goto(origin+'/index.html');
  try{await page.evaluate(async({text,projection,sourceActions})=>{
    const {mount}=await import('/redoc_entry.mjs');window.busyapiDocumentationFailures=[];window.busyapiSourceRequests=[];
    window.reference=await mount(text,projection,document.getElementById('reference'),{...(sourceActions?{sourceActions,onSource:index=>window.busyapiSourceRequests.push(index)}:{}),labels:{source:'View source',sourceOwner:'View original owner',schemas:'Schemas',previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages,definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited'},onError:code=>window.busyapiDocumentationFailures.push(code)});
  },{text,projection,sourceActions});}catch(error){
    const diagnostic=await page.evaluate(async({text,projection})=>{
      const {prepareApiDocs,React,graphAddressedDisplay,redocAuthoredContent}=await import('/redoc_entry.mjs');
      let phase='graph',prepared;
      try{
        const presentation=graphAddressedDisplay(text,projection,location.href,{addresses:'document-pointer'});
        phase='preparation';prepared=await prepareApiDocs({spec:structuredClone(presentation.spec),convertedDownload:false,basePath:'/',options:{skipBundle:true,disableTelemetry:true,sanitize:true,hideDownloadButtons:true,layout:'stacked',schemaDefinitionsTagName:'Schemas'}});
        phase='content';redocAuthoredContent(React,presentation,prepared.items,{previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages,definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited'});
        return {phase:'completed'};
      }catch(error){return {phase,error:error.message,items:prepared?.items};}
    },{text,projection});
    console.error('Generated Redoc fixture failure',JSON.stringify(diagnostic).slice(0,10000));await context.close();throw error;
  }
  await page.locator('#reference h1').first().waitFor();
  return {context,page,requests,denied,errors};
}
async function selectPage(document,slug) {
  await document.page.evaluate(slug=>{window.location.hash='#/'+slug.replace(/^\//,'');},slug);
  if(slug)try{await document.page.waitForFunction(path=>[...window.document.querySelectorAll('[data-section-id]')].some(node=>node.getAttribute('data-section-id')===path&&node.textContent.trim()),'/'+slug.replace(/^\//,''));}
  catch(error){console.error('Mounted route failure',JSON.stringify({slug,errors:document.errors,denied:document.denied,state:await document.page.evaluate(()=>({failures:busyapiDocumentationFailures,sections:[...window.document.querySelectorAll('[data-section-id]')].map(node=>node.getAttribute('data-section-id')),body:window.document.body.innerText.slice(0,2500)}))}));throw error;}
}
async function visit(document) {
  const slugs=await document.page.evaluate(()=>{
    const paths=new Set(['']);function visit(items){for(const item of items){if(item.routeSlug&&item.content)paths.add(item.routeSlug);visit(item.items??[]);}}visit(reference.items);return [...paths];
  }),seen=new Set();
  document.booleans=new Set();
  for(const slug of slugs){
    await selectPage(document,slug);
    // Exercise the actual lazy controls, not hidden text or a loaded banner.
    // Each definition is opened once, never recursively expanding a cycle.
    const definitions=new Set();
    let steps=0;
    for(;steps<128;steps++){
      await document.page.waitForFunction(()=>{
        const branches=[...window.document.querySelectorAll('[data-busyapi-authored-branch]')];
        for(const branch of branches)if(!branch.open)branch.open=true;
        return branches.every(branch=>[...branch.querySelectorAll('[data-busyapi-authored-content]')].some(section=>section.getAttribute('data-busyapi-authored-content')===branch.getAttribute('data-busyapi-authored-branch')));
      });
      seen.add(await document.page.locator('body').innerText());
      for(const value of await document.page.locator('[data-busyapi-boolean-schema]').evaluateAll(nodes=>nodes.map(node=>node.getAttribute('data-busyapi-boolean-schema'))))document.booleans.add(value);
      const opened=await document.page.evaluate(visited=>{
        for(const button of document.querySelectorAll('[data-busyapi-definition]')) {
          const target=button.getAttribute('data-busyapi-definition');
          if(button.isConnected&&button.getClientRects().length&&getComputedStyle(button).visibility!=='hidden'&&!visited.includes(target)){
            window.busyapiWalkWait={panel:button.closest('[data-busyapi-authored-panel]'),target};button.click();return target;
          }
        }
      },[...definitions]);
      if(opened)definitions.add(opened);
      seen.add(await document.page.locator('body').innerText());
      await document.page.evaluate(()=>{for(const node of [document.scrollingElement,...document.querySelectorAll('.api-content,[data-scroll-container]')])if(node)node.scrollTop+=500;});
      if(opened){
        await document.page.waitForFunction(()=>{
          const {panel,target}=busyapiWalkWait;
          return panel?.isConnected&&panel.querySelector(':scope > [data-busyapi-authored-content]')?.getAttribute('data-busyapi-authored-content')===target;
        });
        continue;
      }
      // Reading a definition changes only its owning content panel. Return to
      // that panel's root to inspect sibling examples/media, rather than
      // mistaking a one-way schema walk for complete page-content inspection.
      const returned=await document.page.evaluate(()=>{
        const button=[...document.querySelectorAll('button')].find(node=>node.getClientRects().length&&getComputedStyle(node).visibility!=='hidden'&&node.textContent.startsWith('← '));
        if(!button)return false;const panel=button.closest('[data-busyapi-authored-panel]');
        window.busyapiWalkWait={panel,target:panel?.getAttribute('data-busyapi-authored-panel')};button.click();return true;
      });
      if(!returned)break;
      await document.page.waitForFunction(()=>{
        const {panel,target}=busyapiWalkWait;
        return panel?.isConnected&&panel.querySelector(':scope > [data-busyapi-authored-content]')?.getAttribute('data-busyapi-authored-content')===target;
      });
    }
    assert(steps<128,'The authored definition walk exceeded its bounded complete-review budget');
  }
  return [...seen].join('\n');
}
for(const version of ['3.1.2','3.2.1'])test(`Redoc ${version} authored relationships and exact schema constraints remain visible`,async()=>{
  const source=authoredDocument(version),document=await open(source);
  try{
    const text=await visit(document),diagnostic=JSON.stringify({errors:document.errors,denied:document.denied,body:text.slice(0,3500)});
    for(const sentinel of ['Authored operation sentinel','Webhook incoming sentinel','Callback received sentinel','Response header sentinel','literal example sentinel','Tree property sentinel','Composition sentinel','9007199254740993.00'])
      assert(text.includes(sentinel),'Missing authored '+sentinel+' '+diagnostic);
    if(version.startsWith('3.2.'))for(const sentinel of ['Additional authored operation sentinel','Sequential media sentinel','Serialized sequence sentinel',
      'Webhook QUERY inventory sentinel','Webhook COPY inventory sentinel','Callback QUERY inventory sentinel','Callback COPY inventory sentinel',
      'Callback content sentinel','literal nested callback payload','900719925474099312345678901.00'])assert(text.includes(sentinel),'Missing authored '+sentinel+' '+diagnostic);
    assert(!text.includes('9007199254740992'),'A rounded schema constraint is not the authored value');
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);assert.deepEqual(await document.page.evaluate(()=>busyapiDocumentationFailures),[]);
  }finally{await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`Redoc ${version} source controls preserve repeated-operation and exact schema/example ownership`,async()=>{
  const operation={summary:'Repeated visible name',responses:{200:{description:'Value',content:{'application/json':{schema:{$ref:'#/components/schemas/Boolean'},example:{$ref:'literal 雪😀'}}}}}};
  const second=version.startsWith('3.2.')?'additionalOperations/COPY':'post';
  const text=JSON.stringify({openapi:version,info:{title:'Source controls',version:'1'},paths:{'/first':{get:operation},'/second':version.startsWith('3.2.')?{additionalOperations:{COPY:operation}}:{post:operation}},components:{schemas:{Boolean:false}}});
  const root=origin+'/index.html',projection=referenceDocument({root,snapshot:'source-controls',resources:[{id:root,text,generation:1}]}),sourceActions=[
    {index:0,pointer:'/paths/~1first/get',role:'node',authored:true},
    {index:1,pointer:'/paths/~1second/'+second,role:'node',authored:true},
    {index:2,pointer:'/components/schemas/Boolean',role:'node',authored:false},
    {index:3,pointer:'/paths/~1first/get/responses/200/content/application~1json/example',role:'field',authored:true},
  ],document=await open(text,projection,sourceActions);
  try {
    const slugs=await document.page.evaluate(()=>{const values=new Set(['']);function visit(items){for(const item of items){if(item.routeSlug&&item.content)values.add(item.routeSlug);visit(item.items??[]);}}visit(reference.items);return [...values];}),clicked=new Set();
    for(const slug of slugs) {
      await selectPage(document,slug);
      for(let attempt=0;attempt<10;attempt++) {
        await document.page.evaluate(()=>{for(const branch of document.querySelectorAll('[data-busyapi-authored-branch]'))branch.open=true;});
        await document.page.waitForTimeout(40);
        for(const index of [0,1,2,3])if(!clicked.has(index)&&await document.page.locator(`[data-busyapi-source="${index}"]`).count()) {
          await document.page.locator(`[data-busyapi-source="${index}"]`).first().click();clicked.add(index);
          if(index===2)assert.equal(await document.page.locator('[data-busyapi-source="2"]').first().getAttribute('aria-label'),'View original owner');
        }
      }
    }
    assert.deepEqual([...clicked].sort(),[0,1,2,3]);
    assert.deepEqual((await document.page.evaluate(()=>window.busyapiSourceRequests)).sort(),[0,1,2,3]);
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
  }finally{await document.context.close();}
});
for(const representation of ['single-file','graph-display'])for(const family of ['31','32'])test(`Redoc CE ${family} rich immutable ${representation}: actual operations, external schema and literal examples with no ordinary resource attempts`,async()=>{
  const root='https://contracts.invalid/root.json',source=await readFile(new URL(`../../fixtures/compatibility/oas${family}.json`,import.meta.url),'utf8'),schema=await readFile(new URL('../../fixtures/compatibility/schema.json',import.meta.url),'utf8');
  const resources=[{id:root,text:source,generation:1},{id:'https://contracts.invalid/schema.json',text:schema,generation:1}],frozen=resources.map(resource=>resource.text);
  const derived=(representation==='single-file'?deriveBundle:referenceDisplay)({root,resources,snapshot:'redoc-rich-'+family,outputId:'https://derived.invalid/openapi.json'});
  const projection=representation==='graph-display'?derived.projection:referenceDocument({root:derived.output.id,snapshot:'redoc-rich-'+family,resources:[{id:derived.output.id,text:derived.output.text,generation:1}]}),document=await open(derived.output.text,projection);
  try {
    const text=await visit(document),diagnostic=JSON.stringify({errors:document.errors,denied:document.denied,body:text.slice(0,6000)});
    for(const sentinel of ['Compatibility operation sentinel','Schema property sentinel','payload data',...(family==='32'?['QUERY sentinel','COPY sentinel']:[])])assert(text.includes(sentinel),'Missing '+sentinel+' '+diagnostic);
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
    assert.deepEqual(document.requests,[origin+'/index.html',origin+'/redoc_entry.mjs']);
    assert.deepEqual(resources.map(resource=>resource.text),frozen);
    assert.equal(await document.page.getByRole('button',{name:/^(authorize|try it out|execute|open in .+|ask ai)$/i}).count(),0);
  }finally{await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`Redoc ${version} shared Operation keeps both logical routes and their distinct inherited parameter owners`,async()=>{
 const input=pathContexts(version),captured=referenceDisplay({...input,outputId:'https://derived.invalid/reference.json'}),document=await open(captured.output.text,captured.projection);
 try {
  const operations=await document.page.evaluate(()=>{const found=[];function visit(items){for(const item of items){if(item.content?.itemVariant==='httpItem')found.push({path:item.httpPath,method:item.httpVerb,route:item.routeSlug,link:item.link,meta:item.content.meta});visit(item.items??[]);}}visit(reference.items);return found.filter(item=>['/one/{id}','/two/{id}'].includes(item.path));});
  const routes=new Map();
  for(const item of operations){const previous=routes.get(item.path);assert(!previous||previous===item.route,'One logical operation must not have conflicting routes');routes.set(item.path,item.route);}
  assert.equal(routes.size,2);assert.equal(new Set(routes.values()).size,2,'Shared physical operationId is not a unique logical route identity '+JSON.stringify(operations));
  for(const [path,route]of routes){
   await selectPage(document,route);
   const owner=path.includes('/one/')?'one':'two',other=owner==='one'?'two':'one';
   const content=await visitCurrentContext(document,route);
   assert(content.includes(owner+' parameter owner'),'Missing inherited source for '+path+' '+content);
   assert(!content.includes(other+' parameter owner'),'Another logical path must not supply this operation\'s parameters');
  }
  assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);
 }finally{await document.context.close();}
});
async function visitCurrentContext(document,route) {
 return document.page.locator('[data-section-id]').evaluateAll((nodes,id)=>{
  const root=nodes.find(node=>node.getAttribute('data-section-id')===id&&node.getClientRects().length);
  if(!root)throw Error('The selected logical operation section is absent');
  return root.innerText;
 },'/'+route.replace(/^\//,''));
}
for(const version of ['3.1.2','3.2.1'])test(`Redoc ${version} shared Path Item routes keep exact definition/source ownership`,async()=>{
  const modern=version.startsWith('3.2'),method=modern?'COPY':'get',owner='/components/pathItems/Shared/'+(modern?'additionalOperations/':'')+method;
  const operation={summary:'Shared Path Item operation sentinel',responses:{200:{description:'Shared response sentinel',content:{'application/json':{schema:false,example:{$ref:'literal shared payload',number:111}}}}}};
  const source=JSON.stringify({openapi:version,info:{title:'Shared Path Items',version:'1'},paths:{'/first':{$ref:'#/components/pathItems/Alias'},'/second':{$ref:'#/components/pathItems/Alias'}},components:{pathItems:{Alias:{$ref:'#/components/pathItems/Shared'},Shared:modern?{additionalOperations:{COPY:operation}}:{get:operation}}}}).replace('111','9007199254740993.00');
  const text=source,root=origin+'/index.html',projection=referenceDocument({root,snapshot:'shared-path-items',resources:[{id:root,text,generation:1}]}),document=await open(text,projection,[{index:0,pointer:owner,role:'node',authored:true}]);
  try {
    const visible=await visit(document);
    for(const value of ['Shared Path Item operation sentinel','Shared response sentinel','literal shared payload','9007199254740993.00'])assert(visible.includes(value),'Missing shared definition content: '+value);
    const pages=await document.page.evaluate(()=>{const values=[];function walk(items){for(const item of items){if(item.httpPath&&item.routeSlug&&item.content?.itemVariant==='httpItem')values.push({path:item.httpPath,method:item.httpVerb,slug:item.routeSlug});walk(item.items??[]);}}walk(reference.items);return values;});
    assert.deepEqual([...new Set(pages.map(page=>JSON.stringify([page.path,page.method])))].sort(),[JSON.stringify(['/first',method]),JSON.stringify(['/second',method])].sort(),'Exactly the two logical route identities must survive, independent of tag/path display grouping');
    const routes=new Map();
    for(const page of pages){const previous=routes.get(page.slug);if(previous)assert.deepEqual(page,previous);routes.set(page.slug,page);}
    for(const {slug} of routes.values()){
      await selectPage(document,slug);
      const button=document.page.locator('[data-busyapi-source="0"]');
      assert(await button.count(),'Every actual HTTP page must expose its captured definition owner');
      await button.first().click();
    }
    assert.deepEqual(await document.page.evaluate(()=>busyapiSourceRequests),Array(routes.size).fill(0),'Every displayed route alias must request the same proved physical source, never a similarly named occurrence');
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);assert.deepEqual(await document.page.evaluate(()=>busyapiDocumentationFailures),[]);
  }finally{await document.context.close();}
});
test('Redoc description HTML, remote logos, externalValue and authored code samples do not grant loading/execution',async()=>{
  const value={openapi:'3.2.1',info:{title:'Local privacy',version:'1','x-logo':{url:'https://must-not-load.invalid/logo'},description:'<img src="https://must-not-load.invalid/html" onerror="window.executed=true"> ![image](https://must-not-load.invalid/image)'},servers:[{url:'https://must-not-call.invalid'}],paths:{'/x':{get:{summary:'Untrusted display',responses:{200:{description:'Body',content:{'application/json':{examples:{Remote:{externalValue:'https://must-not-load.invalid/value'}}}}}},'x-codeSamples':[{lang:'JavaScript',source:'fetch("https://must-not-call.invalid")'}]}}}};
  const source=JSON.stringify(value),document=await open(source);
  try {
    const text=await visit(document);assert(text.includes('Untrusted display'));assert(text.includes('must-not-load.invalid/html'),JSON.stringify({text,items:await document.page.evaluate(()=>reference.items)}));
    assert.equal(await document.page.evaluate(()=>window.executed),undefined);assert.equal(await document.page.locator('#reference img,#reference script,#reference iframe').count(),0);
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
    assert.equal(await document.page.getByRole('button',{name:/^(authorize|try it out|execute|open in .+|ask ai)$/i}).count(),0);
    await document.page.evaluate(()=>reference.close());assert.equal(await document.page.locator('#reference *').count(),0);
  }finally{await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`Redoc ${version} retains boolean schema definitions and exact authored examples/constraints`,async()=>{
  const value={openapi:version,info:{title:'Exact schema display',version:'1'},paths:{'/value':{get:{responses:{200:{description:'Exact response',content:{'application/json':{schema:{$ref:'#/components/schemas/Precise'},example:{integer:111,decimal:222}}}}}}}},components:{schemas:{
    Allowed:true,Forbidden:false,Precise:{type:'object',properties:{integer:{type:'integer',minimum:111},decimal:{type:'number',const:222}},examples:[{integer:111,decimal:222}]},
  }}};
  const source=JSON.stringify(value).replaceAll('111','9007199254740993').replaceAll('222','1.00000000000000000001'),document=await open(source);
  try {
    const text=await visit(document),diagnostic=JSON.stringify({text,errors:document.errors,denied:document.denied});
    for(const sentinel of ['Allowed','Forbidden','true','false','9007199254740993','1.00000000000000000001'])assert(text.includes(sentinel),'Missing exact authored '+sentinel+' '+diagnostic);
    assert.deepEqual([...document.booleans].sort(),['false','true']);
    assert(!text.includes('9007199254740992'),'Rounded authored integer must not be displayed');
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
  }finally{await document.context.close();}
});
test('Redoc authored schema/property and long-value pages reach the final Unicode/precise content without laying out every field',async()=>{
  const properties=Object.fromEntries(Array.from({length:60},(_,index)=>['p'+String(index).padStart(2,'0'),{type:'integer',minimum:111}]));
  const example='雪😀'.repeat(6000)+'FINAL-雪😀';
  const source=JSON.stringify({openapi:'3.2.1',info:{title:'Lazy exact content',version:'1'},paths:{},components:{schemas:{Many:{type:'object',properties,examples:[example]}}}}).replaceAll('111','9007199254740993');
  const document=await open(source);
  try {
    await document.page.evaluate(()=>{location.hash='#/schemas/many';});
    const branch=document.page.locator('[data-busyapi-authored-branch="/components/schemas/Many/properties"]');
    await branch.waitFor();await branch.locator(':scope > summary').click();
    const fields=document.page.locator('[data-busyapi-authored-content="/components/schemas/Many/properties"]');
    await fields.waitFor();
    assert.equal(await fields.locator('[data-busyapi-authored-branch]').count(),25);
    assert.equal(await fields.locator('[data-busyapi-authored-branch$="/p59"]').count(),0);
    const next=fields.locator(':scope > nav button[aria-label="Next"]');
    await next.click();await next.click();
    assert.equal(await fields.locator('[data-busyapi-authored-branch]').count(),10);
    const last=fields.locator('[data-busyapi-authored-branch$="/p59"]');await last.locator(':scope > summary').click();
    await last.locator('[data-busyapi-authored-value$="/minimum"]').waitFor();
    assert((await last.innerText()).includes('9007199254740993'));
    const code=document.page.locator('[data-busyapi-authored-value="/components/schemas/Many/examples"]'),chunks=[];
    const value=code.locator('..').locator('..'),advance=value.locator(':scope > nav button[aria-label="Next"]');
    while(true){chunks.push(await code.textContent());if(!await advance.isEnabled())break;await advance.click();assert(chunks.length<20);}
    assert.equal(chunks.join(''),JSON.stringify([example]));
    assert.equal(await document.page.locator('[data-busyapi-authored-content]').count(),3);
    assert.deepEqual(document.denied,[]);assert.deepEqual(document.errors,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
    await document.page.evaluate(()=>reference.close());assert.equal(await document.page.locator('#reference *').count(),0);
  }finally{await document.context.close();}
});
for(const version of ['3.1.2','3.2.1'])test(`Redoc ${version} request media and effective parameter declarations keep exact values and inheritance`,async()=>{
  const spec={openapi:version,info:{title:'Exact request declarations',version:'1'},paths:{'/value/{id}':{
    parameters:[{name:'id',in:'path',required:true,schema:{type:'integer',minimum:111}},{name:'q',in:'query',schema:{type:'integer',minimum:444}}],
    post:{parameters:[{name:'q',in:'query',schema:{type:'integer',maximum:222}},{name:'X-Demo',in:'header',schema:{type:'number',const:333}}],
      requestBody:{description:'Request media sentinel',content:{'application/json':{schema:{type:'integer',minimum:111},example:111},'text/plain':{schema:false,example:'serialized 雪😀\n'}}},
      responses:{204:{description:'Bodyless'}},'x-codeSamples':[{lang:'Example',source:'Authored code sample sentinel'}],
    },
  }}};
  const source=JSON.stringify(spec).replaceAll('111','9007199254740993').replaceAll('222','9007199254740995').replaceAll('333','1.00000000000000000001').replaceAll('444','9007199254740999'),document=await open(source);
  try {
    const text=await visit(document);
    for(const sentinel of ['Request media sentinel','application/json','text/plain','serialized 雪😀','9007199254740993','9007199254740995','1.00000000000000000001','Authored code sample sentinel','Inherited'])assert(text.includes(sentinel),'Missing '+sentinel+' '+text);
    for(const rounded of ['9007199254740992','9007199254740996','9007199254741000'])assert(!text.includes(rounded),'Rounded display '+rounded);
    assert(!text.includes('9007199254740999'),'Overridden query constraint must not be shown as effective');
    const inherited=await document.page.locator('[data-busyapi-inherited="true"]').getAttribute('data-busyapi-parameter-source');
    assert.equal(inherited,'/paths/~1value~1{id}/parameters/0');
    assert.deepEqual(document.errors,[]);assert.deepEqual(document.denied,[]);
    assert.deepEqual(await document.page.evaluate(()=>window.busyapiDocumentationFailures),[]);
    assert.equal(await document.page.getByRole('button',{name:/open in.*(chatgpt|claude)|ask ai|page actions/i}).count(),0);
  }finally{await document.context.close();}
});
