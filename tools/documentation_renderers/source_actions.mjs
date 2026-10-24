// Read-only opaque source controls. Original resources/ranges and freshness
// remain with the native owner; this module cannot navigate a URI or path.
import {hasPresentationCoordinate} from './graph_display.mjs';

export function documentationSourceControl(React,presentation,{sourceActions,onSource,labels}={}) {
  return documentationSourceFactory(presentation,{sourceActions,onSource,labels})?.(React);
}

// Compile once before asynchronous vendor preparation/installation. The pinned
// renderer supplies its own React runtime, rather than another dependency copy.
export function documentationSourceFactory(presentation,{sourceActions,onSource,labels}={}) {
  if(onSource===undefined) {
    if(sourceActions!==undefined)throw Error('busyapi.documentation.source-owner');
    return undefined;
  }
  if(typeof onSource!=='function'||!Array.isArray(sourceActions)||sourceActions.length>200000)
    throw Error('busyapi.documentation.source-owner');
  for(const label of ['source','sourceOwner'])if(typeof labels?.[label]!=='string'||!labels[label].trim())throw Error('busyapi.documentation.labels');
  const text=Object.freeze({source:labels.source,sourceOwner:labels.sourceOwner});
  const actions=new Map();let bytes=0;
  for(let index=0;index<sourceActions.length;index++) {
    const action=sourceActions[index];
    if(!action||typeof action!=='object'||Object.keys(action).length!==4||
      !Number.isSafeInteger(action.index)||action.index!==index||typeof action.pointer!=='string'||typeof action.authored!=='boolean'||
      !['node','field','reference'].includes(action.role)||(bytes+=action.pointer.length*2)>64*1024*1024||
      !hasPresentationCoordinate(presentation,action.pointer,action.role))throw Error('busyapi.documentation.source-action');
    const key=JSON.stringify([action.role,action.pointer]);
    if(actions.has(key))throw Error('busyapi.documentation.source-action');
    actions.set(key,Object.freeze({index,pointer:action.pointer,role:action.role,authored:action.authored}));
  }
  return React=>{
    if(!React?.createElement)throw Error('busyapi.documentation.plugin-api');
    return function Source({pointer,role='node'}) {
      const action=actions.get(JSON.stringify([role,pointer]));
      if(!action)return null;
      const label=text[action.authored?'source':'sourceOwner'];
      return React.createElement('button',{type:'button','data-busyapi-source':String(action.index),
        'data-busyapi-source-authored':String(action.authored),'aria-label':label,
        onClick:()=>onSource(action.index)},label);
    };
  };
}
