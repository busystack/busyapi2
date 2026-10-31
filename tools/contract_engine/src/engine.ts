import {swaggerServerContextRevision,swaggerServerRelationships} from './swagger_servers';
import {swaggerSchemaRulesRevision} from './swagger_schema_artifact';
import {discriminatorContextRevision} from './discriminator_semantics';
import {multipartProjectionRevision} from './schema_reference_projection';
import { createHash } from 'node:crypto';
import { children, referenceKinds, standardOperationMethods } from './contexts';
import { ReferenceGraph, supportedSchemaDialect, referenceMarkdownContext, schemaRoleContextRevision } from './reference_graph';
import { fieldsFor, fieldsForScope, removableField, allowsExtensions, componentFamily, componentLocation, authoringFieldRevision } from './authoring';
import {sameSchemaValueForms, allowsSchemaValue} from './schema_value_forms';
import type {SchemaValueForms} from './schema_value_forms';
import { SourceDocument, SourceError, RawJsonValue, escape, segments, limits } from './document';
import {structuralEvaluator as ajv, structuralValidators as validators, structuralRevisions, structuralSchema} from './structural_schema';
import {specificationDeclaration, isNativeFamily, modernFamily, capabilitiesFor, dialectUriRevision} from './specification';
import {securityDesign, safeFinding} from './security_design';
import {schemaRoots,nestedSchemaBoundaries,schemaMetaView} from './schema_boundaries';
import {setDataSource} from './data_edit';
import {ParameterSemantics} from './parameter_semantics';
import {authoringRelationships} from './authoring_relationships';
import {serverContextRevision,serverRelationships} from './server_semantics';
import {restrictedSchemaIssues} from './restricted_schema';
import {securityRequirementIssues,securityRequirementValueRule} from './security_requirements';
import {formMediaIssues} from './form_semantics';
import {schemaInferenceSources} from './schema_inference';
import {mediaTypeIssues} from './media_validation';
import {documentUriRevision,documentUriRelationships} from './document_uris';
import {xmlContextRevision,xmlRelationships} from './xml_semantics';
import {collectionMemberNamePolicy,componentNamePolicy,reusableDefinitionPointer,responseStatusIssues,responseStatusNamePolicy,schemaDefinitionNamePolicy} from './member_names';
export const engineVersion = '0.1.0';
export const protocol = 1;
const versions = { engine: engineVersion, yaml: '2.9.0', ajv: '8.20.0', node: process.versions.node, openapiSchemas: structuralRevisions, authoringFieldRules:authoringFieldRevision, swaggerSchemaRules:swaggerSchemaRulesRevision, markdownContextRules: '2', xmlContextRules:xmlContextRevision, documentUriRules:documentUriRevision, dialectUriRules:dialectUriRevision, serverRules:serverContextRevision, swaggerServerRules:swaggerServerContextRevision, multipartRules:multipartProjectionRevision, discriminatorRules:discriminatorContextRevision, schemaRoleRules:schemaRoleContextRevision };
export type Resource = {
    id: string;
    text: string;
    generation: number;
    identity: string;
    aliases?: string[];
    hasBom?: boolean;
};
const parsed = new Map<string, {
    doc: SourceDocument;
    cost: number;
}>();
let parsedCost = 0;
function parseResource(r: Resource): SourceDocument {
    const key = r.id + ':' + createHash('sha256').update(r.text).digest('hex');
    const previous = parsed.get(key);
    if (previous && previous.doc.text === r.text) {
        parsed.delete(key);
        parsed.set(key, previous);
        return previous.doc;
    }
    if (previous) { parsedCost-=previous.cost;parsed.delete(key); }
    const doc = new SourceDocument(r.text, r.id, true);
    const cost = r.text.length * 6 + doc.nodes.size * 768;
    if (cost <= 128 * 1024 * 1024) {
        while (parsed.size && (parsed.size >= limits.resources || parsedCost + cost > 128 * 1024 * 1024)) {
            const old = parsed.keys().next().value!;
            parsedCost -= parsed.get(old)!.cost;
            parsed.delete(old);
        }
        parsed.set(key, { doc, cost });
        parsedCost += cost;
    }
    return doc;
}
export function createGraph(input: any) {
    const docs = new Map<string, SourceDocument>((input.resources as Resource[]).map(r => [r.id, parseResource(r)]));
    const root = docs.get(input.root);
    if (!root) throw new SourceError('inspect.root', 'The selected root is absent');
    const declaration = specificationDeclaration(root.root.value);
    if (declaration.status !== 'supported') throw new SourceError(declaration.code, declaration.message, root.dataNode(declaration.pointer)?.range);
    const family = declaration.specification.family;
    return {docs, family, graph: ReferenceGraph.capture(docs, input.root, family, new Map(input.resources.map((r: Resource) => [r.id, r.aliases ?? []])), input.occurrences)};
}
export function analyse(input: any, context?: ReturnType<typeof createGraph>) {
    const started = performance.now();
    const docs = new Map<string, SourceDocument>(), findings: any[] = [], references: any[] = [], operations: any[] = [], components: any[] = [];
    let complete = true, supported = true;
    const diagnostic = (r: Resource, category: string, code: string, message: string, pointer = '', range?: any, severity = 'error', incomplete = false) => {
        const doc=docs.get(r.id),authored=doc?.nodes.get(pointer),source=authored??doc?.dataNode(pointer);
        const physical=source?.pointer??pointer;
        findings.push({ version: 1, category, code, severity, ...safeFinding(message,physical), resource: r.id, root:input.root, range: range ?? source?.range ?? [0, 0], engine: 'busyapi', engineVersion, producer:'busyapi',producerVersion:engineVersion, snapshot: input.snapshot,
            ...(incomplete?{incomplete:true}:{}),
            ...(physical!==pointer?{occurrencePointer:safeFinding('',pointer).pointer}:{}),
            ...(code==='parameter.path.required' && authored && !authored.shared && doc?.syntaxSafe(pointer)?{fixes:['path-parameter-required']}:{}) });
    };
    if (input.resources.length > limits.resources)
        throw new SourceError('limit.resources', 'Dependency count exceeds the 2048-resource limit');
    for (const r of input.resources as Resource[])
        try {
            const doc = context?.docs.get(r.id)??parseResource(r);
            docs.set(r.id, doc);
            for (const issue of doc.issues) {
                complete = false;
                diagnostic(r, 'syntax', issue.code, issue.message, '', issue.range);
            }
        }
        catch (e) {
            const er = e as SourceError;
            const limited = er.code?.startsWith('limit.');
            if (limited)
                complete = false;
            diagnostic(r, limited ? 'openapi' : 'syntax', er.code ?? 'syntax', er.message, '', er.range, limited ? 'warning' : 'error');
        }
    const parsedAt = performance.now();
    const syntaxComplete=!findings.some(f=>f.code.startsWith('limit.'));
    const categoryStates=()=>({syntax:{complete:syntaxComplete,producer:'busyapi',producerVersion:engineVersion,snapshot:input.snapshot,coverage:'strict-json-and-yaml12-core'},
        security:{complete:false,status:'not-run',producer:'busyapi-security-design',producerVersion:'1',snapshot:input.snapshot},
        policy:{complete:false,status:'not-run',required:false},runtime:{complete:false,status:'not-implemented',required:false}});
    const root = docs.get(input.root);
    const rootResource = input.resources.find((r: Resource) => r.id === input.root);
    if (!root || !rootResource)
        return { version: 1, snapshot: input.snapshot, status: findings.some(d => d.code.startsWith('limit.')) ? 'incomplete' : 'invalid', complete: false, findings, operations, components, references, versions, categories:categoryStates(), coverage: { syntax: 'strict-json-and-yaml12-core', openapi: 'not-run' } };
    const data = root.root.value;
    const declaration = specificationDeclaration(data);
    const specification = declaration.status === 'supported' ? declaration.specification : undefined;
    const family = specification?.family ?? '';
    if (declaration.status !== 'supported') {
        supported = false;
        complete = false;
        diagnostic(rootResource, 'openapi', declaration.code, declaration.message, declaration.pointer);
    }
    if (modernFamily(family) && specification.schemaDialect!==null && !supportedSchemaDialect({family,dialect:specification.schemaDialect})) {
        complete = false;
        diagnostic(rootResource, 'openapi', 'dialect.unsupported', 'The root JSON Schema dialect is not supported', '/jsonSchemaDialect', undefined, 'warning');
    }
    if (supported) {
        const validate = validators[family];
        if (!validate(data))
            for (const e of validate.errors.slice(0, 200))
                diagnostic(rootResource, 'openapi', 'structure.' + e.keyword, e.message ?? 'Structural violation', e.instancePath);
    }
    const validatedAt = performance.now();
    const graph = context?.graph??ReferenceGraph.capture(docs, input.root, family, new Map(input.resources.map((r: Resource) => [r.id, r.aliases ?? []])));
    for (const issue of graph.issues) {
        if (issue.incomplete) complete = false;
        diagnostic(input.resources.find((r: Resource) => r.id === issue.resource), 'openapi', issue.code, issue.message, issue.pointer, undefined, issue.severity??(issue.code === 'dialect.unsupported' ? 'warning' : 'error'));
    }
    const index = (document: SourceDocument, pointer: string, value: any, extra: any = {}) => ({ syntaxSafe: document.syntaxSafe(pointer), nodeKind: document.nodes.get(pointer)?.kind, root: input.root, resource: document.id, markdownBase:referenceMarkdownContext(graph,document.id,pointer), generation: input.resources.find((r: Resource) => r.id === document.id)?.generation, pointer, range: document.nodes.get(pointer)?.range ?? [...document.nodes.entries()].filter(([p]) => pointer.startsWith(p+'/')).sort((a,b)=>b[0].length-a[0].length)[0]?.[1].range ?? [0,0], value, ...extra, shared: (document.nodes.get(pointer)?.shared ?? false) || extra.shared === true || !document.nodes.has(pointer) });
    for(const occurrence of graph.operations()) {
        const {source,pathItem}=occurrence,document=docs.get(source.resource)!,view=graph.pathItem(pathItem);
        if(!view.complete)complete=false;
        const inherited=(name:string)=>{const field=view.fields.get(name);return field?docs.get(field.resource)!.dataNode(field.pointer)!.value:undefined;};
        operations.push(index(document,source.pointer,document.dataNode(source.pointer)?.value,{
            path:occurrence.path,method:occurrence.method,customMethod:occurrence.customMethod===true,role:occurrence.role,shared:occurrence.shared,
            occurrence:occurrence.occurrence,family:graph.scope(source.resource,source.pointer).family,
            inheritedParameters:inherited('parameters')??[],
            pathContext:{...pathItem,complete:view.complete,fields:Object.fromEntries(view.fields),
                reference:docs.get(pathItem.resource)!.dataNode(pathItem.pointer)?.value?.$ref,
                summary:inherited('summary'),description:inherited('description'),servers:inherited('servers')},
        }));
    }
    const componentLocations=Object.fromEntries(['schema','parameter','response','header','request-body','example','link','callback','path-item','security','media'].flatMap(kind=>{
        const group=componentFamily(kind,family);return group?[[group,componentLocation(group,family)]]:[];
    }));
    const componentValues=family==='2.0'?Object.fromEntries(Object.entries(componentLocations).map(([group,pointer])=>[group,root.dataNode(String(pointer))?.value??{}])):data?.components??{};
    for (const [group, objects] of Object.entries(componentValues) as any)
        for (const [name, v] of Object.entries(objects ?? {}) as any)
            components.push(index(root, (componentLocations[group]??'/components/'+escape(group)) + '/' + escape(name), v, { group, name }));
    const schemaScopes=graph.scopesFor('schema'),physicalRoots=schemaRoots(schemaScopes.filter(scope=>!scope.sourceKind)),metaRoots=[...physicalRoots,...schemaScopes.filter(scope=>scope.sourceKind)],nestedBoundaries=nestedSchemaBoundaries(physicalRoots);
    const exactNumericKeywords=new Set(['minimum','maximum','exclusiveMinimum','exclusiveMaximum','multipleOf','minLength','maxLength','minItems','maxItems','minProperties','maxProperties','minContains','maxContains']);
    for (const scope of metaRoots) {
        if (!supportedSchemaDialect(scope) || !modernFamily(scope.family)) continue;
        const doc = docs.get(scope.resource)!;
        const value = schemaMetaView(doc.dataNode(scope.pointer)!.value,scope.pointer,nestedBoundaries(scope));
        if (typeof value !== 'boolean' && (value === null || typeof value !== 'object' || Array.isArray(value))) {
            diagnostic(input.resources.find((r: Resource) => r.id === doc.id), 'openapi', 'schema.type', 'A Schema Object must be an object or a boolean', scope.pointer);
            continue;
        }
        const metaValue = value && typeof value === 'object' ? { ...value } : value;
        if (metaValue && typeof metaValue === 'object') delete metaValue.$schema;
        if (!ajv.validateSchema(metaValue))
            for (const e of (ajv.errors ?? []).slice(0, 32)) {
                const pointer=scope.pointer+e.instancePath;
                // This fast stage is a JS structural projection. Numeric
                // keyword values are decided by the awaited exact-CST stage,
                // not rounded zero/infinity/integers in this projection.
                const numeric=doc.nodes.get(pointer)?.value;
                if(typeof numeric==='number'&&exactNumericKeywords.has(segments(pointer).at(-1)!)&&
                    (!Number.isFinite(numeric)||numeric===0&&!/^-?0(?:\.0+)?(?:[eE][+-]?\d+)?$/.test(doc.dataJson(pointer))))continue;
                diagnostic(input.resources.find((r: Resource) => r.id === doc.id), 'openapi', 'schema.' + e.keyword, e.message ?? 'Invalid JSON Schema keyword', scope.pointer + e.instancePath);
            }
    }
    const targetKinds: Record<string, string> = { operation: 'operation', parameter: 'parameter', response: 'response', header: 'header', example: 'example', link: 'link', 'request-body': 'request-body', security: 'security-scheme', 'path-item': 'path-item', media: 'media-type', callback: 'callback' };
    for (const ref of graph.references) {
        const doc = docs.get(ref.resource)!;
        references.push(index(doc, ref.pointer + '/' + escape(ref.keyword), ref.value, {
            kind: ref.kind === 'schema' ? 'schema' : 'reference', contextKind: ref.kind,
            keyword: ref.keyword, base: ref.base, dialect: ref.dialect, connection: ref.connection,
            ...(ref.connection === 'security' ? {range: doc.nodes.get(ref.pointer + '/' + escape(ref.keyword))?.keyRange ?? doc.nodes.get(ref.pointer + '/' + escape(ref.keyword))?.range} : {}),
            resolution: ref.resolution, targetUri: ref.targetUri,
            candidateResources: ref.candidateResources,
            candidateTargets: ref.candidateTargets,
            targetResource: ref.targetResource, targetPointer: ref.targetPointer,
            targetRange: ref.resolution === 'resolved' ? docs.get(ref.targetResource!)?.dataNode(ref.targetPointer!)?.range : undefined,
            dynamic: ref.dynamic,
        }));
        if (ref.resolution !== 'resolved' || ref.kind === 'schema') continue;
        const targetFamily = graph.scope(ref.targetResource!, ref.targetPointer!).family;
        const context = targetKinds[ref.kind];
        const validator = context && validators[targetFamily] && ajv.getSchema(structuralSchema(targetFamily).$id + '#/$defs/' + context);
        const target = docs.get(ref.targetResource!)!;
        const targetValue = target.dataNode(ref.targetPointer!)!.value;
        if (validator && !(targetValue && typeof targetValue.$ref === 'string') && !validator(targetValue))
            for (const e of (validator.errors ?? []).slice(0, 32))
                diagnostic(input.resources.find((r: Resource) => r.id === target.id), 'openapi', 'reference.target.' + e.keyword, e.message ?? 'Invalid referenced object', ref.targetPointer + e.instancePath);
    }
    const resolved = (doc: SourceDocument, value: any, pointer: string, ancestors = new Set<string>(), depth = 0, kind = 'operation'): any => {
        if (depth > 32 || !value || typeof value !== 'object')
            return value;
        const owner = graph.scope(doc.id, pointer);
        if (!supportedSchemaDialect(owner) || value.$dynamicRef)
            return value;
        if (typeof value.$ref === 'string' && referenceKinds.has(kind) && (kind !== 'media' || owner.family === '3.2')) {
            try {
                const ref = graph.resolveReference(value.$ref, graph.scope(doc.id, pointer));
                if (ref.resolution !== 'resolved') return value;
                const part = ref.targetPointer!, target = docs.get(ref.targetResource!);
                const key = ref.targetResource + '#' + part;
                if (target && target.dataNode(part) && !ancestors.has(key)) {
                    const next = new Set(ancestors);
                    next.add(key);
                    const definition = resolved(target, target.dataNode(part)!.value, part, next, depth + 1, kind);
                    const siblings = Object.fromEntries(Object.entries(value).filter(([k]) => k !== '$ref'));
                    if (kind === 'schema' && modernFamily(owner.family))
                        return Object.keys(siblings).length ? { allOf: [definition, siblings] } : definition;
                    return definition && typeof definition === 'object' ? { ...definition, ...Object.fromEntries(Object.entries(siblings).filter(([k]) => modernFamily(owner.family) && ['summary', 'description'].includes(k))) } : definition;
                }
            }
            catch { }
            return value;
        }
        let output: any;
        for (const [key, v, nextKind] of children(value, kind, owner.family)) {
            const child = resolved(doc, v, pointer + '/' + escape(key), ancestors, depth + 1, nextKind);
            if (child !== v) {
                output ??= Array.isArray(value) ? [...value] : { ...value };
                output[key] = child;
            }
        }
        return output ?? value;
    };
    for (const operation of operations) {
        const document = docs.get(operation.resource)!;
        operation.details = {};
        const detail = (node: any) => {
            if (node.kind === 'object' || node.pointer.endsWith('/schema') || /\/properties\/[^/]+$/.test(node.pointer) || node.pointer.endsWith('/example')) {
                const located = index(document, node.pointer, undefined, { occurrence: operation.occurrence });
                delete located.value;
                operation.details[node.pointer] = located;
            }
            for (const child of node.children.values())
                detail(child);
        };
        for (const child of document.nodes.get(operation.pointer)?.children.values() ?? [])
            detail(child);
        const owner = docs.get(operation.resource)!;
        operation.exampleTexts = {};
        for (const [status, response] of Object.entries(operation.value?.responses ?? {}) as any) {
            for (const [media, content] of Object.entries(response?.content ?? {}) as any) {
                const pointer = operation.pointer + '/responses/' + escape(status) + '/content/' + escape(media) + '/example';
                if (content && Object.hasOwn(content, 'example') && owner.nodes.has(pointer)) {
                    (operation.exampleTexts[status] ??= {})[media] = owner.dataJson(pointer);
                }
            }
        }
        const projected = resolved(docs.get(operation.resource)!, operation.value, operation.pointer);
        if (projected !== operation.value)
            operation.referenceValue = projected;
    }
    if (supported)
        for (const op of operations)
            if (op.value && typeof op.value === 'object' && !Array.isArray(op.value) && (op.value.responses && typeof op.value.responses === 'object' && !Object.keys(op.value.responses).some(k => !k.startsWith('x-'))))
                diagnostic(input.resources.find((r: Resource) => r.id === op.resource), 'openapi', 'operation.responses.empty', 'A Responses Object must contain at least one response', op.pointer);
    for (const issue of new ParameterSemantics(graph).checks(operations)) {
        if(issue.incomplete)complete=false;
        diagnostic(input.resources.find((r:Resource)=>r.id===issue.resource),'openapi',issue.code,issue.message,issue.pointer,issue.range,issue.severity??'error');
    }
    for (const issue of [...authoringRelationships(graph), ...serverRelationships(graph),...swaggerServerRelationships(graph), ...xmlRelationships(graph), ...documentUriRelationships(graph), ...restrictedSchemaIssues(graph), ...securityRequirementIssues(graph), ...mediaTypeIssues(graph), ...formMediaIssues(graph),...responseStatusIssues(graph)]) {
        if(issue.incomplete)complete=false;
        diagnostic(input.resources.find((r:Resource)=>r.id===issue.resource),'openapi',issue.code,issue.message,issue.pointer,undefined,issue.severity??'error',issue.incomplete);
    }
    const security=securityDesign(input,docs,graph,operations);
    findings.push(...security.findings);
    if(!security.complete)complete=false;
    const categories={...categoryStates(),security:Object.fromEntries(Object.entries(security).filter(([name])=>name!=='findings'))};
    return { ...(input.measure ? { timings: { parseMs: parsedAt - started, structuralMs: validatedAt - parsedAt, projectionMs: performance.now() - validatedAt } } : {}), version: 1, snapshot: input.snapshot, status: findings.some(d => d.category === 'syntax') ? 'invalid' : !supported ? 'unsupported' : !complete ? 'incomplete' : findings.some(d => d.severity === 'error') ? 'invalid' : 'complete', complete: complete && supported, findings, categories, info: index(root, '/info', data?.info ?? {}, {fields: fieldsFor('info', family, data?.info ?? {}).map(field => ({...field, present: Object.hasOwn(data?.info ?? {}, field.name)}))}), specification, openapi: specification?.declaredVersion, pathItems: ['paths','webhooks'].flatMap(role => data?.[role] && typeof data[role]==='object' && !Array.isArray(data[role]) ? Object.keys(data[role]).filter(name=>role==='webhooks'||name.startsWith('/')).map(name=>index(root,'/'+role+'/'+escape(name),undefined,{name,role})) : []), operations, components, componentLocations, references, coverage: { syntax: 'strict-json-and-yaml12-core', openapi: 'official-structural-shapes-and-initial-authoring-semantics', schemas: '2020-12-keyword-shapes', references: 'uri-resource-identities-pointers-anchors-and-contextual-dynamic-navigation', formats: 'not-validated', security:security.coverage }, versions, resources: input.resources.map((r: Resource) => ({ id: r.id, generation: r.generation, identity: r.identity })), otherRootFields: Object.keys(data ?? {}).filter(k => !['openapi', 'info', 'paths', 'components'].includes(k)), otherRootObjects: Object.keys(data ?? {}).filter(k => !['openapi', 'info', 'paths', 'components'].includes(k)).map(name => index(root, '/' + escape(name), data[name], { name })) };
}
export function inspect(input: any) {
    const {docs, graph} = createGraph(input);
    const doc = docs.get(input.resource), node = doc?.nodes.get(input.pointer);
    const scope = graph.scopes.get(input.resource + '#' + input.pointer);
    const family = doc ? graph.scope(doc.id, input.pointer).family : graph.family;
    if (!isNativeFamily(family))
        throw new SourceError('version.unsupported', 'Native authoring requires a supported containing OpenAPI feature family');
    if (doc && !node) {
      {
        // Fixed nested collections may be absent with their parent (for
        // example components/schemas). Viewing this virtual location is read
        // only; its explicit creation targets the nearest existing owner and
        // the normal proposal writer creates only these legal ancestors.
        const tokens=segments(input.pointer);
        let at='',kind=graph.scopes.get(doc.id+'#')?.kind??'root',owner=doc.root;
        let missing=false,field:any;
        for(let i=0;i<tokens.length;i++) {
            const next=at+'/'+escape(tokens[i]),existing=doc.nodes.get(next);
            field=fieldsForScope(graph,{...graph.scope(doc.id,at),pointer:at,kind},doc.nodes.get(at)?.value??{}).find(f=>f.name===tokens[i]);
            const childKind=children({[tokens[i]]:{}},kind,family,doc.nodes.get(at)?.value??{})[0]?.[2];
            if(!field||!childKind||!['object','array','schema'].includes(field.type)) {field=undefined;break;}
            if(!missing&&existing)owner=existing;
            else missing=true;
            kind=childKind;at=next;
        }
        if(missing&&field&&owner.pointer!==input.pointer) {
            const generation=input.resources.find((r:Resource)=>r.id===doc.id).generation;
            return {version:1,snapshot:input.snapshot,root:input.root,resource:doc.id,generation,pointer:input.pointer,kind,absent:true,
                parent:{root:input.root,resource:doc.id,generation,pointer:owner.pointer,range:owner.range,nodeKind:owner.kind,syntaxSafe:doc.syntaxSafe(owner.pointer),shared:owner.shared},
                field:{...field,destinationPointer:input.pointer},fields:[],entries:[],references:[],count:0};
        }
      }
        const parts = segments(input.pointer), name = parts.pop()!, parentPointer = parts.length ? '/' + parts.map(escape).join('/') : '';
        const parent = doc.nodes.get(parentPointer), parentScope = graph.scopes.get(doc.id + '#' + parentPointer);
        const field = parent && parentScope && fieldsForScope(graph,parentScope,parent.value).find(f => f.name === name);
        const kind = parentScope && children({[name]: {}}, parentScope.kind, family, parent?.value)[0]?.[2];
        if (parent && field && kind && ['object', 'array', 'schema'].includes(field.type)) {
            const generation = input.resources.find((r: Resource) => r.id === doc.id).generation;
            return {version: 1, snapshot: input.snapshot, root: input.root, resource: doc.id, generation, pointer: input.pointer, kind, absent: true,
                parent: {root: input.root, resource: doc.id, generation, pointer: parentPointer, range: parent.range, nodeKind: parent.kind, syntaxSafe: doc.syntaxSafe(parentPointer), shared: parent.shared},
                field, fields: [], entries: [], references: [], count: 0};
        }
    }
    if (!doc || !node || !scope) throw new SourceError('inspect.context', 'This occurrence has no established specification context');
    const resource = input.resources.find((r: Resource) => r.id === doc.id);
    const tokens = segments(node.pointer), last = tokens.pop();
    const parentPointer = tokens.length ? '/' + tokens.map(escape).join('/') : '';
    const parentNode = node.pointer ? doc.nodes.get(parentPointer) : undefined;
    const parentScope = parentNode && graph.scopes.get(doc.id + '#' + parentPointer);
    const fragmentDefinition = parentNode?.kind === 'object' && (!parentScope || parentScope.kind === 'root' && !graph.specifications.has(doc.id));
    const removable = !!parentNode && (fragmentDefinition || !!parentScope && removableField(parentScope.kind, family, parentNode.value, last!, tokens.at(-1),graph.allowsReference(parentScope)));
    const located = (n: any, kind: string) => ({root: input.root, resource: doc.id, generation: resource.generation, pointer: n.pointer, range: n.range,
        syntaxSafe: doc.syntaxSafe(n.pointer), nodeKind: kind==='schema'&&typeof n.value==='boolean'?'boolean':n.kind, shared: n.shared, kind});
    const definitions = fieldsForScope(graph,scope,node.value);
    const fields = definitions.map(field => {
        const child = node.children.get(field.name);
        const childKind = children({[field.name]: {}}, scope.kind, family, node.value)[0]?.[2];
        return {...field, childKind, present: !!child, ...(child ? {dataType: child.value===null?'null':Array.isArray(child.value)?'array':typeof child.value, target: located(child, graph.scopes.get(doc.id + '#' + child.pointer)?.kind ?? 'data'),
            ...(typeof child.value !== 'object' && String(child.value).length <= 16384 ? {value: child.value} : {}),
            ...(child.range[1] - child.range[0] <= 16384 ? {raw: doc.dataJson(child.pointer)} : {}), count: child.children.size} : {})};
    });
    const offset = Math.min(Math.max(0, Number.isInteger(input.offset) ? input.offset : 0), Math.max(0, (Math.ceil(node.children.size / 50) - 1) * 50));
    const ownerPointer = scope.kind === 'schema-map' && node.pointer.endsWith('/properties') ? node.pointer.slice(0, -'/properties'.length) : undefined;
    const ownerSchema = ownerPointer === undefined ? undefined : doc.node(ownerPointer);
    const securityBinding=(pointer:string,name:string)=>{
        const reference=graph.references.find(ref=>ref.resource===doc.id&&ref.pointer===pointer&&ref.keyword===name&&ref.connection==='security');
        return reference?{name:reference.value,kind:securityRequirementValueRule(graph,reference)}:undefined;
    };
    const binding=parentScope?.kind==='security-requirement'&&scope.kind==='string-array'?securityBinding(parentPointer,last!):undefined;
    const entries = [...node.children].slice(offset, offset + 50).map(([name, child]) => ({name,
        ...located(child, graph.scopes.get(doc.id + '#' + child.pointer)?.kind ?? 'data'),
        ...(typeof child.value !== 'object' && String(child.value).length <= 240 ? {value: child.value} : {}),
        ...(child.range[1] - child.range[0] <= 16384 ? {raw: doc.dataJson(child.pointer)} : {}),
        ...(ownerSchema ? {required: Array.isArray(ownerSchema.value.required) && ownerSchema.value.required.includes(name)} : {}),
        ...(scope.kind==='security-requirement'?{securityBinding:securityBinding(node.pointer,name)}:{}), count: child.children.size}));
    const references = graph.references.filter(ref => ref.resource === doc.id && ref.pointer === node.pointer).map(ref => ({...ref,
        ...(ref.resolution === 'resolved' ? {target: {root: input.root, resource: ref.targetResource, pointer: ref.targetPointer,
            generation: input.resources.find((r: Resource) => r.id === ref.targetResource)?.generation, ...docs.get(ref.targetResource!)!.dataLocation(ref.targetPointer!)}} : {})}));
    let schemaTreeRoot:string|undefined;
    if(['schema','schema-map','schema-array'].includes(scope.kind)) {
      let at=node.pointer;
      while(true) {
        const parent=graph.scopes.get(doc.id+'#'+at);
        if(parent?.kind==='schema')schemaTreeRoot=at;
        else if(!parent||!['schema-map','schema-array'].includes(parent.kind))break;
        if(!at)break;at=at.slice(0,at.lastIndexOf('/'));
      }
    }
    const componentDestinations=componentFamily(scope.kind,family)?[...docs.values()].filter(candidate=>graph.specifications.get(candidate.id)?.family===family&&candidate.syntaxSafe('')&&!candidate.root.shared).map(candidate=>candidate.id):[];
    const memberPolicy=collectionMemberNamePolicy(graph,scope),componentPolicy=componentFamily(scope.kind,family)?componentNamePolicy(family):undefined;
    const componentDefinition=!!componentPolicy&&graph.specifications.has(doc.id)&&reusableDefinitionPointer(node.pointer,family);
    const schemaDefinitionPolicy=schemaDefinitionNamePolicy(graph,scope);
    let operationContext:any;
    if(scope.kind==='operation'){
        let at=node.pointer;
        while(at){
            at=at.slice(0,at.lastIndexOf('/'));
            const path=graph.scopes.get(doc.id+'#'+at);
            if(path?.kind!=='path-item')continue;
            const collection=graph.scopes.get(doc.id+'#'+at.slice(0,at.lastIndexOf('/')));
            operationContext={pathItemPointer:at,method:segments(node.pointer).at(-1),additional:parentScope?.kind==='operation-map',
                canRelocatePath:collection?.kind==='path-map'&&graph.specifications.has(doc.id),path:segments(at).at(-1)};
            break;
        }
    }
    const sharedTarget=!!componentFamily(scope.kind,family)&&graph.references.some(ref=>ref.resolution==='resolved'&&ref.targetResource===doc.id&&ref.targetPointer===node.pointer);
    return {version: 1, snapshot: input.snapshot, family, ...(isNativeFamily(family)?{capabilities:capabilitiesFor(family)}:{}), customSchemaKeywords: modernFamily(family), ...located(node, scope.kind), sharedTarget, componentDestination: graph.specifications.get(doc.id)?.family===family, componentDestinations, ...(componentFamily(scope.kind,family)?{componentFamily:componentFamily(scope.kind,family)}:{}), ...(schemaTreeRoot!==undefined?{schemaTreeRoot}:{}), removable, allowsExtensions: allowsExtensions(scope.kind, family, node.value, segments(node.pointer).at(-1),graph.allowsReference(scope)), fields, entries, offset, count: node.children.size, references,
        ...(ownerSchema ? {ownerSchema: located(ownerSchema, 'schema')} : {}),
        schemaSuggestion:schemaInferenceSources(graph,scope),
        ...(binding?{securityBinding:binding}:{}),
        ...(memberPolicy?{memberNamePolicy:memberPolicy}:{}),
        ...(componentPolicy?{componentNamePolicy:componentPolicy}:{}),
        componentDefinition,
        ...(schemaDefinitionPolicy?{schemaDefinitionNamePolicy:schemaDefinitionPolicy}:{}),
        ...(scope.kind==='response'&&parentScope?.kind==='response-map'?{responseStatusNamePolicy:responseStatusNamePolicy(family)}:{}),
        value: Object.fromEntries(fields.filter(f => f.present && Object.hasOwn(f, 'value')).map(f => [f.name, f.value])),
        boolean: scope.kind==='schema'&&typeof node.value === 'boolean' ? node.value : undefined,
        ...(operationContext?{operationContext}:{}),
        ...(['operation','path-item'].includes(scope.kind)?{operationMethods:standardOperationMethods(scope.family)}:{})};
}

/** Explicit, captured data read for a form, not a projection on every reparse.
 * Payload keys remain opaque; exact numeric values come from the same CST. */
export function readDataValue(input:any) {
    const target=input.target,resource=(input.resources as Resource[]).find(r=>r.id===target?.resource);
    if(!resource||resource.generation!==target.generation||!['json','text'].includes(input.representation))
        throw new SourceError('data.value.stale','The captured data occurrence changed');
    const doc=parseResource(resource),node=doc.node(target.pointer);
    if(!doc.syntaxSafe(target.pointer)||JSON.stringify(target.range)!==JSON.stringify(node.range))
        throw new SourceError('data.value.stale','The captured data range changed or has ambiguous syntax');
    if(node.shared)throw new SourceError('edit.shared','Choose the explicit YAML source definition before editing shared data');
    if(input.representation==='text'&&typeof node.value!=='string')
        throw new SourceError('data.value.type','The selected value is not authored text');
    const value=input.representation==='text'?node.value:doc.dataJson(node.pointer);
    if(Buffer.byteLength(value)>16*1024*1024)
        throw new SourceError('limit.data.value','The captured data representation exceeds the 16 MiB editing budget');
    return {version:1,snapshot:input.snapshot,root:input.root,resource:resource.id,generation:resource.generation,
        pointer:node.pointer,range:node.range,representation:input.representation,value};
}

export function propose(input: any) {
    const resource: Resource = input.resources.find((r: Resource) => r.id === input.target.resource);
    if (!resource || resource.generation !== input.target.generation)
        throw new SourceError('edit.stale', 'Captured buffer generation is stale');
    let doc = new SourceDocument(resource.text, resource.id, true);
    doc.assertSafe(input.target.pointer);
    const captured = doc.node(input.target.pointer);
    if (input.target.range && JSON.stringify(captured.range) !== JSON.stringify(input.target.range))
        throw new SourceError('edit.stale', 'Source occurrence moved');
    if (input.target.expected !== undefined && resource.text.slice(...captured.range) !== input.target.expected)
        throw new SourceError('edit.stale', 'Captured source text changed');
    for (const action of input.actions) {
        let fieldForms: SchemaValueForms | undefined;
        if (Object.hasOwn(action, 'schemaValueForms')) {
            if (!['setData', 'createData', 'remove'].includes(action.kind) || typeof action.pointer !== 'string')
                throw new SourceError('edit.action', 'Schema field value forms require a captured data edit');
            const parts = segments(action.pointer), name = parts.pop();
            const parentPointer = parts.length ? '/' + parts.map(escape).join('/') : '';
            const {graph} = createGraph({...input, resources: input.resources.map((item: Resource) => item.id === doc.id ? {...item, text: doc.text} : item)});
            const scope = graph.scopes.get(doc.id + '#' + parentPointer);
            const field = scope && fieldsForScope(graph, scope, doc.node(parentPointer).value).find(field => field.name === name);
            fieldForms = field?.schemaValueForms;
            if (!fieldForms || !sameSchemaValueForms(action.schemaValueForms, fieldForms))
                throw new SourceError('edit.stale', 'The captured schema field value forms changed; reopen the field before applying');
            if (!fieldForms.supported && action.kind !== 'remove')
                throw new SourceError('edit.schema.dialect.unsupported', 'Schema field value forms are unavailable for the declared schema dialect', doc.node(parentPointer).range, 'unsupported');
        }
        if (action.kind === 'set' && segments(action.pointer).length === 3 && segments(action.pointer)[0] === 'paths') {
          const parts=segments(action.pointer), pathPointer='/paths/'+escape(parts[1]);
          const pathItem=doc.nodes.get(pathPointer);
          if (pathItem?.shared || pathItem?.value?.$ref) throw new SourceError('edit.path.reference','This Path Item has shared or referenced ownership; choose its source target explicitly');
          if (doc.nodes.has(action.pointer)) throw new SourceError('edit.collision','The operation destination is occupied');
        }

        if (action.pointer)
            doc.assertSafe(action.pointer);
        let text: string;
        if (action.kind === 'moveOperation') {
            let n = doc.node(input.target.pointer);
            if (segments(n.pointer).includes('additionalOperations'))
                throw new SourceError('edit.operation.custom', 'Custom operation relocation needs an explicit additionalOperations target; edit its source occurrence');
            if (!standardOperationMethods(createGraph(input).graph.scope(doc.id,n.pointer).family).includes(action.method))
                throw new SourceError('edit.method', 'Choose a supported Path Item method');
            const opSegments = segments(n.pointer), oldMethod = opSegments.pop()!, oldPath = opSegments.pop()!;
            const pathItem = doc.node('/paths/' + escape(oldPath));
            const targetItem = doc.nodes.get('/paths/' + escape(action.path));
            if (action.path !== oldPath) {
                if (pathItem.value.$ref || targetItem?.value?.$ref)
                    throw new SourceError('edit.path.reference', 'Referenced Path Item context requires an explicit source target');
                for (const context of [pathItem.value, targetItem?.value]) {
                    if (!context)
                        continue;
                    if (context.parameters != null && (!Array.isArray(context.parameters) || context.parameters.some((p: any) => !p || typeof p !== 'object' || p.$ref)))
                        throw new SourceError('edit.path.parameters', 'Source and destination inherited parameters need explicit source review');
                    if (context.servers != null && (!Array.isArray(context.servers) || context.servers.some((s: any) => !s || typeof s !== 'object' || typeof s.url !== 'string')))
                        throw new SourceError('edit.path.servers', 'Source or destination servers have ambiguous context');
                }
                const hasContext = (v: any) => v && ['parameters', 'servers', 'summary', 'description'].some(k => Object.hasOwn(v, k));
                if ((hasContext(pathItem.value) || hasContext(targetItem?.value)) && !['destination', 'preserve'].includes(action.context))
                    throw new SourceError('edit.path.context', 'Choose destination context or preservation of effective parameters and servers');
                const names = new Set([...String(action.path).matchAll(/\{([^}]+)\}/g)].map(m => m[1]));
                const inherited = action.context === 'preserve' ? pathItem.value.parameters ?? [] : targetItem?.value?.parameters ?? [];
                const own = n.value.parameters ?? [];
                if (!Array.isArray(own) || !Array.isArray(inherited) || [...own, ...inherited].some((p: any) => !p || typeof p !== 'object' || p.$ref))
                    throw new SourceError('edit.path.parameters', 'Referenced or malformed parameters require explicit source review');
                const effective = [...own, ...inherited.filter((p: any) => !own.some((o: any) => o.name === p.name && o.in === p.in))];
                if (effective.some((p: any) => p.in === 'path' && (!names.has(p.name) || p.required !== true)) || [...names].some(name => !effective.some((p: any) => p.in === 'path' && p.name === name && p.required === true)))
                    throw new SourceError('edit.path.template', 'Path placeholders and effective path parameters must agree');
                if (action.context === 'preserve') {
                    for (const p of targetItem?.value?.parameters ?? [])
                        if (!effective.some((o: any) => o.name === p.name && o.in === p.in))
                            throw new SourceError('edit.path.context', 'Destination parameters cannot be removed by an operation override; choose destination context or another path');
                    for (let i = 0; i < inherited.length; i++)
                        if (!own.some((o: any) => o.name === inherited[i].name && o.in === inherited[i].in)) {
                            const sourcePointer = pathItem.pointer + '/parameters/' + i;
                            if (doc.node(sourcePointer).shared)
                                throw new SourceError('edit.shared', 'Aliased parameters require an explicit source target');
                            const raw = new RawJsonValue(doc.dataJson(sourcePointer));
                            if (!doc.nodes.has(n.pointer + '/parameters'))
                                doc = new SourceDocument(doc.set(n.pointer + '/parameters', []), resource.id, true);
                            doc = new SourceDocument(doc.set(n.pointer + '/parameters/' + doc.node(n.pointer + '/parameters').children.size, raw), resource.id, true);
                        }
                    if (!Object.hasOwn(n.value, 'servers') && (pathItem.value.servers || targetItem?.value?.servers)) {
                        const sourcePointer = pathItem.value.servers ? pathItem.pointer + '/servers' : doc.root.value.servers ? '/servers' : undefined;
                        const value = sourcePointer ? new RawJsonValue(doc.dataJson(sourcePointer)) : [{ url: '/' }];
                        doc = new SourceDocument(doc.set(n.pointer + '/servers', value), resource.id, true);
                    }
                }
            }
            n = doc.node(input.target.pointer);
            if (!action.path.startsWith('/'))
                throw new SourceError('edit.path', 'Paths must begin with /');
            const destination = '/paths/' + escape(action.path) + '/' + escape(action.method);
            if (doc.nodes.has(destination))
                throw new SourceError('edit.collision', 'Destination operation already exists');
            if (action.path === oldPath) {
                const keyNode = n.keyRange!;
                text = doc.replace(...keyNode, doc.emit(action.method));
            }
            else {
                const newPath = '/paths/' + escape(action.path);
                const oldEntryStart = n.entryStart ?? n.range[0];
                const authored = doc.text.slice(doc.lineStart(oldEntryStart), n.end);
                const baseIndent = doc.indent(oldEntryStart);
                const removed = doc.remove(n.pointer);
                const next = new SourceDocument(removed, resource.id);
                const existing = next.nodes.get(newPath);
                if (doc.format === 'json' || next.node('/paths').flow || existing?.flow && n.flow) {
                    if (doc.format === 'yaml' && !n.flow)
                        throw new SourceError('edit.path.flow', 'Moving an authored block into a flow container requires an explicit structure choice');
                    const raw = doc.text.slice(...n.range);
                    const parent = existing ?? next.node('/paths');
                    const at = parent.range[1] - 1;
                    const entry = existing ? JSON.stringify(action.method) + ': ' + raw : JSON.stringify(action.path) + ': {' + JSON.stringify(action.method) + ': ' + raw + '}';
                    text = next.replace(at, at, (parent.children.size ? ', ' : '') + entry);
                }
                else {
                    if (existing?.flow)
                        throw new SourceError('edit.path.flow', 'Moving a block operation into a flow Path Item cannot preserve its authored comments; choose a block destination in Source');
                    const parent = existing ?? next.node('/paths');
                    if (parent.flow)
                        throw new SourceError('edit.path.flow', 'Choose a block Paths container in Source before moving this operation');
                    const indent = existing ? next.indent(parent.range[0]) : next.indent(parent.range[0]) + 2;
                    let entry = authored.replace(new RegExp('(^|\\r?\\n) {' + baseIndent + '}', 'g'), '$1' + ' '.repeat(indent));
                    const originalMethod = doc.text.slice(...n.keyRange!);
                    const keyAt = entry.indexOf(originalMethod);
                    entry = entry.slice(0, keyAt) + next.emit(action.method) + entry.slice(keyAt + originalMethod.length);
                    if (!existing)
                        entry = ' '.repeat(indent - 2) + next.emit(action.path) + ':' + next.newline + entry;
                    const at = parent.end;
                    const prefix = /[\r\n]$/.test(next.text.slice(0, at)) ? '' : next.newline;
                    text = next.replace(at, at, prefix + entry + (/[\r\n]$/.test(entry) ? '' : at < next.text.length ? next.newline : ''));
                }
            }
        }
        else if (action.kind === 'setRequired') {
            if (typeof action.name !== 'string' || typeof action.required !== 'boolean') throw new SourceError('edit.action', 'Required membership needs a property name and boolean choice');
            const schema = doc.node(action.pointer);
            if (schema.kind !== 'object' || doc.nodes.get(action.pointer + '/properties')?.kind !== 'object' || !Object.hasOwn(schema.value.properties, action.name)) throw new SourceError('schema.property.missing', 'The property is not authored in this schema');
            const list = schema.value.required;
            if (list !== undefined && (!Array.isArray(list) || list.some((value: any) => typeof value !== 'string') || new Set(list).size !== list.length)) throw new SourceError('schema.required.shape', 'Repair the authored required list before changing membership');
            const index = list?.indexOf(action.name) ?? -1;
            if (action.required === (index >= 0)) text = doc.text;
            else if (action.required) {
                if (list === undefined) text = doc.set(action.pointer + '/required', [action.name]);
                else text = doc.set(action.pointer + '/required/' + list.length, action.name);
            } else {
                const owner = createGraph(input).graph.scope(resource.id, action.pointer);
                text = doc.remove(action.pointer + '/required' + (!modernFamily(owner.family) && list.length === 1 ? '' : '/' + index));
            }
        }
        else if (action.kind === 'rename') {
            const n = doc.node(action.pointer);
            const parts = segments(action.pointer);
            parts.pop();
            const parent = doc.node(parts.length ? '/' + parts.map(escape).join('/') : '');
            if (segments(action.pointer).at(-1) === action.name) continue;
            if (parent.children.has(action.name))
                throw new SourceError('edit.collision', 'Destination key already exists');
            if (n.shared || n.keyShared || !n.keyRange)
                throw new SourceError('edit.shared', 'Key is shared or has no editable source occurrence');
            const rawKey = doc.text.slice(...n.keyRange);
            const keyText = doc.format === 'yaml' && rawKey.startsWith("'") ? "'" + String(action.name).replaceAll("'", "''") + "'" : rawKey.startsWith('"') ? JSON.stringify(action.name) : doc.emit(action.name, undefined, parent.flow);
            text = doc.replace(...n.keyRange, keyText);
        }
        else if (action.kind === 'setExample' || action.kind === 'setData' || action.kind === 'createData') {
            if (action.kind === 'createData' && doc.nodes.has(action.pointer)) throw new SourceError('edit.collision', 'The destination already exists');
            text = setDataSource(doc, action.pointer, action.raw);
        }
        else if (action.kind === 'remove')
            text = doc.remove(action.pointer);
        else if (action.kind === 'append') {
            const n = doc.node(action.pointer);
            text = doc.set(action.pointer + '/' + n.children.size, action.value);
        }
        else if (action.kind === 'set' || action.kind === 'create') {
            if (action.kind === 'create' && doc.nodes.has(action.pointer)) throw new SourceError('edit.collision', 'The destination already exists');
            let p = action.pointer;
            const parts = segments(p);
            for (let i = 1; i < parts.length; i++) {
                const ancestor = '/' + parts.slice(0, i).map(escape).join('/');
                if (!doc.nodes.has(ancestor)) {
                    doc = new SourceDocument(doc.set(ancestor, {}), resource.id, true);
                }
            }
            text = doc.set(p, action.value);
        }
        else throw new SourceError('edit.action', 'Unknown source action');
        doc = new SourceDocument(text, resource.id, true);
        if (fieldForms && action.kind !== 'remove' && !allowsSchemaValue(fieldForms, doc.node(action.pointer)))
            throw new SourceError('edit.schema.value', 'This value does not have a permitted form for the captured schema field');
    }
    const original = resource.text, changed = doc.text;
    if (original === changed)
        return { version: 1, snapshot: input.snapshot, edits: [], nextRange: captured.range };
    let start = 0;
    while (start < Math.min(original.length, changed.length) && original[start] === changed[start])
        start++;
    let a = original.length, b = changed.length;
    while (a > start && b > start && original[a - 1] === changed[b - 1]) {
        a--;
        b--;
    }
    // Avoid splitting a surrogate pair at a generated boundary.
    if (start > 0 && /[\uDC00-\uDFFF]/.test(original[start]))
        start--;
    if (a > start && a < original.length && /[\uDC00-\uDFFF]/.test(original[a])) {
        a++;
        b++;
    }
    return { version: 1, snapshot: input.snapshot, nextRange: doc.nodes.get(input.target.pointer)?.range, edits: [{ buffer: resource.id, generation: resource.generation, start, end: a, expected: original.slice(start, a), replacement: changed.slice(start, b) }] };
}
export function discover(input: any) {
    const roots: any[] = [];
    for (const r of input.resources) {
        try {
            const d = new SourceDocument(r.text, r.id),declaration=specificationDeclaration(d.root.value);
            if (declaration.status==='supported')
                roots.push({ id: r.id, openapi: declaration.specification.declaredVersion, specification:declaration.specification, title: d.root.value.info?.title ?? r.id });
        }
        catch { }
    }
    return { roots };
}
