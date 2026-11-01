// Local classic-script entry works for a relocated file:// export as well as
// the closed native scheme. No fetch, npm, renderer resolver or project code.
(() => {
  'use strict';
  const element=document.getElementById('busyapi-snapshot'),status=document.getElementById('busyapi-status');
  let input,reference,failed=false;
  const native=()=>location.protocol==='busyapi-doc:';
  const report=(kind,extra={})=>{
    if(native())window.webkit.messageHandlers.busyapiDocumentation.postMessage({version:1,snapshot:input?.snapshot,kind,...extra});
  };
  const failure=()=>{
    if(failed)return;failed=true;reference?.close();
    if(status){status.hidden=false;status.textContent=input?.labels?.failure??status.dataset.failure??'';}
    report('failed',{code:'renderer-failed'});
  };
  window.addEventListener('error',failure);
  window.addEventListener('unhandledrejection',failure);
  window.addEventListener('pagehide',()=>{reference?.close();reference=undefined;},{once:true});
  document.addEventListener('click',event=>{
    const anchor=event.composedPath().find(node=>node instanceof HTMLAnchorElement);
    if(!anchor)return;
    let internal=false;
    try{const target=new URL(anchor.href,location.href),current=new URL(location.href);target.hash='';current.hash='';internal=target.href===current.href&&!anchor.hasAttribute('download');}catch{}
    // Authored descriptions are display-only in these supplementary presets.
    // A link is not permission to load a file, API server, assistant or site.
    if(!internal){event.preventDefault();event.stopImmediatePropagation();}
  },true);
  (async()=>{
    try{
      if(!element||element.textContent.length>64*1024*1024)throw Error('Invalid captured presentation');
      input=JSON.parse(element.textContent);element.remove();
      if(input?.version!==1||!['redoc','swagger'].includes(input.preset)||typeof input.text!=='string'||typeof input.snapshot!=='string'||!input.labels||
          !Array.isArray(input.sourceActions)||typeof input.labels.page!=='string'||input.labels.page.length>256||
          !input.labels.page.includes('{page}')||!input.labels.page.includes('{pages}'))
        throw Error('Invalid captured presentation');
      const labels={...input.labels,page:(page,pages)=>input.labels.page.replaceAll('{page}',String(page)).replaceAll('{pages}',String(pages))};
      const renderer=input.preset==='redoc'?window.BusyApiRedoc:window.BusyApiSwagger;
      reference=await renderer.mount(input.text,input.projection,document.getElementById('reference'),{
        labels,onError:failure,
        ...(native()?{sourceActions:input.sourceActions,onSource:index=>report('source',{index})}:{}),
      });
      if(failed)return;
      // Wait for the actual mounted content, not merely an accepted Promise.
      const deadline=performance.now()+15000;
      const ready=input.preset==='redoc'?'#reference h1':'#reference .swagger-ui .info .title';
      while(!document.querySelector(ready)){
        if(performance.now()>deadline)throw Error('Documentation content did not mount');
        await new Promise(resolve=>setTimeout(resolve,20));
      }
      if(status)status.hidden=true;
      document.documentElement.dataset.busyapiReady='true';
      report('ready');
    }catch{failure();}
  })();
})();
