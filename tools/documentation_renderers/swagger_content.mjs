// Located presentation corrections through Swagger's supported component hooks.
// This consumes the same exact Reference pages as Redoc; no schema merge,
// numeric serialization, reference resolution or second document model lives here.
import {presentationNode,presentationSection} from './graph_display.mjs';
import {authoredContentComponent,authoredParametersComponent} from './authored_content.mjs';

const pointer=parts=>parts.length?'/'+parts.map(value=>String(value).replaceAll('~','~0').replaceAll('/','~1')).join('/'):'';
export function swaggerLocatedContent(system,Source) {
  const {React,Im}=system,element=React.createElement,rows=new WeakMap();
  let captured,Content,Parameters;
  function current(){
    const config=system.getConfigs(),presentation=config.busyApiPresentation(),labels=config.busyApiLabels;
    if(captured!==presentation){
      Content=authoredContentComponent(React,presentation,labels,Source);
      Parameters=authoredParametersComponent(React,Content,labels);captured=presentation;
    }
    return {presentation,labels};
  }
  function Schema(props){
    const {presentation}=current(),at=pointer(props.specPath?.toArray?.()??[]),
      section=presentationSection(presentation,at,{followReference:true});
    if(section?.kind!=='schema')throw Error('busyapi.documentation.content-source');
    return element(Content,{pointer:section.pointer});
  }
  function Schemas(){
    const {presentation,labels}=current(),at='/components/schemas';
    if(!presentationSection(presentation,at))return null;
    if(typeof labels.schemas!=='string'||!labels.schemas)throw Error('busyapi.documentation.labels');
    return element('section',{className:'models is-open'},element('h4',null,labels.schemas),element(Content,{pointer:at}));
  }
  function Webhooks(){
    const {presentation,labels}=current();
    if(!presentation.spec.openapi.startsWith('3.2.')||!presentationSection(presentation,'/webhooks'))return null;
    if(typeof labels.webhooks!=='string'||!labels.webhooks)throw Error('busyapi.documentation.labels');
    return element('section',{className:'webhooks'},element('h2',null,labels.webhooks),element(Content,{pointer:'/webhooks'}));
  }
  return {
    Model:()=>Schema,
    Models:()=>Schemas,
    BaseLayout:Original=>props=>element(React.Fragment,null,element(Original,props),element(Webhooks)),
    Callbacks:()=>props=>{
      const {presentation}=current(),parts=props.specPath?.toArray?.(),
        section=parts&&presentationSection(presentation,pointer(parts),{followReference:true});
      if(!section||section.kind!=='callback-map')throw Error('busyapi.documentation.content-source');
      // The pinned callback operation selector omits additionalOperations.
      // Render the complete captured callback tree instead of projecting an
      // incomplete operation list or changing authored method/data keys.
      return element(Content,{pointer:section.pointer});
    },
    parameters:Original=>props=>{
      const {presentation}=current(),parts=props.specPath?.toArray?.();
      if(!parts||parts.at(-1)!=='parameters')throw Error('busyapi.documentation.content-source');
      const occurrence=pointer(parts.slice(0,-1));
      const owner=presentationSection(presentation,occurrence,{followReference:true,occurrence}),
        effective=owner?.effective.find(entry=>entry.name==='parameters');
      if(!effective||effective.complete!==true||effective.invalid||!Array.isArray(effective.entries))throw Error('busyapi.documentation.content-source');
      const parameters=Im.List(effective.entries.map(entry=>{
        const node=presentationNode(presentation,entry.source.pointer);
        if(entry.state!=='resolved'||node?.kind!=='parameter')throw Error('busyapi.documentation.content-source');
        const value=Im.fromJS(node.value);rows.set(value,entry);return value;
      }));
      return element(Original,{...props,parameters});
    },
    parameterRow:()=>props=>{
      current();const entry=rows.get(props.rawParam);
      if(!entry)throw Error('busyapi.documentation.content-source');
      return element('tr',null,element('td',{colSpan:3},element(Parameters,{entries:[entry]})));
    },
  };
}
