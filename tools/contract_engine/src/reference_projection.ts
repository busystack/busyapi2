import {createGraph, Resource} from './engine';
import {children} from './contexts';
import {swaggerServers} from './swagger_operation';
import {fieldsForScope,richTextField} from './authoring';
import {escape, segments, SourceError} from './document';
import {ParameterSemantics} from './parameter_semantics';
import {GraphTarget,ReferenceGraph,referenceMarkdownBase} from './reference_graph';
import {createHash} from 'node:crypto';
import {isNativeFamily} from './specification';
import {ignoresRequestBody} from './operation_semantics';

// Hash exact UTF-16 units so even a preserved lone surrogate cannot collapse
// into the UTF-8 replacement character. This is a view ID, not a resource URI.
const operationNavigationId=(root:string,occurrence:string)=>createHash('sha256').update(Buffer.from(occurrence.slice(root.length),'utf16le')).digest('hex');

function operationEffective(graph:ReferenceGraph,resource:string,pointer:string,path:GraphTarget|undefined,located:(resource:string,pointer:string)=>any,parameterOffset=0,all=false,parameterSemantics=new ParameterSemantics(graph),method?:string) {
    const doc=graph.docs.get(resource)!,node=doc.dataNode(pointer)!,root=graph.docs.get(graph.root)!,effective:any[]=[];
    if(!path){
        const parts=segments(pointer);parts.splice(parts.at(-2)==='additionalOperations'?-2:-1);
        const parent=parts.length?'/'+parts.map(escape).join('/'):'';
        const scope=graph.scopes.get(resource+'#'+parent);if(scope?.kind==='path-item')path=scope;
    }
    const view=path?graph.pathItem(path):undefined;
    for(const name of ['servers','security']) {
        if(name==='servers'&&graph.scope(resource,pointer).family==='2.0') {
            effective.push({name,origin:'root',inherited:true,complete:true,source:located(root.id,''),default:swaggerServers(graph,resource,pointer,located).map(server=>({url:server.url}))});
            continue;
        }
        const local=node.children.has(name)?{resource,pointer:pointer+'/'+name,origin:'operation'}:undefined;
        const inherited=name==='servers'?view?.fields.get(name):undefined;
        const unknown=!local&&name==='servers'&&view&&!inherited&&(!view.chainComplete||view.conflicts.includes(name));
        const chosen=local??(inherited?{...inherited,origin:'path-item'}:undefined)??(!unknown&&root.root.children.has(name)?{resource:root.id,pointer:'/'+name,origin:'root'}:undefined);
        effective.push({name,origin:unknown?'unresolved':chosen?.origin??'specification',inherited:chosen?.origin!=='operation',complete:!unknown&&(name!=='servers'||!!local||!view||view.chainComplete),
            ...(chosen?{source:located(chosen.resource,chosen.pointer)}:{}),...(!chosen&&!unknown&&name==='servers'?{default:[{url:'/'}]}:{})});
    }
    const parameters=parameterSemantics.operation(resource,pointer,path);
    const visible=parameters.visible.map(parameter=>({...parameter,source:located(parameter.source.resource,parameter.source.pointer),
        ...(parameter.definition?{definition:located(parameter.definition.resource,parameter.definition.pointer)}:{})}));
    const offset=all?0:Math.min(Math.max(0,Number.isSafeInteger(parameterOffset)?parameterOffset:0),Math.max(0,(Math.ceil(visible.length/50)-1)*50));
    effective.push({name:'parameters',entries:all?visible:visible.slice(offset,offset+50),count:visible.length,offset,
        complete:parameters.complete,invalid:!parameters.valid,overriddenCount:parameters.entries.length-visible.length});
    if(method&&node.children.has('requestBody')&&ignoresRequestBody(graph.scope(resource,pointer).family,method.toUpperCase()))
        effective.push({name:'requestBody',origin:'operation',inherited:false,complete:true,ignored:true,policy:'oas30-http-method',method:method.toUpperCase(),source:located(resource,pointer+'/requestBody')});
    return effective;
}

// A read-only, located projection for native Reference and offline documents.
// It never bundles, evaluates a schema, reads a file, or follows payload keys.
// Every child is requested lazily; reference targets remain explicit links.
export function referencePage(input: any, context?:ReturnType<typeof createGraph>) {
    const {docs, graph} = context??createGraph(input);
    const read=(resource:string,pointer:string)=>{
        const physical=docs.get(resource)?.dataNode(pointer);
        // Read-only occurrence coordinates, not newly editable virtual nodes.
        return physical?{...physical,pointer}:undefined;
    };
    const doc = docs.get(input.resource), node = read(input.resource,input.pointer);
    if (!doc || !node) throw new SourceError('reference.target', 'The documentation occurrence is absent');
    const scope = graph.scopes.get(doc.id + '#' + node.pointer);
    const family = graph.scope(doc.id, node.pointer).family;
    const kind = input.data === true || !isNativeFamily(family) ? 'data' : scope?.kind ?? 'data';
    const generations = new Map(input.resources.map((r: Resource) => [r.id, r.generation]));
    const located = (resource: string, pointer: string) => {
        const source=docs.get(resource),target=source?.dataNode(pointer);
        if (!target) throw new SourceError('reference.target', 'The documentation source is absent');
        let occurrence=pointer;
        while(occurrence&&!source!.nodes.has(occurrence))occurrence=occurrence.slice(0,occurrence.lastIndexOf('/'));
        return {root: input.root, resource, pointer, markdownBase:referenceMarkdownBase(graph,resource,pointer), generation: generations.get(resource), range: target.range, data:false,
            ...(target.pointer!==pointer?{physicalPointer:target.pointer,occurrenceRange:source!.nodes.get(occurrence)!.range}:{}),
            kind: graph.scopes.get(resource + '#' + pointer)?.kind ?? 'data', syntaxSafe: source!.dataSyntaxSafe(pointer)};
    };
    const fieldDefinitions = fieldsForScope(graph,{...graph.scope(doc.id,node.pointer),kind},node.value);
    const referenceIndex = new Map(graph.references.map(ref => [JSON.stringify([ref.resource, ref.pointer, ref.keyword]), ref]));
    const definitions = new Map(fieldDefinitions.map(field => [field.name, field]));
    // Do not use String(number), JSON.stringify(parsed values), or ?? to select
    // examples: source numeric lexemes, null, false and zero must survive.
    const excerpt = (pointer: string, start: number, maximum = 16384) => {
        const target = doc.dataNode(pointer)!, value = target.value,authored=doc.nodes.get(pointer);
        const alias = authored?.alias!==undefined;
        const text = alias ? doc.text.slice(...authored.range) : typeof value === 'string' ? value : doc.dataJson(pointer);
        let offset = Math.min(Math.max(0, Number.isSafeInteger(start) ? start : 0), text.length);
        if (offset && /[\uDC00-\uDFFF]/u.test(text[offset]) && /[\uD800-\uDBFF]/u.test(text[offset - 1])) offset--;
        let end = Math.min(text.length, offset + maximum);
        if (end < text.length && /[\uD800-\uDBFF]/u.test(text[end - 1])) end--;
        return {text: text.slice(offset, end), textOffset: offset, textEnd: end, textLength: text.length,
            representation: alias ? 'yaml-source' : typeof value === 'string' ? 'text' : 'json'};
    };
    const offset = Math.min(Math.max(0, Number.isSafeInteger(input.offset) ? input.offset : 0), Math.max(0, (Math.ceil(node.children.size / 50) - 1) * 50));
    const referenceData = kind === 'data' || graph.referenceObject(node.value,{...graph.scope(doc.id,node.pointer),kind});
    const entries = [...node.children].slice(offset, offset + 50).map(([name, child]) => {
        const definition = definitions.get(name);
        // The whole containing occurrence, not an isolated key/value, decides
        // whether this child is semantic. In particular a Callback Reference
        // Object's $ref and ignored siblings are not callback Path Items.
        // Determine the containing Reference Object once, then classify only
        // this bounded page. Enumerating a whole large property map for each
        // 50-row request would defeat the native lazy view.
        const context = referenceData ? undefined : children({[name]:child.value},kind,family,node.value).find(([key])=>key===name)?.[2];
        const schema = kind === 'schema-map' && node.pointer.endsWith('/properties') ? doc.dataNode(node.pointer.slice(0, -11)) : undefined;
        const pointer=node.pointer+'/'+escape(name),value=read(doc.id,pointer)!;
        return {name, ...located(doc.id, pointer), kind:context??'data', data:!context, nodeKind: value.kind, count: value.children.size,
            defined: !!definition, contextual: !!context, extension: name.startsWith('x-'),
            richText:richTextField(kind,family,node.value,name,segments(node.pointer).at(-1),graph.allowsReference({...graph.scope(doc.id,node.pointer),kind}))&&doc.nodes.get(pointer)?.alias===undefined,
            ...(schema ? {required: Array.isArray(schema.value?.required) && schema.value.required.includes(name)} : {}),
            ...(definition && Object.hasOwn(definition, 'effectiveDefault') ? {effectiveDefault: definition.effectiveDefault} : {}),
            ...(!['object','array'].includes(value.kind) ? excerpt(pointer, 0, 240) : {}),
        };
    });
    const visibleNames = new Set(entries.map(entry => entry.name));
    const references = graph.references.filter(ref => kind !== 'data' && ref.resource === doc.id && ref.pointer === node.pointer && (visibleNames.has(ref.keyword) || ['$ref','$dynamicRef'].includes(ref.keyword))).map(ref => ({...ref,
        source: located(ref.resource, ref.pointer + '/' + escape(ref.keyword)),
        ...(ref.resolution === 'resolved' ? {target: located(ref.targetResource!, ref.targetPointer!)} : {}),
        ...(ref.dynamic ? {dynamic: {...ref.dynamic, candidates: ref.dynamic.candidates.map(target => located(target.resource, target.pointer))}} : {}),
    }));
    const defaults = fieldDefinitions.filter(field => !node.children.has(field.name) && Object.hasOwn(field, 'effectiveDefault')).map(field => ({name: field.name, value: field.effectiveDefault}));
    const interpretation = kind === 'schema' ? 'schema-applicators' : kind === 'path-item' ? 'path-item' :
        graph.allowsReference({...graph.scope(doc.id,node.pointer),kind}) && typeof node.value?.$ref === 'string' ? 'reference-object' : kind === 'data' ? 'data' : 'inline';
    const issues = kind === 'data' ? [] : graph.issues.filter(issue => issue.resource === doc.id && (issue.pointer === node.pointer || issue.pointer.startsWith(node.pointer + '/')));
    const previews: any[] = [];
    let previewsLimited = false;
    let previewTextBudget = 16384;
    const preview = (label: string, name: string, resource: string, pointer: string, direction: string, depth: number, data = false) => {
        if (previews.length >= 50) {previewsLimited = true;return;}
        const source = docs.get(resource)!, value = read(resource,pointer)!,authored=source.nodes.get(pointer);
        const alias = authored?.alias!==undefined;
        const text = data ? alias ? source.text.slice(...authored.range) : typeof value.value === 'string' ? value.value :
            value.range[1] - value.range[0] <= 4096 ? source.dataJson(pointer) : source.text.slice(value.range[0], value.range[0] + 4096) : undefined;
        let end = Math.min(text?.length ?? 0, 4096, previewTextBudget);
        if (text && /[\uD800-\uDBFF]/u.test(text[end - 1])) end--;
        previewTextBudget-=end;
        previews.push({label, name, source:{...located(resource,pointer),data}, direction, depth,richText:label==='description'&&!alias,
            ...(text !== undefined ? {text:text.slice(0,end), limited: end < text.length || value.range[1]-value.range[0] > 4096,
                representation:alias ? 'yaml-source' : typeof value.value === 'string' ? 'text' : value.range[1]-value.range[0] <= 4096 ? 'json' : source.format} : {})});
    };
    const follow = (resource: string, pointer: string, kind: string) => {
        const visited = new Set<string>(), chain: {resource:string;pointer:string}[] = [];
        for(let depth=0;depth<32;depth++) {
            const key=JSON.stringify([resource,pointer]);
            if(visited.has(key))return;
            visited.add(key);chain.push({resource,pointer});
            const n=read(resource,pointer)!;
            if(typeof n.value?.$ref!=='string' || !graph.allowsReference({...graph.scope(resource,pointer),kind}))return {resource,pointer,chain};
            const edge=referenceIndex.get(JSON.stringify([resource,pointer,'$ref']));
            if(!edge || edge.resolution!=='resolved')return;
            resource=edge.targetResource!;pointer=edge.targetPointer!;
        }
    };
    const schemaPreview = (resource:string,pointer:string,direction:string,depth:number) => {
        preview('schema',segments(pointer).at(-1)!,resource,pointer,direction,depth);
        const schema = read(resource,pointer)!;
        if(typeof schema.value==='boolean')preview('value','',resource,pointer,direction,depth+1,true);
        if(schema.children.has('type')) preview('value','type',resource,pointer+'/type',direction,depth+1,true);
        const properties = schema.children.get('properties');
        if(properties?.kind === 'object') {
            for(const [name] of [...properties.children].slice(0,8)) preview('property',name,resource,pointer+'/properties/'+escape(name),direction,depth+1);
            if(properties.children.size > 8) preview('properties','properties',resource,pointer+'/properties',direction,depth+1);
        }
        for(const name of ['$ref','$dynamicRef','allOf','anyOf','oneOf','not','if','then','else'])
            if(schema.children.has(name))preview('constraint',name,resource,pointer+'/'+escape(name),direction,depth+1);
    };
    const mediaPreview = (resource:string,pointer:string,direction:string,depth:number) => {
        const collection = read(resource,pointer)!;
        if(collection.kind !== 'object')return;
        for(const [name, occurrence] of collection.children) {
            if(previews.length>=50) {previewsLimited=true;return;}
            const mediaPointer=pointer+'/'+escape(name);
            preview('media',name,resource,mediaPointer,direction,depth);
            const media = follow(resource,mediaPointer,'media');if(!media)continue;
            const object = read(media.resource,media.pointer)!;
            for(const key of ['schema',...(graph.scope(media.resource,media.pointer).family==='3.2'?['itemSchema']:[])])
                if(object.children.has(key))schemaPreview(media.resource,media.pointer+'/'+key,direction,depth+1);
            if(object.children.has('example'))preview('example','example',media.resource,media.pointer+'/example',direction,depth+1,true);
            const examples=object.children.get('examples');
            if(examples?.kind==='object')for(const [name,child] of examples.children) {
                if(previews.length>=50) {previewsLimited=true;return;}
                const examplePointer=media.pointer+'/examples/'+escape(name),example=follow(media.resource,examplePointer,'example');
                preview('example',name,media.resource,examplePointer,direction,depth+1);
                if(example)for(const key of ['value',...(graph.scope(example.resource,example.pointer).family==='3.2'?['dataValue','serializedValue']:[])])
                    if(read(example.resource,example.pointer)!.children.has(key)) preview('value',key,example.resource,example.pointer+'/'+key,direction,depth+2,true);
            }
        }
    };
    const bodyPreview = (resource:string,pointer:string,name:string,kind:string,direction:string) => {
        preview(kind,name,resource,pointer,direction,0);
        const body=follow(resource,pointer,kind);if(!body)return;
        // Reference Object annotations override presentation only. Content,
        // headers and schemas still belong to the actual definition.
        for(const entry of body.chain) {
            const description=read(entry.resource,entry.pointer)!.children.get('description');
            if(description && typeof description.value==='string') {preview('description','description',entry.resource,entry.pointer+'/description',direction,1,true);break;}
        }
        const object=read(body.resource,body.pointer)!;
        if(object.children.has('content'))mediaPreview(body.resource,body.pointer+'/content',direction,1);
        for(const name of ['headers','links'])if(object.children.has(name))preview(name,name,body.resource,body.pointer+'/'+name,direction,1);
    };
    if(kind==='operation' && node.kind==='object') {
        if(node.children.has('requestBody'))bodyPreview(doc.id,node.pointer+'/requestBody','requestBody','request-body','request');
        const responses=node.children.get('responses');
        if(responses?.kind==='object')for(const [status,response] of responses.children) {
            if(status.startsWith('x-'))continue;
            if(previews.length>=50){previewsLimited=true;break;}
            bodyPreview(doc.id,node.pointer+'/responses/'+escape(status),status,'response','response');
        }
    }
    let effective: any[] = [];
    const contexts=kind==='operation'?graph.operationContexts(doc.id,node.pointer):[];
    const selected=input.definitionOnly===true?undefined:input.occurrence===undefined?(contexts.length===1?contexts[0]:undefined):contexts.find(context=>context.occurrence===input.occurrence);
    const contextOffset=Math.min(Math.max(0,Number.isSafeInteger(input.contextOffset)?input.contextOffset:0),Math.max(0,(Math.ceil(contexts.length/50)-1)*50));
    if(input.occurrence!==undefined&&!selected&&input.definitionOnly!==true)throw new SourceError('reference.occurrence','The requested operation occurrence does not select this physical source');
    if (kind === 'operation' && node.value && node.kind === 'object') {
        if(selected)effective=operationEffective(graph,doc.id,node.pointer,selected.pathItem,located,input.parameterOffset,false,undefined,selected.method);
    }
    const parentPointer=node.pointer.slice(0,node.pointer.lastIndexOf('/')),parent=graph.scopes.get(doc.id+'#'+parentPointer);
    const richText=input.data!==true&&doc.nodes.get(node.pointer)?.alias===undefined&&!!parent&&richTextField(parent.kind,family,doc.dataNode(parentPointer)?.value,segments(node.pointer).at(-1)!,segments(parentPointer).at(-1),graph.allowsReference(parent));
    return {version: 1, snapshot: input.snapshot, family, ...located(doc.id, node.pointer), kind, data:kind==='data', nodeKind: node.kind,richText,
        interpretation, references, defaults, entries, offset, count: node.children.size, issues:issues.slice(0,50).map(issue => ({...issue, source:located(issue.resource,issue.pointer)})), issueCount:issues.length, effective, previews, previewsLimited,
        ...(kind==='operation'?{occurrence:selected?.occurrence??null,contextSelectionRequired:contexts.length>0&&!selected,
            selectedContext:selected?{occurrence:selected.occurrence,navigationId:operationNavigationId(input.root,selected.occurrence),path:selected.path,method:selected.method,customMethod:selected.customMethod===true,role:selected.role,pathItem:located(selected.pathItem.resource,selected.pathItem.pointer)}:null,
            contextCount:contexts.length,contextOffset,contexts:contexts.slice(contextOffset,contextOffset+50).map(context=>({occurrence:context.occurrence,navigationId:operationNavigationId(input.root,context.occurrence),path:context.path,method:context.method,customMethod:context.customMethod===true,role:context.role,pathItem:located(context.pathItem.resource,context.pathItem.pointer)}))}:{}),
        complete:doc.dataSyntaxSafe(node.pointer) && issues.length === 0 && references.every(ref => ref.resolution === 'resolved') && effective.every(field=>field.complete!==false&&!field.invalid),
        ...(!['object','array'].includes(node.kind) ? excerpt(node.pointer, input.textOffset) : {}),
        ...(kind === 'schema' && typeof node.value === 'boolean' ? {boolean: node.value} : {}),
    };
}

/** Complete offline projection of the same located Reference graph. This is
 * neither a parser nor a bundle: authored resources and recursive/reference
 * occurrences remain separate linked sections. Data values are exact CST JSON
 * text, never JSON.stringify(parsed numbers). No resource is acquired here. */
export function referenceDocument(input:any) {
    const context=createGraph(input),{docs,graph,family}=context;
    if(graph.issues.length||[...docs.values()].some(doc=>doc.issues.length))
        throw new SourceError('documentation.incomplete','Documentation requires a coherent, unambiguous approved source graph');
    const generations=new Map((input.resources as Resource[]).map(resource=>[resource.id,resource.generation]));
    const location=(resource:string,pointer:string)=>{
        const doc=docs.get(resource)!,physical=doc.dataNode(pointer);
        if(!physical)throw new SourceError('documentation.source','A documentation source occurrence is unavailable');
        let occurrence=pointer;
        while(occurrence&&!doc.nodes.has(occurrence))occurrence=occurrence.slice(0,occurrence.lastIndexOf('/'));
        return {resource,pointer,markdownBase:referenceMarkdownBase(graph,resource,pointer),generation:generations.get(resource),range:physical.range,
            ...(physical.pointer!==pointer?{physicalPointer:physical.pointer,occurrenceRange:doc.nodes.get(occurrence)!.range}:{})};
    };
    const referenceIndex=new Map<string,typeof graph.references>();
    const incoming=new Map<string,typeof graph.references>();
    for(const reference of graph.references) {
        const key=JSON.stringify([reference.resource,reference.pointer]),values=referenceIndex.get(key)??[];
        values.push(reference);referenceIndex.set(key,values);
        const target=JSON.stringify([reference.targetResource,reference.targetPointer]),usages=incoming.get(target)??[];
        usages.push(reference);incoming.set(target,usages);
    }
    const scopes=[...graph.scopes.values()].sort((a,b)=>a.resource<b.resource?-1:a.resource>b.resource?1:
        docs.get(a.resource)!.dataNode(a.pointer)!.range[0]-docs.get(b.resource)!.dataNode(b.pointer)!.range[0]||a.pointer.length-b.pointer.length);
    if(scopes.length>40000)throw new SourceError('limit.documentation.sections','Documentation exceeds 40000 semantic sections');
    let bytes=0,fields=0;
    const retain=(text:string)=>{
        bytes+=Buffer.byteLength(text);
        if(bytes>32*1024*1024)throw new SourceError('limit.documentation.text','Documentation exceeds its 32 MiB text limit');
        return text;
    };
    const parameterSemantics=new ParameterSemantics(graph);
    const sections=scopes.map(scope=>{
        const doc=docs.get(scope.resource)!,node=doc.dataNode(scope.pointer)!;
        const family=scope.family;
        const definitions=fieldsForScope(graph,scope,node.value);
        const contexts=new Map((graph.referenceObject(node.value,scope)?[]:children(node.value,scope.kind,family)).map(([name,,kind])=>[name,kind]));
        const entries=[...node.children].map(([name,physical])=>{
            if(++fields>200000)throw new SourceError('limit.documentation.fields','Documentation exceeds 200000 fields');
            const pointer=scope.pointer+'/'+escape(name),child=doc.dataNode(pointer)!;
            // A non-OAS retrieval document may be a container of fragment
            // definitions. Its child kinds come from actual graph consumers,
            // not an invented OAS root field or a literal payload. This mirrors
            // the graph's literal-container boundary; extension/example fields
            // in real specification objects remain data even when referenced.
            const kind=contexts.get(name)??(scope.kind==='root'&&!graph.specifications.has(doc.id)?
                graph.scopes.get(scope.resource+'#'+pointer)?.kind:undefined);
            const target=kind!==undefined&&graph.scopes.has(scope.resource+'#'+pointer);
            return {name,source:location(scope.resource,pointer),kind:kind??'data',
                ...(target?{target:location(scope.resource,pointer)}:
                    {text:retain(typeof child.value==='string'?child.value:doc.dataJson(pointer)),
                     representation:typeof child.value==='string'?'text':'json',
                     richText:richTextField(scope.kind,family,node.value,name,segments(scope.pointer).at(-1),graph.allowsReference(scope))}),
            };
        });
        const references=(referenceIndex.get(JSON.stringify([scope.resource,scope.pointer]))??[]).map(reference=>({
            keyword:reference.keyword,value:reference.value,source:location(scope.resource,scope.pointer+'/'+escape(reference.keyword)),
            ...(reference.connection?{connection:reference.connection}:{}),
            target:location(reference.targetResource!,reference.targetPointer!),
            ...(reference.dynamic?{dynamic:{anchor:reference.dynamic.anchor,candidates:reference.dynamic.candidates.map(target=>location(target.resource,target.pointer))}}:{}),
        }));
        // The native page supplies effective declarations through the same
        // parameter/ownership implementation. Read every page, not previews.
        const operationContexts=scope.kind==='operation'?graph.operationContexts(scope.resource,scope.pointer).map(occurrence=>({
            occurrence:occurrence.occurrence,path:occurrence.path,method:occurrence.method,customMethod:occurrence.customMethod===true,role:occurrence.role,
            navigationId:operationNavigationId(input.root,occurrence.occurrence),
            pathItem:location(occurrence.pathItem.resource,occurrence.pathItem.pointer),
            effective:operationEffective(graph,scope.resource,scope.pointer,occurrence.pathItem,location,0,true,parameterSemantics,occurrence.method),
        })):[];
        const effective=scope.kind==='operation'&&operationContexts.length===1?operationContexts[0].effective:[];
        const usages=(incoming.get(JSON.stringify([scope.resource,scope.pointer]))??[]).map(reference=>({
            source:location(reference.resource,reference.pointer),keyword:reference.keyword,
            ...(reference.connection?{connection:reference.connection}:{}),dynamic:!!reference.dynamic,
        }));
        return {source:location(scope.resource,scope.pointer),kind:scope.kind,base:scope.base,dialect:scope.dialect,usages,...(scope.kind==='operation'?{contexts:operationContexts}:{}),
            retrieval:graph.retrievals.get(scope.resource),entries,references,effective,
            defaults:definitions.filter(field=>!node.children.has(field.name)&&Object.hasOwn(field,'effectiveDefault')).map(field=>({name:field.name,value:field.effectiveDefault})),
            ...(!['object','array'].includes(node.kind)?{text:retain(doc.dataJson(scope.pointer)),representation:'json'}:{}),
        };
    });
    const result={version:1,producer:'busyapi-native-reference',producerVersion:'1',snapshot:input.snapshot,root:input.root,family,complete:true,sections};
    if(Buffer.byteLength(JSON.stringify(result))>48*1024*1024)throw new SourceError('limit.documentation.projection','Documentation exceeds its bounded projection size');
    return result;
}
