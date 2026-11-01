// Supported browser ES-module entry of the exact upstream Swagger UI release.
// Dependency resolution happens only during the locked asset build. Project
// resources remain the immutable graph-addressed input of the existing adapter.
import SwaggerUI from 'swagger-ui';
import React from 'react';
import {createRoot} from 'react-dom/client';
import {configuration} from './swagger_entry.mjs';

export async function mount(text,projection,element,options) {
  if(!element||typeof options?.onError!=='function')throw Error('busyapi.documentation.owner');
  let root,closed=false;
  const config=configuration(text,projection,'https://busyapi-display.invalid/captured/document.json',{
    ...options,
    onError:code=>{if(!closed)options.onError(code);},
    ...(options.onSource?{onSource:index=>{if(!closed)options.onSource(index);}}:{}),
  });
  // Own the React root through Swagger's root-injection extension point, so
  // closing a capture unmounts its observers and controls. Do not patch vendor
  // code or reach into React's private container properties for teardown.
  const owner=system=>({rootInjects:{render:node=>{
    if(closed||node!==element||root)throw Error('busyapi.documentation.owner');
    const App=system.getComponent('App','root');
    if(typeof App!=='function')throw Error('busyapi.documentation.plugin-api');
    root=createRoot(element);root.render(React.createElement(App));
  }}});
  try{
    const system=SwaggerUI({...config,plugins:[...config.plugins,owner],domNode:element,dom_id:null});
    return Object.freeze({system,close(){if(closed)return;closed=true;root?.unmount();root=undefined;}});
  }catch{
    closed=true;root?.unmount();
    throw Error('busyapi.documentation.renderer-failed');
  }
}
