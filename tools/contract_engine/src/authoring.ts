import Ajv2020 from 'ajv/dist/2020';
import {structuralSchema, structuralDefinition} from './structural_schema';
import {modernFamily} from './specification';
import type {ReferenceGraph,GraphScope} from './reference_graph';
import {escape} from './document';
import {isReferenceObject,referenceKinds} from './contexts';

// This shared description supplies native fields, Source assistance and help.
// Structural artifacts describe field shapes, not complete OAS semantics.
const evaluator = new Ajv2020({strict: false, validateFormats: false});
const conditions = new Map<any, any>();
const names: Record<string, string> = {security: 'security-scheme', media: 'media-type', callback: 'callbacks', 'path-item': 'path-item', 'request-body': 'request-body'};
export function componentFamily(kind:string,family:string):string|undefined {
    if(kind==='media'&&family!=='3.2')return;
    if(kind==='path-item'&&!modernFamily(family))return;
    return ({schema:'schemas',parameter:'parameters',header:'headers',response:'responses','request-body':'requestBodies',example:'examples',link:'links',callback:'callbacks','path-item':'pathItems',media:'mediaTypes',security:'securitySchemes'} as Record<string,string>)[kind];
}
/** Resource-relative authored URIs and the Server retrieval-relative URL.
 * Security discovery and OAuth endpoints are API URLs: OAS resolves those
 * against the applicable Server URL, not the document/schema identity. */
export function documentUriFields(kind:string,value?:any):readonly string[] {
    // A Reference Object's ignored preserved siblings are not declarations.
    // Among these URI-bearing kinds, only Example supports Reference Objects.
    if(kind==='example'&&typeof value?.$ref==='string')return [];
    return ({info:['termsOfService'],contact:['url'],license:['url'],'external-documentation':['url'],example:['externalValue'],server:['url']} as Record<string,string[]>)[kind]??[];
}
/** Passive authored URI positions, not dependency requests or reference edges.
 * Typed graph occurrences exclude example/extension payloads. In particular,
 * listing externalValue never reads, parses or fetches serialized example data. */
export function* documentUriOccurrences(graph:ReferenceGraph):Generator<{scope:GraphScope;pointer:string;field:string;value:string}> {
    for(const scope of graph.scopes.values()){
        const doc=graph.docs.get(scope.resource)!,node=doc.dataNode(scope.pointer);
        for(const field of documentUriFields(scope.kind,node?.value)){
            const pointer=scope.pointer+'/'+escape(field),value=doc.dataNode(pointer)?.value;
            if(typeof value==='string')yield {scope,pointer,field,value};
        }
    }
}
/** Presentation metadata is attached only to an established standard field,
 * never an arbitrary payload property that happens to be called description. */
export function richTextField(kind:string,family:string,value:any,name:string,contextName=''):boolean {
    return name==='description'&&fieldsFor(kind,family,value,contextName).some(field=>field.name===name&&field.type==='string');
}
/** OAS Specification Extensions apply only at declared object positions, not
 * arbitrary string-keyed maps or OpenAPI Reference Objects. Schema Objects
 * also allow unknown vocabulary keywords. Payloads remain opaque data. */
export function allowsExtensions(kind: string, family: string, value: any, contextName = ''): boolean {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
    if (kind === 'schema') return true;
    if (typeof value.$ref === 'string' && kind !== 'path-item') return false;
    if (['xml', 'discriminator', 'callback', 'path-map', 'response-map'].includes(kind)) return true;
    const standard = structuralSchema(family);
    if (!standard) return false;
    let target = structuralDefinition(kind, family, value, contextName);
    if (kind === 'oauth-flow') {
        if (family === '3.0') return !!target?.patternProperties?.['^x-'];
        const key = ({clientCredentials: 'client-credentials', authorizationCode: 'authorization-code', deviceAuthorization: 'device-authorization'} as any)[contextName] ?? contextName;
        target = standard.$defs['oauth-flows'].$defs[key];
    }
    const seen = new Set<any>();
    const visit = (node: any): boolean => {
        if (!node || seen.has(node)) return false;
        seen.add(node);
        if (node.patternProperties?.['^x-']) return true;
        if (node.$ref === '#/$defs/specification-extensions') return true;
        if (node.$ref?.startsWith('#/') && visit(node.$ref.slice(2).split('/').reduce((v: any, k: string) => v?.[k], standard))) return true;
        return (node.allOf ?? []).some(visit);
    };
    return visit(target);
}
export function removableField(kind: string, family: string, value: any, name: string, contextName = ''): boolean {
    if (kind.endsWith('-map') || kind.endsWith('-array') || ['callback','security-requirement'].includes(kind)) return true;
    const field = fieldsFor(kind, family, value, contextName).find(f => f.name === name);
    return !!field && !field.required;
}
export function fieldsFor(kind: string, family: string, value: any = {}, contextName = ''): any[] {
    const standard = structuralSchema(family);
    if (!standard) return [];
    const target = structuralDefinition(kind, family, value, contextName);
    if (isReferenceObject(value,kind,family)) return (modernFamily(family) ? ['$ref', 'summary', 'description'] : ['$ref']).map(name => ({name, type: 'string'}));
    if (kind === 'schema' && modernFamily(family)) return schemaFields();
    // These annotations are defined by the OAS vocabulary, outside the
    // structural artifact's schema meta slot (OAS 3.1/3.2 XML/Discriminator).
    if (kind === 'discriminator') return [
        {name: 'propertyName', type: 'string', required: true}, {name: 'mapping', type: 'object'},
        ...(family === '3.2' ? [{name: 'defaultMapping', type: 'string'}] : []),
    ];
    if (kind === 'xml') return [
        ...['name', 'namespace', 'prefix'].map(name => ({name, type: 'string'})),
        ...['attribute', 'wrapped'].map(name => ({name, type: 'boolean', ...(family === '3.1' ? {effectiveDefault: false} : {}), blockedBy: family === '3.2' && Object.hasOwn(value, 'nodeType') ? ['nodeType'] : []})),
        ...(family === '3.2' ? [{name: 'nodeType', type: 'string', options: ['element','attribute','text','cdata','none'], blockedBy: ['attribute','wrapped'].filter(name => Object.hasOwn(value, name))}] : []),
    ];
    if (kind === 'oauth-flow') {
        const key = ({clientCredentials: 'client-credentials', authorizationCode: 'authorization-code', deviceAuthorization: 'device-authorization'} as any)[contextName] ?? contextName;
        const definition = family === '3.0' ? target : standard.$defs['oauth-flows'].$defs[key];
        return Object.entries(definition?.properties ?? {}).map(([name, field]) => ({...describe(name, field, standard), required: definition.required?.includes(name) === true}));
    }
    if (!target) return [];
    const properties = new Map<string, any>();
    const prohibited = new Map<string, Set<string>>();
    const exclusions: string[][] = [];
    const required = new Set<string>();
    const seen = new Set<any>();
    const collect = (schema: any, causes: string[] = []) => {
        if (!schema || seen.has(schema)) return;
        seen.add(schema);
        if (schema.$ref?.startsWith('#/')) collect(schema.$ref.slice(2).split('/').reduce((v: any, k: string) => v[k], standard), causes);
        for (const [name, property] of Object.entries(schema.properties ?? {})) {
            if (property === false) {
                const blocked = prohibited.get(name) ?? new Set<string>();
                for (const cause of causes) blocked.add(cause);
                prohibited.set(name, blocked);
            } else {
                const field = describe(name, property, standard), previous = properties.get(name);
                // allOf/dependent schemas refine a field; a default-only
                // refinement must not erase its type or earlier restrictions.
                properties.set(name, {...previous, ...field,
                    ...(previous?.options && field.options ? {options: previous.options.filter((v: any) => field.options.includes(v))} : {})});
            }
        }
        for (const name of schema.required ?? []) required.add(name);
        if (Array.isArray(schema.not?.required)) exclusions.push(schema.not.required);
        for (const child of schema.allOf ?? []) collect(child, causes);
        // The 3.0 artifact expresses location/type refinements with oneOf.
        // Select by the authored discriminator without validating an unfinished
        // form as a complete object. With no choice yet, expose the choice.
        if (family === '3.0' && schema.oneOf) {
            const alternatives = schema.oneOf.map((branch: any) => branch.$ref?.startsWith('#/')
                ? branch.$ref.slice(2).split('/').reduce((v: any, k: string) => v?.[k], standard) : branch);
            const selector = kind === 'parameter' ? 'in' : kind === 'security' ? 'type' : undefined;
            if (selector && value?.[selector] !== undefined) {
                const selected = alternatives.filter((branch: any) => branch.properties?.[selector]?.enum?.includes(value[selector]));
                for (const branch of selected) collect(branch, causes);
            } else if (selector) {
                const options = alternatives.flatMap((branch: any) => branch.properties?.[selector]?.enum ?? []);
                properties.set(selector, {...properties.get(selector), name: selector, type: 'string', options: [...new Set(options)]});
                required.add(selector);
            }
        }
        for (const [name, child] of Object.entries(schema.dependentSchemas ?? {})) if (Object.hasOwn(value, name)) collect(child, [...causes, name]);
        if (schema.if) {
            let validate = conditions.get(schema.if);
            if (!validate) { validate = evaluator.compile(schema.if); conditions.set(schema.if, validate); }
            collect(validate(value) ? schema.then : schema.else, causes);
        }
    };
    collect(target);
    const fields = [...properties.values()];
    if (kind === 'schema' && !modernFamily(family)) {
        fields.unshift({name: '$ref', type: 'string'});
        for (const field of fields) {
            if (['items', 'additionalProperties', 'not'].includes(field.name)) field.type = 'schema';
            if (['allOf', 'oneOf', 'anyOf'].includes(field.name)) field.type = 'array';
        }
        if (value?.type === 'array') required.add('items');
    }
    if (kind === 'parameter' && family === '3.0') {
        const location = fields.find(field => field.name === 'in');
        if (location) location.options = ['path', 'query', 'header', 'cookie'];
    }
    // A newly created specification object can deliberately choose the
    // Reference Object alternative before authoring incompatible inline
    // fields. Reuse the graph's position/version boundary; payload/metadata
    // keys never acquire reference semantics. Existing inline content still
    // requires extraction/removal rather than an implicit destructive switch.
    if (referenceKinds.has(kind) && kind !== 'schema' && kind !== 'path-item' &&
        (kind !== 'media' || family === '3.2') && value && typeof value === 'object' && !Array.isArray(value) &&
        Object.keys(value).every(name => ['summary','description'].includes(name)) && !fields.some(field => field.name === '$ref'))
        fields.unshift({name:'$ref',type:'string'});
    if (kind === 'parameter' && value.in === 'path') {
        const field = fields.find(f => f.name === 'required');
        if (field) {field.options = [true]; delete field.effectiveDefault; required.add('required');}
    }
    if (kind === 'parameter' && Object.hasOwn(value, 'schema')) {
        const style = value.style ?? (['query', 'cookie'].includes(value.in) ? 'form' : 'simple');
        const explode = fields.find(f => f.name === 'explode');
        if (explode) {
            explode.effectiveDefault = style === 'form' || family === '3.2' && style === 'cookie';
            if (family === '3.2' && value.in === 'cookie') explode.options = [true];
        }
    }
    if (kind === 'parameter' && family === '3.2' && value.in === 'querystring') {
        for (const name of ['schema','style','explode','allowReserved']) prohibited.set(name, new Set(['in']));
    }
    // Some normative relationships are not expressed in the informational
    // structural artifact. Keep these alongside its shared field description.
    if (['parameter','header'].includes(kind)) exclusions.push(['schema','content']);
    if (['parameter','header','media'].includes(kind)) exclusions.push(['example','examples']);
    if (['media','encoding'].includes(kind) && family === '3.2') exclusions.push(['encoding','prefixEncoding'], ['encoding','itemEncoding']);
    if (kind === 'link') exclusions.push(['operationRef','operationId']);
    if (kind === 'license') exclusions.push(['identifier','url']);
    return fields.map(field => {
        const blocked = new Set(prohibited.get(field.name));
        for (const group of exclusions) if (group.includes(field.name)) {
            const others = group.filter(name => name !== field.name);
            if (others.length && others.every(name => Object.hasOwn(value, name))) for (const name of others) blocked.add(name);
        }
        return {...field, type: field.type ?? 'any', required: required.has(field.name), ...(prohibited.has(field.name) ? {prohibited: true} : {}), blockedBy: [...blocked]};
    });
}
function describe(name: string, field: any, standard: any) {
    if (field === true) return {name, type: 'any'};
    const seen = new Set<any>();
    while (field.$ref?.startsWith('#/') && !seen.has(field)) {
        seen.add(field);
        const referenced = field.$ref.slice(2).split('/').reduce((v: any, k: string) => v[k], standard);
        if (!referenced) break;
        field = {...referenced, ...Object.fromEntries(Object.entries(field).filter(([key]) => key !== '$ref'))};
    }
    return {name, ...(field.type || field.enum || Object.hasOwn(field, 'const') || field.$dynamicRef || field.$ref ? {type: field.type ?? (field.enum ? typeof field.enum[0] : Object.hasOwn(field, 'const') ? typeof field.const : field.$dynamicRef ? 'schema' : 'object')} : {}),
        ...(field.enum ? {options: field.enum} : Object.hasOwn(field, 'const') ? {options: [field.const]} : {}), ...(Object.hasOwn(field, 'default') ? {effectiveDefault: field.default} : {})};
}
function schemaFields() {
    const groups: Record<string, string[]> = {
        string: ['$id', '$schema', '$anchor', '$dynamicAnchor', '$ref', '$dynamicRef', '$comment', 'title', 'description', 'format', 'pattern', 'contentEncoding', 'contentMediaType'],
        boolean: ['readOnly', 'writeOnly', 'deprecated', 'uniqueItems'],
        number: ['minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf'],
        integer: ['minLength', 'maxLength', 'minProperties', 'maxProperties', 'minItems', 'maxItems', 'minContains', 'maxContains'],
        object: ['properties', 'patternProperties', '$defs', 'dependentSchemas', 'dependentRequired', 'discriminator', 'xml'],
        array: ['required', 'enum', 'examples', 'allOf', 'anyOf', 'oneOf', 'prefixItems'],
        schema: ['items', 'contains', 'additionalProperties', 'unevaluatedProperties', 'unevaluatedItems', 'propertyNames', 'not', 'if', 'then', 'else', 'contentSchema'],
        any: ['type', 'const', 'default', 'example'],
    };
    return Object.entries(groups).flatMap(([type, names]) => names.map(name => ({name, type})));
}
