// Synthetic native-fixture diagnostics only. The final non-trace run uses the
// production entry, not this observer. Same public APIs/results, no data edits.
import React from 'react';
import {createRoot} from 'react-dom/client';
import {HashRouter} from 'react-router';
import {prepareApiDocs,Redoc} from 'redoc';
import {mountRedocReference} from './redoc_adapter.mjs';
import {graphAddressedDisplay} from './graph_display.mjs';
const diagnostic=error=>{
  const children=Array.isArray(error?.errors)?error.errors.slice(0,4):error?.cause?[error.cause]:[];
  window.webkit.messageHandlers.busyapiFixture?.postMessage(
    String(error?.name)+': '+String(error?.message??error)+' '+children.map(child=>String(child?.name)+': '+String(child?.message??child)).join('; ')+' '+String(error?.stack??'').slice(0,1200));
};
export function mount(text,projection,element,options) {
  const uri=new URL(window.location.href);uri.hash='';
  const presentation=graphAddressedDisplay(text,projection,uri.href,{addresses:'document-pointer'});
  return mountRedocReference(presentation,element,{...options,api:{React,HashRouter,Redoc,
    createRoot:(element,options)=>createRoot(element,{...options,onUncaughtError:error=>{diagnostic(error);options.onUncaughtError(error);}}),
    prepareApiDocs:async options=>{try{return await prepareApiDocs(options);}catch(error){diagnostic(error);throw error;}},
  }});
}
