import React from 'react';
import {createRoot} from 'react-dom/client';
import {HashRouter} from 'react-router';
import {prepareApiDocs,Redoc} from 'redoc';
import {mountRedocReference} from './redoc_adapter.mjs';
import {graphAddressedDisplay} from './graph_display.mjs';

export function mount(text,projection,element,options) {
  const uri=new URL(window.location.href);uri.hash='';
  const presentation=graphAddressedDisplay(text,projection,uri.href,{addresses:'document-pointer'});
  return mountRedocReference(presentation,element,{...options,api:{React,createRoot,HashRouter,prepareApiDocs,Redoc}});
}
