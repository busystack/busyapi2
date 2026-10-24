// Bounded read-only presentation of the existing native Reference projection.
// This is not a schema model, parser, resolver, evaluator or authoring surface.
// In particular it never asks a renderer to infer examples or merge schemas.
import {presentationSection,presentationValue} from './graph_display.mjs';

export function authoredContentComponent(React,presentation,labels,Source=()=>null) {
  if(!React?.createElement||!React.useState||!presentationSection(presentation,''))throw Error('busyapi.documentation.plugin-api');
  for(const name of ['previousPage','nextPage','definition','dynamicReference'])if(typeof labels?.[name]!=='string'||!labels[name].trim())throw Error('busyapi.documentation.labels');
  if(typeof labels.page!=='function')throw Error('busyapi.documentation.labels');
  const element=React.createElement;
  function Pages({page,pages,select}) {
    return pages>1?element('nav',null,
      element('button',{type:'button','aria-label':labels.previousPage,disabled:page===0,onClick:()=>select(page-1)},'‹'),
      element('span',{'aria-live':'polite'},labels.page(page+1,pages)),
      element('button',{type:'button','aria-label':labels.nextPage,disabled:page+1===pages,onClick:()=>select(page+1)},'›')):null;
  }
  function ExactText({value}) {
    const [page,select]=React.useState(0),text=value.representation==='text'?value.text:value.raw,size=8192,pages=Math.max(1,Math.ceil(text.length/size));
    const selected=Math.min(page,pages-1);let start=selected*size,end=Math.min(text.length,(selected+1)*size);
    if(start&&/[\uDC00-\uDFFF]/u.test(text[start])&&/[\uD800-\uDBFF]/u.test(text[start-1]))start--;
    if(end<text.length&&/[\uDC00-\uDFFF]/u.test(text[end])&&/[\uD800-\uDBFF]/u.test(text[end-1]))end--;
    return element('div',null,element('pre',{style:{whiteSpace:'pre-wrap',overflowWrap:'anywhere'}},
      element('code',{'data-busyapi-authored-value':value.source.pointer},text.slice(start,end))),element(Pages,{page:selected,pages,select}));
  }
  function Branch({entry,depth,navigate}) {
    const [expanded,expand]=React.useState(false);
    if(depth>=32)return element('button',{type:'button',onClick:()=>navigate(entry.target.pointer)},entry.name+' →');
    return element('details',{'data-busyapi-authored-branch':entry.target.pointer,onToggle:event=>expand(event.currentTarget.open)},
      element('summary',null,entry.name),expanded?element(Content,{pointer:entry.target.pointer,depth:depth+1,navigate}):null);
  }
  function Reference({reference,navigate}) {
    const [page,select]=React.useState(0),targets=reference.dynamic?reference.dynamic.candidates:[reference.target],size=25,
      pages=Math.max(1,Math.ceil(targets.length/size)),selected=Math.min(page,pages-1);
    return element('div',null,
      reference.dynamic?element('span',null,labels.dynamicReference+' '+reference.dynamic.anchor):null,
      ...targets.slice(selected*size,(selected+1)*size).map((target,index)=>element('button',{key:index,type:'button',onClick:()=>navigate(target.pointer),
        'data-busyapi-definition':target.pointer,'aria-label':labels.definition+' '+target.pointer},reference.keyword+' → '+target.pointer)),
      element(Pages,{page:selected,pages,select}));
  }
  function Content({pointer,depth=0,navigate}) {
    const [page,select]=React.useState(0),section=presentationSection(presentation,pointer);
    if(!section||depth>64)throw Error('busyapi.documentation.authored-content');
    const size=25,pages=Math.max(1,Math.ceil(section.entries.length/size)),selected=Math.min(page,pages-1);
    return element('section',{'data-busyapi-authored-content':pointer},
      element(Source,{pointer}),
      section.pointer!==pointer?element('code',{'data-busyapi-definition-owner':section.pointer},section.pointer):null,
      ...(section.text!==undefined?[element('code',{key:'value',...(section.kind==='schema'&&['true','false'].includes(section.text)?{'data-busyapi-boolean-schema':section.text}:{})},section.text)]:[]),
      element('dl',null,...section.entries.slice(selected*size,(selected+1)*size).map(entry=>entry.target?
        element('div',{key:entry.source.pointer},element(Branch,{entry,depth,navigate}),
          entry.reference?element(Reference,{reference:entry.reference,navigate}):null):
        element('div',{key:entry.source.pointer},element('dt',null,entry.name,element(Source,{pointer:entry.source.pointer,role:'field'})),element('dd',null,
          element(ExactText,{value:presentationValue(presentation,entry.source.pointer,{followReference:false}),key:entry.source.pointer}),
          entry.reference?element(Reference,{reference:entry.reference,navigate}):null)))),
      element(Pages,{page:selected,pages,select}));
  }
  return function AuthoredContent({pointer,field=false}) {
    const [selected,navigate]=React.useState(pointer);
    if(field)return element('section',{'data-busyapi-authored-panel':pointer},element('code',null,pointer),element(Source,{pointer,role:'field'}),element(ExactText,{value:presentationValue(presentation,pointer,{followReference:false})}));
    return element('div',{'data-busyapi-authored-panel':pointer},selected!==pointer?element('button',{type:'button',onClick:()=>navigate(pointer),'aria-label':labels.definition+' '+pointer},'← '+pointer):null,
      element(Content,{pointer:selected,navigate,key:selected}));
  };
}

export function authoredParametersComponent(React,Content,labels) {
  if(typeof labels?.inherited!=='string'||!labels.inherited.trim())throw Error('busyapi.documentation.labels');
  const element=React.createElement;
  return function Parameters({entries}) {
    const [page,select]=React.useState(0),size=25,pages=Math.max(1,Math.ceil(entries.length/size)),selected=Math.min(page,pages-1);
    return element('section',null,...entries.slice(selected*size,(selected+1)*size).map(entry=>element('section',{key:entry.source.pointer,
      'data-busyapi-parameter-source':entry.source.pointer,'data-busyapi-inherited':String(entry.inherited)},
      element('code',null,entry.name+' ('+entry.location+')'),entry.inherited?element('span',null,' · '+labels.inherited):null,
      element(Content,{pointer:entry.source.pointer}))),pages>1?element('nav',null,
      element('button',{type:'button','aria-label':labels.previousPage,disabled:selected===0,onClick:()=>select(selected-1)},'‹'),
      element('span',{'aria-live':'polite'},labels.page(selected+1,pages)),
      element('button',{type:'button','aria-label':labels.nextPage,disabled:selected+1===pages,onClick:()=>select(selected+1)},'›')):null);
  };
}
