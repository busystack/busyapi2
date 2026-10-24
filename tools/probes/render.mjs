// Trusted fixture-only browser probe. No production renderer dependency.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
const base=path.dirname(fileURLToPath(import.meta.url));
const source=path.resolve(process.argv[2]);
const spec=JSON.parse(await fs.readFile(source,'utf8'));
const kind=process.argv[3];const browser=await chromium.launch({headless:true});
try{
 const page=await browser.newPage();
 const origin='http://busyapi-probe.invalid';
 const resources=new Map([[path.basename(source),await fs.readFile(source)],
   ['schema.json',await fs.readFile(path.join(path.dirname(source),'schema.json'))]]);
 await page.route('**/*',route=>{
   const url=new URL(route.request().url());
   if(url.origin!==origin)return route.abort();
   if(url.pathname==='/index.html')return route.fulfill({contentType:'text/html',body:'<div id="reference"></div>'});
   const body=resources.get(url.pathname.slice(1));
   return body?route.fulfill({contentType:'application/json',body}):route.abort();
 });
 await page.goto(origin+'/index.html');
 const url=origin+'/'+path.basename(source);
 if(kind==='swagger'){
  await page.addScriptTag({path:path.join(base,'node_modules/swagger-ui-dist/swagger-ui-bundle.js')});
  await page.evaluate(url=>window.SwaggerUIBundle({url,dom_id:'#reference',docExpansion:'full',defaultModelsExpandDepth:2,defaultModelRendering:'model',defaultModelExpandDepth:4,supportedSubmitMethods:[],validatorUrl:null}),url);
 }else{
  await page.addScriptTag({path:path.join(base,'node_modules/redoc/bundles/redoc.standalone.js')});
  await page.evaluate(url=>window.Redoc.init(url,{disableSearch:true,hideDownloadButton:true,expandResponses:'all',schemaExpansionLevel:4},document.getElementById('reference')),url);
 }
 await page.waitForFunction(()=>['Compatibility operation sentinel','Schema property sentinel'].every(text=>document.body.textContent.includes(text)),null,{timeout:15000});
 const text=await page.locator('body').innerText();
 for(const sentinel of ['Compatibility operation sentinel','Schema property sentinel'])if(!text.includes(sentinel))throw Error(`Rendered ${kind} output lacks ${sentinel}`);
 if(spec.openapi.startsWith('3.2'))for(const sentinel of ['QUERY sentinel','COPY sentinel'])if(!text.includes(sentinel))throw Error(`Rendered ${kind} output lacks ${sentinel}`);
 console.log(JSON.stringify({status:'working',renderer:kind,assertions:['operation','schema','version-methods']}));
}finally{await browser.close();}
