// BusyAPI's read-only adapter for the exact Swagger UI distribution below.
// Selectors consume a supplied immutable presentation, never acquire resources.
// No vendor source is modified. Native resource isolation is a separate boundary.
import {presentationNode,presentationValue} from './graph_display.mjs';
import {documentationSourceFactory} from './source_actions.mjs';
import {swaggerLocatedContent} from './swagger_content.mjs';
export const swaggerAdapterIdentity = Object.freeze({
  producer: 'busyapi-swagger-read-only', version: '7',
  package: 'swagger-ui', packageVersion: '5.33.2',
  clientPackage:'swagger-client',clientPackageVersion:'3.38.2',
});

const prefix = '__busyapi_additional_';
const token = /^[-!#$%&'*+.^_`|~0-9A-Za-z]+$/;
export function additionalMethodIdentity(method) {
  if (typeof method !== 'string' || method.length > 256 || !token.test(method)) {
    throw Error('busyapi.documentation.method');
  }
  // Private view identity, not an authored method or operationId. Encoding
  // every byte avoids collisions with fixed methods and prefix-looking tokens.
  return prefix + [...method].map(value => value.charCodeAt(0).toString(16).padStart(2, '0')).join('');
}
export function additionalMethodToken(identity) {
  if (typeof identity !== 'string' || !identity.startsWith(prefix)) return undefined;
  const encoded = identity.slice(prefix.length);
  if (!encoded.length || encoded.length > 512 || encoded.length % 2 || !/^[0-9a-f]+$/.test(encoded)) return undefined;
  const method = encoded.replace(/../g, value => String.fromCharCode(Number.parseInt(value, 16)));
  return token.test(method) ? method : undefined;
}

const denied = () => { throw Error('busyapi.documentation.read-only'); };
const hidden = () => null;
const operationKey = operation => JSON.stringify(operation.get('specPath')?.toJS?.() ?? [operation.get('path'), operation.get('method')]);

export function busyApiSwaggerPlugin(system) {
  if (!system?.Im?.fromJS || !system?.React?.createElement) throw Error('busyapi.documentation.plugin-api');
  const resolveDocument = system.fn.resolveSubtree;
  if(typeof resolveDocument!=='function')throw Error('busyapi.documentation.plugin-api');
  let resolvedInput, resolvedBaseDoc, resolvedStrategies, resolvedDocument;
  const ExampleContext=system.React.createContext(null);
  const located=swaggerLocatedContent(system,Source);
  let sourceFactory,SourceControl;
  const pointer = parts => parts.length?'/'+parts.map(value=>String(value).replaceAll('~','~0').replaceAll('/','~1')).join('/'):'';
  function Source(props) {
    // Swagger registers plugins before applying the caller's configuration.
    // Bind only when the mounted component reads the captured configuration.
    const factory=system.getConfigs().busyApiSourceFactory;
    if(factory!==sourceFactory){sourceFactory=factory;SourceControl=factory?.(system.React);}
    return SourceControl?system.React.createElement(SourceControl,props):null;
  }
  function ExactValue({value}) {
    const [page,setPage]=system.React.useState(0), labels=system.getConfigs().busyApiLabels;
    const text=value.name==='serializedValue'?value.text:value.raw,size=8192,pages=Math.max(1,Math.ceil(text.length/size));
    const selected=Math.min(page,pages-1);
    let start=selected*size,end=Math.min(text.length,(selected+1)*size);
    if(start&&/[\uDC00-\uDFFF]/u.test(text[start])&&/[\uD800-\uDBFF]/u.test(text[start-1]))start--;
    if(end<text.length&&/[\uDC00-\uDFFF]/u.test(text[end])&&/[\uD800-\uDBFF]/u.test(text[end-1]))end--;
    return system.React.createElement('div',null,
      system.React.createElement(Source,{pointer:value.source.pointer,role:'field'}),
      system.React.createElement('pre',{className:'example'},system.React.createElement('code',{'data-busyapi-authored-value':value.source.pointer},text.slice(start,end))),
      ...(pages>1?[system.React.createElement('div',{key:'pages'},
        system.React.createElement('button',{type:'button','aria-label':labels.previousPage,disabled:selected===0,onClick:()=>setPage(selected-1)},'‹'),
        system.React.createElement('span',{'aria-live':'polite'},labels.page(selected+1,pages)),
        system.React.createElement('button',{type:'button','aria-label':labels.nextPage,disabled:selected+1===pages,onClick:()=>setPage(selected+1)},'›'))]:[]));
  }
  function exampleValue(props,context) {
    const presentation=system.getConfigs().busyApiPresentation(),parts=props.specPath?.toArray?.()??[];
    let media=parts.at(-1)==='schema'||parts.at(-1)==='itemSchema'?presentationNode(presentation,pointer(parts.slice(0,-1))):undefined;
    if(!media&&context?.getMedia?.())media=presentationNode(presentation,pointer([...(context.path??[]),'content',context.getMedia()]));
    if(media?.kind!=='media')return undefined;
    const examples=presentationNode(presentation,media.pointer+'/examples');
    if(examples) {
      const key=context?.selectedKey&&Object.hasOwn(examples.value,context.selectedKey)?context.selectedKey:Object.keys(examples.value)[0];
      if(key!==undefined) {
        const name=examples.pointer+'/'+String(key).replaceAll('~','~0').replaceAll('/','~1');
        for(const field of presentation.spec.openapi?.startsWith('3.2.')?['dataValue','serializedValue','value']:['value']) {
          const value=presentationValue(presentation,name+'/'+field);
          if(value)return value;
        }
      }
      return undefined;
    }
    return presentationValue(presentation,media.pointer+'/example');
  }
  function MediaFallback({context}) {
    const presentation=system.getConfigs().busyApiPresentation(),mediaName=context.getMedia();
    if(!mediaName)return null;
    const media=presentationNode(presentation,pointer([...context.path,'content',mediaName]));
    if(media?.kind!=='media')return null;
    const schema=presentationNode(presentation,media.pointer+'/schema');
    const itemSchema=presentationNode(presentation,media.pointer+'/itemSchema');
    if(schema&&typeof schema.value!=='boolean'&&!itemSchema)return null;
    const value=exampleValue({specPath:system.Im.fromJS([])},context);
    return system.React.createElement('div',{'data-busyapi-media-fallback':media.pointer},
      ...(schema&&typeof schema.value==='boolean'?[system.React.createElement('code',{key:'schema','data-busyapi-boolean-schema':String(schema.value),'data-busyapi-schema-source':schema.source.pointer},'schema: '+String(schema.value))]:[]),
      ...(itemSchema?[system.React.createElement('section',{key:'itemSchema'},system.React.createElement('code',null,'itemSchema'),
        system.React.createElement(system.getComponent('Model'),{specPath:system.Im.fromJS([...context.path,'content',mediaName,'itemSchema'])}))]:[]),
      ...(value&&(!schema||typeof schema.value==='boolean')?[system.React.createElement(ExactValue,{value,key:presentation.snapshot+'#'+value.source.pointer})]:[]));
  }
  const fail = code => {
    const error=Error(code);
    system.getConfigs().uncaughtExceptionHandler(error);
    throw error;
  };
  let pathsSnapshot, operationSnapshot, taggedBase, taggedAdditional, taggedResult;
  const additional = () => {
    const paths = system.specSelectors.paths();
    if (paths === pathsSnapshot && operationSnapshot) return operationSnapshot;
    const operations = [];
    paths?.forEach((item, path) => item.get?.('additionalOperations')?.forEach?.((operation, method) => {
      if (!operation?.get) return;
      operations.push({path, method, identity: additionalMethodIdentity(method), operation,
        specPath: ['paths', path, 'additionalOperations', method]});
    }));
    if (operations.length > 20000) throw Error('busyapi.documentation.operation-limit');
    pathsSnapshot = paths; operationSnapshot = operations;
    return operations;
  };
  return {
    fn: {
      fetch: denied, execute: denied,
      // Samples are source data, not inferred payloads or realistic-looking
      // credentials. Skip the upstream generator/serialization work entirely;
      // model controls below receive exact captured values when authored.
      getSampleSchema: () => undefined,
      // The pinned client can resolve a document pointer against an already
      // extracted operation instead of the supplied document. Resolve the
      // graph-addressed display once against its complete immutable input and
      // select requested subtrees afterwards. This is the upstream supported
      // resolver API, not another URI resolver or a filesystem/network loader.
      resolveSubtree: async (_partial, path, options) => {
        const input = system.specSelectors.specJson();
        // Display-document identity is independent of the native page's custom
        // transport URI (and of a relocated offline HTML entry). Supply the
        // exact owner-selected identity through the client's supported baseDoc
        // API. It is an in-memory lookup key, never retrieval permission.
        const baseDoc=system.getConfigs().busyApiPresentation().displayUri;
        const strategies=system.getConfigs().busyApiResolveStrategies;
        if(input!==resolvedInput||baseDoc!==resolvedBaseDoc||strategies!==resolvedStrategies) {
          resolvedInput=input;resolvedBaseDoc=baseDoc;resolvedStrategies=strategies;
          resolvedDocument=Promise.resolve().then(()=>resolveDocument(input.toJS(), [], {...options,...(strategies?{strategies}:{}),baseDoc,requestInterceptor:denied}));
        }
        let result;
        try {result=await resolvedDocument;}catch {return fail('busyapi.documentation.resolver-failed');}
        if(input!==system.specSelectors.specJson()||baseDoc!==system.getConfigs().busyApiPresentation().displayUri||strategies!==system.getConfigs().busyApiResolveStrategies)return fail('busyapi.documentation.stale');
        if(!result?.spec||(result.spec.openapi!==input.get('openapi')||result.spec.swagger!==input.get('swagger'))||result.errors!==undefined&&!Array.isArray(result.errors)||result.errors?.length)
          return fail('busyapi.documentation.resolver-failed');
        let value=result.spec;
        for(const part of path) {
          if(value===null||typeof value!=='object'||!Object.hasOwn(value,part)) {
            // UI components also request absent optional collections. Absence
            // must be proved against the captured input, not inferred from a
            // resolver failure or a vanished authored target.
            if(!input.hasIn(path))return {...result,spec:undefined};
            return fail('busyapi.documentation.target');
          }
          value=value[part];
        }
        return {...result,spec:value};
      },
    },
    components: {
      // Remove controls as well as disabling actions. These exact registered
      // names are qualified against 5.33.2, not a promise of future compatibility.
      authorizeBtn: hidden, authorizationPopup: hidden, authorizeOperationBtn: hidden,
      TryItOutButton: hidden, Execute: hidden,
      // Safe text is an allowed description presentation. Never give authored
      // Markdown/HTML the ability to request images or install event handlers.
      Markdown: props => system.React.createElement('span', {style: {whiteSpace: 'pre-wrap'}}, typeof props.source === 'string' ? props.source : ''),
    },
    wrapComponents: {
      ...located,
      InfoContainer: Original => props => system.React.createElement(system.React.Fragment,null,
        system.React.createElement(Original,props),system.React.createElement(Source,{pointer:''})),
      operation: Original => props => system.React.createElement('div',{'data-busyapi-operation-source':pointer(props.specPath?.toArray?.()??[])},
        system.React.createElement(Original,props),system.React.createElement(Source,{pointer:pointer(props.specPath?.toArray?.()??[])})),
      contentType: Original => function ObservedContentType(props) {
        const context=system.React.useContext(ExampleContext);
        system.React.useLayoutEffect(()=>{if(typeof props.value==='string')context?.onMedia?.(props.value);},[context?.onMedia,props.value]);
        return system.React.createElement(Original,props);
      },
      response: Original => located.response(function ResponseWithExactExamples(props) {
        const [media,setMedia]=system.React.useState(null);
        const value={path:props.specPath?.toArray?.()??[],selectedKey:props.activeExamplesKey,getMedia:()=>media,onMedia:setMedia};
        // The upstream response component calls .toJS() on inline booleans.
        // Withhold that unsupported prop only from its presentation and render
        // the actual boolean alongside it. Neither source nor view API data is
        // converted to an empty object or rewritten.
        const response=props.response?.get('content')?.map?props.response.update('content',content=>content.map(item=>typeof item.get?.('schema')==='boolean'?item.delete('schema'):item)):props.response;
        return system.React.createElement(ExampleContext.Provider,{value},
          system.React.createElement(Original,{...props,response}),system.React.createElement(MediaFallback,{context:value}),
          system.React.createElement(Source,{pointer:pointer(value.path)}));
      }),
      modelExample: Original => function AuthoredModelExample(props) {
        const context=system.React.useContext(ExampleContext),value=exampleValue(props,context);
        // Use exact captured data, including false/zero/null/string values.
        // Never relabel an upstream generated/rounded sample as authored data.
        const example=value?system.React.createElement(ExactValue,{value,key:system.getConfigs().busyApiPresentation().snapshot+'#'+value.source.pointer}):null;
        return system.React.createElement(Original,{...props,example});
      },
      JSONSchema202012: Original => props => typeof props.schema==='boolean' ?
        system.React.createElement(system.React.Fragment,null,
          system.React.createElement(Original,props),
          system.React.createElement('code',{'data-busyapi-boolean-schema':String(props.schema)},String(props.schema))) :
        system.React.createElement(Original,props),
      OperationSummaryMethod: Original => props => {
        const method = additionalMethodToken(props.method);
        return method === undefined ? system.React.createElement(Original, props) :
          system.React.createElement('span', {className: 'opblock-summary-method', 'data-busyapi-additional-method': method}, method);
      },
    },
    statePlugins: {
      spec: {
        wrapActions: {execute: () => denied, executeRequest: () => denied},
        wrapSelectors: {
          // In the pinned System implementation, original is already bound to
          // state. Forwarding the wrapper's state again shifts path/method and
          // silently yields empty operations despite a working page banner.
          validOperationMethods: original => (_state, ...args) => [...new Set([...original(...args), ...additional().map(value => value.identity)])],
          selectSchemas: _original => () => {
            // The pinned upstream selector itself calls .toJS() on booleans;
            // invoking it first and repairing the result is already too late.
            const result = {};
            // Preserve false, not an empty map or missing definition. Swagger's
            // resolved subtree is a display projection, not schema evaluation.
            system.specSelectors.definitions()?.forEach?.((value, name) => { result[name] = value?.toJS?.() ?? value; });
            system.specSelectors.specResolvedSubtree(['components', 'schemas'])?.forEach?.((value, name) => { result[name] = value?.toJS?.() ?? value; });
            return result;
          },
          taggedOperations: original => (_state, ...args) => {
            let tags = original(...args);
            const operations = additional();
            if (tags === taggedBase && operations === taggedAdditional) return taggedResult;
            const base = tags;
            const seen = new Map();
            tags.forEach((tag, name) => seen.set(name, new Set(tag.get('operations').map(operationKey).toArray())));
            for (const value of operations) {
              const operation = system.Im.fromJS({path: value.path, method: value.identity,
                operation: value.operation, id: value.identity + '-' + value.path, specPath: value.specPath});
              const names = value.operation.get('tags')?.size ? value.operation.get('tags').toArray() : ['default'];
              for (const name of new Set(names)) {
                if (!tags.has(name)) tags = tags.set(name, system.Im.fromJS({tagDetails: {name}, operations: []}));
                const keys = seen.get(name) ?? new Set();
                if (!keys.has(operationKey(operation))) {
                  tags = tags.updateIn([name, 'operations'], values => values.push(operation));
                  keys.add(operationKey(operation)); seen.set(name, keys);
                }
              }
            }
            taggedBase = base; taggedAdditional = operations; taggedResult = tags;
            return tags;
          },
          operationWithMeta: original => (_state, path, method) => {
            const authored = additionalMethodToken(method);
            return authored === undefined ? original(path, method) :
              system.specSelectors.specJsonWithResolvedSubtrees().getIn(['paths', path, 'additionalOperations', authored]);
          },
        },
      },
      auth: {wrapActions: {
        authorize: () => denied, authorizeOauth2: () => denied,
        authorizeRequest: () => denied, authorizeApplication: () => denied,
        authorizeAccessCode: () => denied, authorizePassword: () => denied,
        preAuthorizeImplicit: () => denied, showDefinitions: () => denied,
      }},
    },
  };
}

export function readOnlySwaggerConfiguration(presentation, {onError,labels,sourceActions,onSource,resolveStrategies} = {}) {
  if(presentation?.representation!=='graph-addressed-display-only'||presentation.addresses!=='absolute-document'||!presentationNode(presentation,''))throw Error('busyapi.documentation.projection');
  const spec=presentation.spec;
  if (!spec || typeof spec !== 'object' || !(spec.swagger==='2.0'||/^3\.[012]\./.test(spec.openapi))) throw Error('busyapi.documentation.version');
  if (typeof onError !== 'function') throw Error('busyapi.documentation.error-owner');
  if(typeof labels?.previousPage!=='string'||typeof labels.nextPage!=='string'||typeof labels.page!=='function')throw Error('busyapi.documentation.labels');
  // Validate the table even before plugin installation. No source field from
  // the page becomes a path; callbacks carry only a captured native index.
  const Source=documentationSourceFactory(presentation,{sourceActions,onSource,labels});
  if(resolveStrategies!==undefined&&(!Array.isArray(resolveStrategies)||resolveStrategies.length<2||resolveStrategies.length>4||
      resolveStrategies.some((strategy,index)=>strategy?.name!==['openapi-3-2-apidom','openapi-3-1-apidom','openapi-3-0','openapi-2'][index]||['match','normalize','resolve'].some(name=>typeof strategy[name]!=='function'))))throw Error('busyapi.documentation.plugin-api');
  return {
    spec, url: '', urls: [], configUrl: null,busyApiPresentation:()=>presentation,busyApiLabels:labels,busyApiSourceFactory:Source,busyApiResolveStrategies:resolveStrategies===undefined?undefined:Object.freeze([...resolveStrategies]),
    plugins: [busyApiSwaggerPlugin],
    supportedSubmitMethods: [], tryItOutEnabled: false,
    validatorUrl: null, persistAuthorization: false,
    withCredentials: false, queryConfigEnabled: false,
    requestInterceptor: denied,
    // Swagger catches wrapped action failures and otherwise merely logs them.
    // A native/export owner must observe the failure, never an empty success.
    // Do not forward authored source/credentials through routine error output.
    uncaughtExceptionHandler: error => onError(['read-only','stale','target','resolver-failed'].some(code=>error?.message==='busyapi.documentation.'+code) ? error.message : 'busyapi.documentation.renderer-failed'),
    showMutatedRequest: false, displayRequestDuration: false,
    defaultModelRendering: 'model', defaultModelsExpandDepth: 2,
    defaultModelExpandDepth: 4,
    docExpansion: 'full',
  };
}
