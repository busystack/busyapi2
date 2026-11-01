import fs from 'node:fs/promises';
import path from 'node:path';
import {chromium} from 'playwright';
const fixtures=new URL('../../../fixtures/compatibility/',import.meta.url).pathname;
const kind=process.argv[2], name=process.argv[3];
if(!['swagger','redoc'].includes(kind)||!name)throw Error('Usage: node render.mjs swagger|redoc FIXTURE [bundle]');
const spec=await fs.readFile(path.isAbsolute(name)?name:path.join(fixtures,name),'utf8');
const adapter=process.argv[4]==='bundle';
const component=process.argv[4]==='component';
let componentBundle;
if(component){
 const {build}=await import('../../contract_engine/node_modules/esbuild/lib/main.js');
 componentBundle=(await build({entryPoints:[new URL('./redoc_component.mjs',import.meta.url).pathname],bundle:true,write:false,format:'esm',platform:'browser',define:{'process.env.NODE_ENV':'"production"'},logLevel:'silent'})).outputFiles[0].text;
}
const origin='http://busyapi-probe.invalid';
const assets=new URL('./node_modules/',import.meta.url);
const requests=[];const blocked=[];const errors=[];
const browser=await chromium.launch({headless:true});
try {
 const page=await browser.newPage({viewport:{width:1400,height:1000}});
 page.on('pageerror',e=>errors.push(e.message));
 page.on('console',m=>{if(m.type()==='error')errors.push(m.text().slice(0,700));});
 await page.route('**/*',async route=>{
  const url=new URL(route.request().url());requests.push(url.href);
  if(url.origin!==origin){blocked.push(url.href);return route.abort();}
  if(url.pathname==='/index.html')return route.fulfill({contentType:'text/html',body:'<!doctype html><html><head></head><body><div id="reference"></div></body></html>'});
  if(url.pathname==='/spec.json')return route.fulfill({contentType:'application/json',body:spec});
  if(url.pathname==='/schema.json')return route.fulfill({contentType:'application/json',body:await fs.readFile(path.join(fixtures,'schema.json'))});
  if(component&&url.pathname==='/assets/busyapi-redoc-component.js')return route.fulfill({contentType:'text/javascript',body:componentBundle});
  if(/^\/assets\/[A-Za-z0-9_.-]+\.js$/.test(url.pathname)){
   try{return route.fulfill({contentType:'text/javascript',body:await fs.readFile(new URL('redoc/bundles/'+url.pathname.slice(8),assets))});}catch{}
  }
  blocked.push(url.href);return route.abort();
 });
 await page.goto(origin+'/index.html');
 if(kind==='swagger'){
  await page.addScriptTag({path:new URL('swagger-ui-dist/swagger-ui-bundle.js',assets).pathname});
  await page.evaluate(url=>{
   const plugin=system=>({statePlugins:{spec:{wrapSelectors:{
    validOperationMethods:original=>(...args)=>{
     const names=new Set(original(...args));
     system.specSelectors.paths()?.forEach(item=>item.get('additionalOperations')?.keySeq().forEach(name=>names.add(name)));
     return [...names];
    },
    selectSchemas:original=>(...args)=>{
     const schemas=system.specSelectors.definitions();
     const resolved=system.specSelectors.specResolvedSubtree(['components','schemas']);
     const output=schemas.toJS();
     resolved?.forEach?.((value,name)=>{output[name]=value?.toJS?.()??value;});
     return output;
    },
    taggedOperations:original=>(...args)=>{
     let tags=original(...args);
     system.specSelectors.paths()?.forEach((item,path)=>item.get('additionalOperations')?.forEach((operation,method)=>{
      const op=system.Im.fromJS({path,method,operation,id:`${method}-${path}`,specPath:['paths',path,'additionalOperations',method]});
      const names=operation.get('tags')?.size?operation.get('tags').toJS():['default'];
      for(const name of names){if(!tags.has(name))tags=tags.set(name,system.Im.fromJS({tagDetails:{name},operations:[]}));tags=tags.updateIn([name,'operations'],ops=>ops.push(op));}
     }));return tags;
    },
    operationWithMeta:original=>(state,path,method)=>{
     const custom=system.specSelectors.specJsonWithResolvedSubtrees().getIn(['paths',path,'additionalOperations',method]);
     return custom??original(state,path,method);
    },
   }}}});
   window.ui=window.SwaggerUIBundle({url,dom_id:'#reference',plugins:[plugin],docExpansion:'full',defaultModelsExpandDepth:2,defaultModelRendering:'model',defaultModelExpandDepth:4,supportedSubmitMethods:[],validatorUrl:null});
  },origin+'/spec.json');
 }else if(component){
  await page.evaluate(async url=>{const {render}=await import('/assets/busyapi-redoc-component.js');window.busyapiCloseReference=await render(await(await fetch(url)).json(),document.getElementById('reference'));},origin+'/spec.json');
 }else{
  await page.evaluate(async ({url,adapter})=>{const {init}=await import('/assets/redoc.standalone.js');const input=adapter?await(await fetch(url)).json():url;await init(input,{skipBundle:adapter,sanitize:true,disableTelemetry:true,hideDownloadButtons:true,layout:'stacked',router:'hash'},document.getElementById('reference'));},{url:origin+'/spec.json',adapter});
 }
 const seen=new Set();
 for(let i=0;i<80;i++){
  const text=await page.locator('body').innerText();
  for(const sentinel of ['Compatibility operation sentinel','Schema property sentinel','QUERY sentinel','COPY sentinel','payload data'])if(text.includes(sentinel))seen.add(sentinel);
  await page.evaluate(()=>{const nodes=[document.scrollingElement,...document.querySelectorAll('*')].filter(x=>x&&x.scrollHeight>x.clientHeight+20);for(const n of nodes)n.scrollTop=(n.scrollTop+400)%(n.scrollHeight-n.clientHeight+1);});
  await page.waitForTimeout(100);
 }
 const text=await page.locator('body').innerText();
 const expected=['Compatibility operation sentinel','Schema property sentinel',...(JSON.parse(spec).openapi.startsWith('3.2')?['QUERY sentinel','COPY sentinel']:[])];
 const missing=expected.filter(s=>!seen.has(s));
 const unexpectedAttempts=[...new Set(blocked)];
 const executionControls=await page.getByRole('button').allTextContents();
 const status=missing.length||errors.length||unexpectedAttempts.length?'failing':'working';
 console.log(JSON.stringify({renderer:kind,fixture:path.basename(name),adapter,component, status,seen:[...seen],missing,errors,requests:[...new Set(requests)],blocked,unexpectedAttempts,executionControls}));
 if(status!=='working')process.exitCode=2;
}finally{await browser.close();}
