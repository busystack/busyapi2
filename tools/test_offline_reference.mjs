// Development-only browser qualification of the actual local-file entry path.
// No browser/test dependency or executable is distributed with generated sites.
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,copyFile,rename,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
import {spawnSync} from 'node:child_process';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const require=createRequire(join(root,'tools/probes/m2/package.json'));
const {chromium}=require('playwright');
const {mixed}=createRequire(import.meta.url)('../fixtures/compatibility/reference_display.cjs');
const cli=resolve(process.argv[2]??join(root,'build/test-runtime/busyapi'));
const temporary=await mkdtemp(join(tmpdir(),'busyapi-offline-reference-'));
let browser;
try {
 browser=await chromium.launch({headless:true,chromiumSandbox:true,
  ...(process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE?{executablePath:process.env.BUSYAPI_TEST_BROWSER_EXECUTABLE}:{})});
 for(const family of ['31','32'])for(const [scenario,format] of [['rich','json'],['mixed','json'],['mixed','yaml']]) {
  const source=join(temporary,'api '+scenario+' '+family+' 雪.'+format);
  if(scenario==='mixed'){
   const version=family==='31'?'3.1.2':'3.2.1';
   if(format==='json'){
    const input=mixed(version);
    await writeFile(source,input.resources[0].text);
    await writeFile(join(temporary,'models.json'),input.resources[1].text);
   }else{
    for(const [destination,name]of [[source,'root'],[join(temporary,'models.yaml'),'models']])await writeFile(destination,(await readFile(join(root,'fixtures/compatibility/mixed-dialects-'+name+'.yaml'),'utf8')).replace('openapi: 3.1.2','openapi: '+version));
   }
  }else{
  const value=JSON.parse(await readFile(join(root,'fixtures/compatibility/oas'+family+'.json'),'utf8'));
  value.info.description='# Offline content\n\n**CommonMark sentinel**\n\n![image alt sentinel](https://must-not-load.invalid/image)\n\n<script>window.unwantedExecution=true</script>\n\n[unsafe](javascript:window.unwantedExecution=true) [external](https://must-not-load.invalid/guide)';
  value.components.examples={Large:{value:{number:111,description:'**literal example sentinel**',$ref:'literal payload'}}};
  value.paths['/things'].post={operationId:'createThing',requestBody:{content:{'application/json':{schema:{$ref:'schema.json#/Thing'}}}},responses:{201:{description:'Created',headers:{'X-Count':{schema:{type:'integer'}}}}}};
  await writeFile(source,JSON.stringify(value).replace('"number":111','"number":9007199254740993'));
  await copyFile(join(root,'fixtures/compatibility/schema.json'),join(temporary,'schema.json'));
  }
  const output=join(temporary,'first output '+scenario+' '+family+' '+format);
  const command=spawnSync(cli,['build-docs',source,'--output',output,'--json'],{
   env:{PATH:'',LANG:'C.UTF-8'},encoding:'utf8',timeout:60000,
  });
  assert.equal(command.status,0,command.stderr+'\n'+command.stdout);
  const record=JSON.parse(command.stdout);assert.equal(record.output.entry,'index.html');
  const relocated=join(temporary,'relocated site '+scenario+' '+family+' '+format+' 空');await rename(output,relocated);
  const context=await browser.newContext({serviceWorkers:'block'}),page=await context.newPage();
  const attempted=[],errors=[];
  await context.route('**/*',route=>{
   const request=route.request().url();
   if(request.startsWith(pathToFileURL(relocated).href+'/'))return route.continue();
   attempted.push(request);return route.abort('blockedbyclient');
  });
  page.on('pageerror',error=>errors.push(error.message));
  page.on('popup',()=>errors.push('Unexpected popup'));
  await page.goto(pathToFileURL(join(relocated,'index.html')).href,{waitUntil:'load'});
  const content=await page.locator('body').innerText();
  for(const sentinel of scenario==='mixed'?['Mixed dialect operation sentinel','2020 dialect schema sentinel','OAS dialect schema sentinel','9007199254740993.00','literal example sentinel','okay']:['listThings','requestBody','responses','headers','Boolean','Composed','9007199254740993','literal payload','literal example sentinel','image alt sentinel','a/b','CommonMark sentinel'])assert(content.includes(sentinel),'Missing '+sentinel+' in '+family+' '+scenario+' '+format);
  if(scenario==='rich'&&family==='32')for(const sentinel of ['queryThings','copyThings','QUERY','COPY'])assert(content.includes(sentinel),'Missing '+sentinel);
  if(scenario==='rich')assert.equal(await page.locator('strong').filter({hasText:'CommonMark sentinel'}).count(),1);
  assert.equal(await page.locator('script,img,iframe,object,embed,form,button,input,video,audio').count(),0);
  assert.equal(await page.evaluate(()=>window.unwantedExecution),undefined);
  assert.equal(await page.locator('a[href^="javascript:"]').count(),0);
  const broken=await page.locator('a[href^="#"]').evaluateAll(links=>links.filter(link=>!document.getElementById(link.getAttribute('href').slice(1))).map(link=>link.textContent));
  assert.deepEqual(broken,[],'Every definition/effective/dynamic/source anchor must exist');
  await page.locator('nav a').first().click();
  assert(new URL(page.url()).hash,'Internal navigation must work under file://');
  await page.waitForTimeout(200);
  assert.deepEqual(attempted,[],'Ordinary rendering attempted an unapproved resource');
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({preset:'native-reference',family,scenario,format,browser:browser.version(),entry:'relocated file://',complete:true,unexpectedRequests:attempted.length,errors:errors.length}));
  await context.close();
 }
} finally {
 await browser?.close();
 await rm(temporary,{recursive:true,force:true});
}
