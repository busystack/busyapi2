// Actual packaged CLI output opened directly after relocation. Development
// browser tooling is never copied into these independent documentation sites.
import {test,before,after} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,copyFile,rename,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {readAuthoredPanels} from './test_authored_reader.mjs';
import {callbackDocument} from './test_fixtures/callback_document.mjs';
const probe=createRequire(new URL('../probes/m2/package.json',import.meta.url)),{chromium}=probe('playwright');
const engine=createRequire(new URL('../contract_engine/package.json',import.meta.url)),YAML=engine('yaml');
const {SourceDocument}=engine('./dist/document.cjs');
const {mixed}=engine('../../fixtures/compatibility/reference_display.cjs');
const root=fileURLToPath(new URL('../../',import.meta.url)),cli=process.env.BUSYAPI_TEST_CLI??path.join(root,'build/test-runtime/busyapi'),execute=promisify(execFile);
let browser;
before(async()=>{browser=await chromium.launch({headless:true,chromiumSandbox:true,...(process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE?{executablePath:process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE}:{})});});
after(async()=>{await browser?.close();});

async function readAll(page) {
  const seen=new Set(),routes=new Set(['#/']),visited=new Set();
  for(let count=0;count<80;count++){
    const route=[...routes].find(value=>!visited.has(value));if(route===undefined)break;visited.add(route);
    await page.evaluate(value=>{location.hash=value.slice(1);},route);
    // The pinned public links use #/page#page/section for an anchor within a
    // route. The mounted page's identity is the first segment, not that full
    // anchor string. Still navigate the actual complete authored display link.
    if(route!=='#/')try{await page.waitForFunction(section=>[...document.querySelectorAll('[data-section-id]')].some(node=>node.getAttribute('data-section-id')===section&&node.textContent.trim()),'/'+route.slice(2).split('#',1)[0]);}
    catch(error){console.error('Export mounted route failure',route,await page.evaluate(()=>({sections:[...document.querySelectorAll('[data-section-id]')].map(node=>node.getAttribute('data-section-id')),links:[...document.querySelectorAll('a[href]')].map(node=>({href:node.getAttribute('href'),text:node.textContent})),body:document.body.innerText.slice(0,2200)})));throw error;}
    seen.add(await readAuthoredPanels(page));
    for(const hash of await page.locator('a[href]').evaluateAll(anchors=>anchors.map(anchor=>{try{return new URL(anchor.href).hash;}catch{return '';}}).filter(value=>value.startsWith('#/'))))routes.add(hash);
    seen.add(await page.locator('body').innerText());
  }
  assert(routes.size<80,'The browser route inventory must remain bounded');
  return [...seen].join('\n');
}

async function readSwagger(page) {
  const seen=new Set();
  for(let count=0;count<50;count++){
    await page.evaluate(()=>{for(const branch of document.querySelectorAll('[data-busyapi-authored-branch]'))branch.open=true;});
    seen.add(await page.locator('body').innerText());
    await page.evaluate(()=>window.scrollTo(0,(window.scrollY+500)%Math.max(1,document.documentElement.scrollHeight-window.innerHeight+1)));
    await page.waitForTimeout(30);
  }
  seen.add(await readAuthoredPanels(page));
  for(const tab of await page.getByRole('tab',{name:'Example Value',exact:true}).elementHandles())if(await tab.evaluate(node=>node.isConnected)){
    await tab.click();seen.add(await readAuthoredPanels(page));
  }
  for(const tab of await page.locator('.tab-header .tab-item').filter({hasText:/^Callbacks$/}).elementHandles())if(await tab.evaluate(node=>node.isConnected)){
    await tab.click();seen.add(await readAuthoredPanels(page));
  }
  return [...seen].join('\n');
}

for(const scenario of ['rich','mixed'])for(const preset of ['redoc','swagger'])for(const family of ['31','32'])for(const format of ['yaml','json'])test(`relocated offline ${preset} ${scenario} ${family} ${format} uses the production CLI, assets and local entry`,async()=>{
  const temp=await mkdtemp(path.join(tmpdir(),'busyapi-redoc-export-dom-'));
  const context=await browser.newContext({serviceWorkers:'block'});
  try{
    const project=path.join(temp,'source'),site=path.join(temp,'generated');await mkdir(project);
    const source=path.join(project,'root.'+format),schema=path.join(project,scenario==='rich'?'schema.json':'models.json'),callback=path.join(project,'callbacks.json');
    const fixture=path.join(root,`fixtures/compatibility/oas${family}.json`);
    const original=await readFile(fixture,'utf8'),enhanced=scenario==='mixed'?mixed(family==='31'?'3.1.2':'3.2.1',{pathItem:true}).resources[0].text:new SourceDocument(original,pathToFileURL(source).href).set('/paths/~1things/get/callbacks',{
      Received:{$ref:'callbacks.json#/Shared',summary:'Captured callback owner'},
    });
    if(format==='json')await writeFile(source,enhanced,{flag:'wx'});
    else{
      // Equivalent temporary block-YAML oracle from the pinned canonical
      // parser, without routing numeric values through ordinary JS objects.
      const document=YAML.parseDocument(enhanced,{intAsBigInt:true});
      assert.deepEqual(document.errors,[]);YAML.visit(document,{Collection(_key,node){node.flow=false;}});
      await writeFile(source,'# temporary YAML renderer fixture\r\n'+document.toString({lineWidth:0}),{flag:'wx'});
    }
    if(scenario==='mixed')await writeFile(schema,mixed(family==='31'?'3.1.2':'3.2.1',{pathItem:true}).resources[1].text,{flag:'wx'});
    else{
      await copyFile(path.join(root,'fixtures/compatibility/schema.json'),schema);
      await writeFile(callback,callbackDocument(family==='31'?'3.1.2':'3.2.1'),{flag:'wx'});
    }
    const before=await readFile(source),beforeSchema=await readFile(schema),beforeCallback=scenario==='rich'?await readFile(callback):null;
    const result=await execute(cli,['build-docs',source,'--preset',preset,'--output',site,'--json'],{env:{PATH:'/nonexistent'},maxBuffer:2*1024*1024});
    assert.equal(JSON.parse(result.stdout).preset,preset);assert.equal(result.stderr,'');
    const relocated=path.join(temp,'relocated 雪 reference');await rename(site,relocated);
    const page=await context.newPage(),errors=[],requests=[],denied=[],popups=[];
    page.on('pageerror',error=>errors.push(error.message));page.on('request',request=>requests.push(request.url()));page.on('popup',popup=>{popups.push(popup.url());popup.close();});
    await context.route('**/*',route=>{
      const url=route.request().url();if(/^(?:https?|wss?):/.test(url)){denied.push(url);return route.abort('blockedbyclient');}return route.continue();
    });
    await page.addInitScript(()=>{window.policyViolations=[];document.addEventListener('securitypolicyviolation',event=>policyViolations.push({directive:event.effectiveDirective,blocked:event.blockedURI}));});
    await page.goto(pathToFileURL(path.join(relocated,'index.html')).href);
    await page.locator('html[data-busyapi-ready="true"]').waitFor({timeout:20000});
    const content=await (preset==='redoc'?readAll(page):readSwagger(page));
    const expected=scenario==='mixed'?['Mixed dialect operation sentinel','2020 dialect schema sentinel','OAS dialect schema sentinel','literal example sentinel','9007199254740993.00','okay']:['Compatibility operation sentinel','Schema property sentinel','payload data','Export callback POST sentinel',
      ...(family==='32'?['QUERY sentinel','COPY sentinel','Export callback QUERY sentinel','Export callback COPY sentinel','literal nested callback payload','900719925474099312345678901.00']:[])];
    for(const sentinel of expected)assert(content.includes(sentinel),'Missing actual local output content '+sentinel+' '+content.slice(0,1200));
    assert.equal(await page.getByRole('button',{name:/^(authorize|try it out|execute|ask ai|open in .*)$/i}).count(),0);
    assert.equal(await page.locator('[data-busyapi-source]').count(),0,'Standalone exports do not pretend to retain native source authority');
    assert.deepEqual(errors,[]);assert.deepEqual(denied,[]);assert.deepEqual(popups,[]);
    assert.deepEqual(await page.evaluate(()=>policyViolations),[]);
    assert(requests.every(url=>url.startsWith('file:')),'Ordinary rendering attempted a non-local resource');
    const inventory=JSON.parse(await readFile(path.join(relocated,'third-party.json'),'utf8')),
      notices=await readFile(path.join(relocated,'THIRD_PARTY_NOTICES.txt'),'utf8');
    assert.equal(inventory.packages.length,preset==='redoc'?52:118);assert(notices.includes(preset==='redoc'?'(c) Copyright 2025 Redocly Inc, all rights reserved.':'Copyright 2020-2021 SmartBear Software Inc.'));assert(notices.includes('Permission is hereby granted, free of charge'));
    assert(notices.includes('regenerator-runtime -- Copyright (c) 2014-present, Facebook, Inc. -- license (MIT)'));
    assert.equal(inventory.packages.find(record=>record.name==='dompurify').embeddedSources[0].license,'MIT');
    if(preset==='redoc'){
      const declaration=JSON.parse(await readFile(new URL('./license_declarations.json',import.meta.url),'utf8')).packages['@redocly/redoc-opentelemetry@0.5.1'];
      const record=inventory.packages.find(value=>value.name==='@redocly/redoc-opentelemetry');
      assert.equal(record.version,'0.5.1');assert.equal(record.license,'MIT');
      assert.deepEqual(record.declarationEvidence,declaration);
      assert(notices.includes(await readFile(new URL(declaration.supplement,import.meta.url),'utf8')),
        'The standalone copy must retain this component-specific declaration, copyright, permission and disclaimer, not another package\'s MIT text');
    }
    assert.deepEqual(await readFile(source),before);assert.deepEqual(await readFile(schema),beforeSchema);if(beforeCallback)assert.deepEqual(await readFile(callback),beforeCallback);
    // A separate adversarial phase must be denied before an IP request, not
    // confused with the zero-attempt ordinary-workflow assertions above.
    await page.evaluate(()=>{fetch('https://must-not-load.invalid/contract').catch(()=>{});const image=new Image();image.src='https://must-not-load.invalid/pixel';document.body.append(image);});
    await page.waitForTimeout(100);
    assert((await page.evaluate(()=>policyViolations)).some(value=>value.directive==='connect-src'));
    assert((await page.evaluate(()=>policyViolations)).some(value=>value.directive==='img-src'));
    assert.deepEqual(denied,[],'CSP must stop adversarial IP loads before the browser request boundary');
  }finally{await context.close();await rm(temp,{recursive:true,force:true});}
});
