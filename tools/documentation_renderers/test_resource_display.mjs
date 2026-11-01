// Narrow actual installed-asset probe, not native WebKit acceptance. Browser
// tools stay development-only; the tested renderer scripts are application assets.
import assert from 'node:assert/strict';
import {before,after,test} from 'node:test';
import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {readAuthoredPanels} from './test_authored_reader.mjs';
const probe=createRequire(new URL('../probes/m2/package.json',import.meta.url)),{chromium}=probe('playwright');
const engine=createRequire(new URL('../contract_engine/package.json',import.meta.url)),{referenceDisplay:prepareDisplay}=engine('./dist/reference_display.cjs');
const referenceDisplay=(input,outputId)=>prepareDisplay({...input,outputId});
const {mixed}=engine('../../fixtures/compatibility/reference_display.cjs');
const origin='http://busyapi-mixed-display.invalid';let browser;
before(async()=>{browser=await chromium.launch({headless:true,chromiumSandbox:true,...(process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE?{executablePath:process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE}:{})});});
after(async()=>{await browser?.close();});
for(const preset of ['swagger','redoc'])for(const version of ['3.1.2','3.2.1'])for(const pathItem of [false,true])test(`${preset} installed entry renders mixed-dialect graph content without resolution/ordinary network attempts ${version} pathItem=${pathItem}`,async()=>{
 const input=mixed(version,{pathItem}),before=JSON.stringify(input),captured=referenceDisplay(input,'https://display.invalid/reference.json');
 const directory=new URL(`../../build/test-runtime/share/busyapi/documentation/${preset}/`,import.meta.url);
 const manifest=JSON.parse(await readFile(new URL('assets.json',directory),'utf8'));
 const script=await readFile(new URL(preset+'.js',directory));
 const recorded=manifest.files[preset+'.js'];
 assert.equal(createHash('sha256').update(script).digest('hex'),typeof recorded==='string'?recorded:recorded.sha256);
 const context=await browser.newContext({serviceWorkers:'block'}),page=await context.newPage(),requests=[],denied=[],errors=[];
 context.setDefaultTimeout(15000);
 page.on('pageerror',error=>errors.push(error.message));
 page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
 page.on('popup',()=>errors.push('Unexpected popup'));
 await context.route('**/*',route=>{
  const url=route.request().url();requests.push(url);
  if(url===origin+'/index.html')return route.fulfill({contentType:'text/html',headers:{'Content-Security-Policy':"default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'"},body:'<!doctype html><div id="reference"></div>'});
  if(url===origin+'/'+preset+'.js')return route.fulfill({contentType:'text/javascript',body:script});
  denied.push(url);return route.abort('blockedbyclient');
 });
 try {
  await page.goto(origin+'/index.html');
  await page.addScriptTag({url:origin+'/'+preset+'.js'});
  if(preset==='swagger')await page.addStyleTag({content:await readFile(new URL('swagger.css',directory),'utf8')});
  await page.evaluate(async({preset,text,projection})=>{
   window.busyapiFailures=[];
   const renderer=preset==='redoc'?window.BusyApiRedoc:window.BusyApiSwagger;
   window.reference=await renderer.mount(text,projection,document.getElementById('reference'),{
    labels:{schemas:'Schemas',webhooks:'Webhooks',previousPage:'Previous',nextPage:'Next',page:(page,pages)=>`${page}/${pages}`,definition:'Read definition',dynamicReference:'Possible dynamic targets',inherited:'Inherited'},onError:code=>window.busyapiFailures.push(code),
   });
  },{preset,text:captured.output.text,projection:captured.projection});
  await page.locator(preset==='redoc'?'#reference h1':'#reference .swagger-ui .info').first().waitFor();
  const seen=new Set();
  if(preset==='redoc') {
   const slugs=await page.evaluate(()=>{const values=new Set(['']);function visit(items){for(const item of items){if(item.routeSlug&&item.content)values.add(item.routeSlug);visit(item.items??[]);}}visit(reference.items);return [...values];});
   for(const slug of slugs) {
    await page.evaluate(slug=>{window.location.hash='#/'+slug.replace(/^\//,'');},slug);
    if(slug)await page.waitForFunction(path=>[...document.querySelectorAll('[data-section-id]')].some(node=>node.getAttribute('data-section-id')===path&&node.textContent.trim()),'/'+slug.replace(/^\//,''));
    seen.add(await readAuthoredPanels(page));
   }
  } else {
   for(let step=0;step<15;step++) {
    await page.evaluate(()=>window.scrollBy(0,500));
    await page.waitForTimeout(30);
    seen.add(await readAuthoredPanels(page));
   }
   // Examples and schemas are distinct real tabs. A schema-only walk cannot
   // prove that an inactive authored example (including exact numbers) renders.
   for(const tab of await page.getByRole('tab',{name:'Example Value',exact:true}).all()) {
    await tab.click();seen.add(await readAuthoredPanels(page));
   }
  }
  const visible=[...seen].join('\n'),diagnostic=JSON.stringify({denied,errors,visible});
  for(const expected of ['Mixed dialect operation sentinel','2020 dialect schema sentinel','OAS dialect schema sentinel','literal example sentinel','9007199254740993.00','okay'])assert(visible.includes(expected),'Missing '+expected+' '+diagnostic);
  assert(!visible.includes('9007199254740992'),'Never present a rounded example as authored');
  assert.deepEqual(denied,[]);assert.deepEqual(errors,[]);assert.deepEqual(await page.evaluate(()=>busyapiFailures),[]);
  assert.deepEqual(requests,[origin+'/index.html',origin+'/'+preset+'.js']);
  assert.equal(await page.getByRole('button',{name:/^(authorize|try it out|execute|open in .+|ask ai)$/i}).count(),0);
  assert.equal(JSON.stringify(input),before);
  await page.evaluate(()=>reference.close());assert.equal(await page.locator('#reference *').count(),0);
 } finally {await context.close();}
});
