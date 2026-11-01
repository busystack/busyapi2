// Supported Redoc `items`/`markdownAdapter` presentation boundary. These are
// disposable display nodes, never API edits or changes to the supplied spec.
import {presentationSection,presentationValue} from './graph_display.mjs';
import {authoredContentComponent,authoredParametersComponent} from './authored_content.mjs';

export function redocAuthoredContent(React,presentation,items,labels,Source) {
  const Content=authoredContentComponent(React,presentation,labels,Source),Parameters=authoredParametersComponent(React,Content,labels),tokens=new WeakMap();
  let work=0;
  const maps=new Map();
  const owners=new WeakMap();
  const fields=pointer=>{
    if(!maps.has(pointer))maps.set(pointer,new Map((presentationSection(presentation,pointer)?.entries??[]).map(entry=>[entry.name,entry])));
    return maps.get(pointer);
  };
  const operationOwner=item=>{
    if(owners.has(item))return owners.get(item);
    const display=item.content.meta?.pointer;
    if(typeof display!=='string'||typeof item.httpPath!=='string'||typeof item.httpVerb!=='string')throw Error('busyapi.documentation.content-source');
    const path=fields(item.isWebhook?'/webhooks':'/paths').get(item.httpPath)?.target?.pointer;
    // A Path Item occurrence can be a reference, not a local operation map.
    // Follow only the projection's captured alias coordinates; local fields and
    // chained shared definitions retain the graph's distinct ownership rules.
    const candidate=path+(item.isAdditionalOperation?'/additionalOperations':'')+'/'+item.httpVerb.replaceAll('~','~0').replaceAll('/','~1');
    const operation=path&&presentationSection(presentation,candidate,{followReference:true});
    if(operation?.kind!=='operation')throw Error('busyapi.documentation.content-source');
    const context=presentationSection(presentation,operation.pointer,{occurrence:candidate});
    const owner={display,pointer:operation.pointer,occurrence:candidate,navigationId:context.navigationId};owners.set(item,owner);return owner;
  };
  // `ApiItem` publicly exposes routeSlug/link. The pinned CE derives them
  // from operationId, which can name one physical operation used at multiple
  // logical Path Item occurrences. Disambiguate only those display routes,
  // using the captured occurrence, never by changing the contract's ID/path.
  const routeOwners=new Map(),usedRoutes=new Set(),navigationIds=new Map();let routeWork=0;
  const scanRoutes=(values,depth=0)=>{
    if(!Array.isArray(values)||depth>64)throw Error('busyapi.documentation.content-limit');
    for(const item of values){
      if(++routeWork>200000||!item||typeof item!=='object')throw Error('busyapi.documentation.content-limit');
      for(const value of [item.routeSlug,item.link])if(typeof value==='string')usedRoutes.add(value);
      if(item.content?.itemVariant==='httpItem'&&typeof item.routeSlug==='string'){
        const owner=operationOwner(item),values=routeOwners.get(item.routeSlug)??new Set();values.add(owner.occurrence);routeOwners.set(item.routeSlug,values);navigationIds.set(owner.occurrence,owner.navigationId);
      }
      if(item.items)scanRoutes(item.items,depth+1);
    }
  };
  scanRoutes(items);
  const distinct=new Set([...routeOwners.values()].filter(values=>values.size>1).flatMap(values=>[...values])),routes=new Map();
  for(const occurrence of [...distinct].sort()){
    const identity=navigationIds.get(occurrence);
    if(typeof identity!=='string'||!/^[a-f0-9]{64}$/.test(identity))throw Error('busyapi.documentation.route-owner');
    // The canonical projection supplies this opaque view ID; no browser hash,
    // URI resolution or source operationId mutation is involved. Lowercase
    // IDs also survive CE's public route/section normalization unchanged.
    const base='/busyapi-operation/'+identity;let suffix=0,route=base;
    while(usedRoutes.has(route))route=base+'-'+(++suffix);
    routes.set(occurrence,route);usedRoutes.add(route);
  }
  const token=pointer=>{
    const section=presentationSection(presentation,pointer,{followReference:true});
    if(!section)throw Error('busyapi.documentation.content-source');
    const content=Object.freeze({});tokens.set(content,{pointer:section.pointer});
    return {nodeType:'markdoc',content};
  };
  const parameterLocations={headers:'header',query:'query',querystring:'querystring',path:'path',cookies:'cookie'};
  const nodes=(values,schemaPage=false,depth=0,owner)=>{
    if(!Array.isArray(values)||depth>64)throw Error('busyapi.documentation.content-limit');
    let replaced=false,request=false;
    const result=values.map(node=>{
      if(++work>200000||!node||typeof node!=='object')throw Error('busyapi.documentation.content-limit');
      if(node.nodeType==='header') {
        if(!Source||!owner)return {...node,showPageActions:false};
        const content=Object.freeze({});tokens.set(content,{source:owner.pointer});
        return {nodeType:'container',children:[{...node,showPageActions:false},{nodeType:'markdoc',content}]};
      }
      // Only the generated top-level schema-definition item is adapted. An
      // authored Markdoc tag in a description never becomes a capability.
      if(schemaPage&&node.nodeType==='markdoc'&&Array.isArray(node.content)&&node.content.length===1) {
        const tag=node.content[0];
        if(tag?.type==='tag'&&tag.tag==='schemaDefinition') {
          const reference=tag.attributes?.schemaRef;
          if(typeof reference!=='string'||!reference.startsWith('#/'))throw Error('busyapi.documentation.content-source');
          const pointer=decodeURIComponent(reference.slice(1));
          if(presentationSection(presentation,pointer)?.kind!=='schema')throw Error('busyapi.documentation.content-source');
          return token(pointer);
        }
      }
      if(node.nodeType==='item-content'&&node.variant==='responses') {
        // 3.0.1's public additional-operation item can omit the
        // additionalOperations segment in its *display* pointer. Join its
        // explicit method/path inventory to typed graph fields, never repair
        // an arbitrary pointer string or select by a non-unique operationId.
        if(!owner||node.pointer!==owner.display+'/responses')
          throw Error('busyapi.documentation.content-source');
        const pointer=owner.pointer+'/responses';
        if(presentationSection(presentation,pointer)?.kind!=='response-map')throw Error('busyapi.documentation.content-source');
        replaced=true;return token(pointer);
      }
      if(node.nodeType==='item-content'&&node.variant==='body') {
        if(!owner||node.pointer!==owner.display+'/requestBody'||presentationSection(presentation,owner.pointer+'/requestBody')?.kind!=='request-body')
          throw Error('busyapi.documentation.content-source');
        replaced=true;request=true;return token(owner.pointer+'/requestBody');
      }
      if(node.nodeType==='item-content'&&Object.hasOwn(parameterLocations,node.variant)) {
        if(!owner||node.pointer!==owner.display+'/parameters')throw Error('busyapi.documentation.content-source');
        const effective=presentationSection(presentation,owner.pointer,{occurrence:owner.occurrence})?.effective.find(field=>field.name==='parameters');
        if(!effective||effective.complete!==true||effective.invalid||!Array.isArray(effective.entries))throw Error('busyapi.documentation.content-source');
        const entries=Object.freeze(effective.entries.filter(entry=>entry.location===parameterLocations[node.variant]));
        if(!entries.length||entries.some(entry=>entry.state!=='resolved'||presentationSection(presentation,entry.source.pointer)?.kind!=='parameter'))
          throw Error('busyapi.documentation.content-source');
        const content=Object.freeze({});tokens.set(content,{entries});
        replaced=true;request=true;return {nodeType:'markdoc',content};
      }
      if(node.nodeType==='item-content'&&node.variant==='callback') {
        if(!owner||node.pointer!==owner.display+'/callbacks'||presentationSection(presentation,owner.pointer+'/callbacks',{followReference:true})?.kind!=='callback-map')
          throw Error('busyapi.documentation.content-source');
        // CE's callback content enumerates fixed methods but not 3.2
        // additionalOperations. The shared located tree preserves every
        // callback Path Item, operation, response, schema and exact example.
        replaced=true;return token(owner.pointer+'/callbacks');
      }
      if(node.nodeType==='container') {
        const children=nodes(node.children??[],schemaPage,depth+1,owner);
        // The exact authored Responses tree includes every media type, schema,
        // example and header. Do not also show rounded/inferred vendor samples
        // from this container's parallel response panel. Other panels survive.
        const values=[...children.values];
        if(children.request&&presentationValue(presentation,owner.pointer+'/x-codeSamples',{followReference:false})) {
          const content=Object.freeze({});tokens.set(content,{pointer:owner.pointer+'/x-codeSamples',field:true});values.push({nodeType:'markdoc',content});
        }
        return {...node,children:values,...(children.replaced?{panels:[]}:{})};
      }
      return node;
    });
    return {values:result,replaced,request};
  };
  const visit=(values,depth=0)=>{
    if(!Array.isArray(values)||depth>64)throw Error('busyapi.documentation.content-limit');
    return values.map(item=>{
      if(++work>200000||!item||typeof item!=='object')throw Error('busyapi.documentation.content-limit');
      const owner=item.content?.itemVariant==='httpItem'?operationOwner(item):undefined;
      const route=owner&&routes.get(owner.occurrence);
      if(route&&item.link!==item.routeSlug)throw Error('busyapi.documentation.route-owner');
      return {...item,...(route?{routeSlug:route,link:route}:{}),...(item.items?{items:visit(item.items,depth+1)}:{}),...(item.content?{content:{...item.content,
        ...(owner?{meta:{...item.content.meta,pointer:owner.pointer}}:{}),
        children:nodes(item.content.children,item.content.itemVariant==='schema',0,owner).values}}:{})};
    });
  };
  return Object.freeze({items:visit(items),render:source=>{
    const value=tokens.get(source);
    return value?value.source!==undefined?React.createElement(Source,{pointer:value.source}):value.entries?React.createElement(Parameters,{entries:value.entries}):React.createElement(Content,{...value,key:value.pointer}):undefined;
  }});
}
