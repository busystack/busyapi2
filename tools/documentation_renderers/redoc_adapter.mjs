// Exact-release Redoc CE component adapter. Vendor packages are injected by
// the build entry point, not loaded from a project or acquired at runtime.
import {presentationNode} from './graph_display.mjs';
import {redocAuthoredContent} from './redoc_content.mjs';
import {documentationSourceFactory} from './source_actions.mjs';

export const redocAdapterIdentity=Object.freeze({
  producer:'busyapi-redoc-read-only',version:'7',package:'redoc',packageVersion:'3.0.1',
});

// Markdoc's parsed descriptions are untrusted data. Display text only: no
// authored tag, image, event handler or href becomes a DOM capability.
export function redocDescriptionText(source) {
  let nodes=0,bytes=0;
  const blocks=new Set(['paragraph','heading','list','item','blockquote','fence','hardbreak','softbreak']);
  const visit=(value,depth)=>{
    if(++nodes>200000||depth>128)throw Error('busyapi.documentation.description-limit');
    if(typeof value==='string'){
      if((bytes+=value.length*2)>2*1024*1024)throw Error('busyapi.documentation.description-limit');
      return value;
    }
    if(Array.isArray(value))return value.map(child=>visit(child,depth+1)).join('');
    if(!value||typeof value!=='object')return '';
    if(value.type==='image')return typeof value.attributes?.alt==='string'?visit(value.attributes.alt,depth+1):'';
    if(value.type==='tag'&&value.tag==='html') {
      const name=value.attributes?.name;
      if(typeof name!=='string')return '';
      const attributes=value.attributes?.attrs;
      const text='<'+visit(name,depth+1)+(attributes&&typeof attributes==='object'?Object.entries(attributes).map(([key,item])=>
        typeof item==='string'?' '+visit(key,depth+1)+'='+JSON.stringify(visit(item,depth+1)):'').join(''):'')+'>';
      return text+visit(value.children??[],depth+1);
    }
    return (typeof value.attributes?.content==='string'?visit(value.attributes.content,depth+1):'')+
      visit(value.children??[],depth+1)+(blocks.has(value.type)?'\n':'');
  };
  return visit(source,0);
}

export async function mountRedocReference(presentation,element,{api,onError,signal,labels,sourceActions,onSource}={}) {
  // Prove ownership by consulting the private shared presentation index. A
  // lookalike object cannot bypass graph capture or source freshness checks.
  if(presentation?.addresses!=='document-pointer'||presentationNode(presentation,'')?.kind!=='root')
    throw Error('busyapi.documentation.projection');
  if(presentation.spec.swagger==='2.0')throw Error('busyapi.documentation.redoc-swagger-conversion');
  if(!api?.React?.createElement||typeof api.createRoot!=='function'||!api.HashRouter||
      typeof api.prepareApiDocs!=='function'||!api.Redoc||
      typeof onError!=='function'||typeof labels?.schemas!=='string'||!labels.schemas.trim())
    throw Error('busyapi.documentation.plugin-api');
  if(signal?.aborted)throw Error('busyapi.documentation.cancelled');
  let closed=false,root;
  const close=()=>{if(closed)return;closed=true;signal?.removeEventListener('abort',close);root?.unmount();root=undefined;};
  signal?.addEventListener('abort',close,{once:true});
  const fail=code=>{close();onError(code);throw Error(code);};
  let source;
  try {source=documentationSourceFactory(presentation,{sourceActions,onSource,labels})?.(api.React);}catch{return fail('busyapi.documentation.renderer-failed');}
  let prepared;
  try {
    // The pinned adapter normalizes some presentation data in place. Supply a
    // private clone, never the owner's immutable graph-addressed input.
    prepared=await api.prepareApiDocs({spec:structuredClone(presentation.spec),convertedDownload:false,basePath:'/',options:{
      skipBundle:true,disableTelemetry:true,sanitize:true,hideDownloadButtons:true,
      layout:'stacked',schemaDefinitionsTagName:labels.schemas,
    }});
  }catch{return fail('busyapi.documentation.renderer-failed');}
  if(closed||signal?.aborted){close();throw Error('busyapi.documentation.cancelled');}
  if(prepared?.specType!=='openapi'||!Array.isArray(prepared.items)||prepared.items.length>40000||
      !prepared.store||!prepared.options||(prepared.document?.openapi!==presentation.spec.openapi||prepared.document?.swagger!==presentation.spec.swagger))
    return fail('busyapi.documentation.renderer-failed');
  let content;
  try {content=redocAuthoredContent(api.React,presentation,prepared.items,labels,source);}catch{return fail('busyapi.documentation.renderer-failed');}
  const markdownAdapter={parse:source=>source,render:source=>content.render(source)??api.React.createElement('span',{style:{whiteSpace:'pre-wrap'}},redocDescriptionText(source))};
  try {
    root=api.createRoot(element,{onUncaughtError:()=>{close();onError('busyapi.documentation.renderer-failed');}});
    root.render(api.React.createElement(api.HashRouter,null,api.React.createElement(api.Redoc,{
      items:content.items,store:prepared.store,basePath:'/',options:{...prepared.options,disableTelemetry:true},
      telemetryConfig:{disabled:true,beforeSend:()=>false},markdownAdapter,
    })));
  }catch{return fail('busyapi.documentation.renderer-failed');}
  // Captured items are also used for exact operation/content qualification.
  // They are vendor display output, never an API document or export authority.
  return Object.freeze({close,items:content.items,store:prepared.store});
}
