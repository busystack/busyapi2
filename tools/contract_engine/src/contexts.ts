import {modernFamily} from './specification';

export type Child = [
    string,
    any,
    string
];
const methods31 = Object.freeze(['get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace']);
const methods32 = Object.freeze([...methods31, 'query']);
export const standardOperationMethods = (family: string): readonly string[] => family === '3.2' ? methods32 : methods31;
// Only specification positions carry references; payloads and metadata do not.
export function children(value: any, kind: string, family = '3.2'): Child[] {
    if (!value || typeof value !== 'object')
        return [];
    const out: Child[] = [];
    const one = (key: string, next: string) => {
        if (Object.hasOwn(value, key))
            out.push([key, value[key], next]);
    };
    const entries = (next: string) => Object.entries(value).forEach(([k, v]) => out.push([k, v, next]));
    switch (kind) {
        case 'root':
            one('info', 'info');
            one('servers', 'server-array');
            one('security', 'security-array');
            one('tags', 'tag-array');
            one('externalDocs', 'external-documentation');
            one('paths', 'path-map');
            if (modernFamily(family)) one('webhooks', 'webhook-map');
            one('components', 'components');
            break;
        case 'info':
            one('contact', 'contact');
            one('license', 'license');
            break;
        case 'server-array': entries('server'); break;
        case 'server': one('variables', 'server-variable-map'); break;
        case 'server-variable-map': entries('server-variable'); break;
        case 'server-variable': one('enum', 'string-array'); break;
        case 'security-array': entries('security-requirement'); break;
        case 'security-requirement': entries('string-array'); break;
        case 'tag-array': entries('tag'); break;
        case 'tag': one('externalDocs', 'external-documentation'); break;
        case 'components':
            for (const [key, next] of Object.entries({ schemas: 'schema-map', parameters: 'parameter-map', responses: 'response-component-map', headers: 'header-map', requestBodies: 'body-map', examples: 'example-map', links: 'link-map', callbacks: 'callback-map', ...(modernFamily(family) ? {pathItems: 'path-item-component-map'} : {}), securitySchemes: 'security-map' }))
                one(key, next);
            if (family === '3.2')
                one('mediaTypes', 'content-map');
            break;
        case 'path-map':
            Object.entries(value).filter(([k]) => !k.startsWith('x-')).forEach(([k, v]) => out.push([k, v, 'path-item']));
            break;
        case 'webhook-map':
        case 'path-item-component-map':
            entries('path-item');
            break;
        case 'path-item':
            one('servers', 'server-array');
            for (const key of standardOperationMethods(family))
                one(key, 'operation');
            if (family === '3.2')
                one('additionalOperations', 'operation-map');
            one('parameters', 'parameter-array');
            break;
        case 'operation-map':
            entries('operation');
            break;
        case 'operation':
            one('tags', 'string-array');
            one('servers', 'server-array');
            one('security', 'security-array');
            one('externalDocs', 'external-documentation');
            one('parameters', 'parameter-array');
            one('requestBody', 'request-body');
            one('responses', 'response-map');
            one('callbacks', 'callback-map');
            break;
        case 'parameter-array':
        case 'parameter-map':
            entries('parameter');
            break;
        case 'header-map':
            entries('header');
            break;
        case 'response-map':
            Object.entries(value).filter(([k]) => !k.startsWith('x-')).forEach(([k, v]) => out.push([k, v, 'response']));
            break;
        case 'response-component-map':
            entries('response');
            break;
        case 'body-map':
            entries('request-body');
            break;
        case 'response':
            one('headers', 'header-map');
            one('content', 'content-map');
            one('links', 'link-map');
            break;
        case 'parameter':
        case 'header':
            one('schema', 'schema');
            one('content', 'content-map');
            one('examples', 'example-map');
            break;
        case 'request-body':
            one('content', 'content-map');
            break;
        case 'content-map':
            entries('media');
            break;
        case 'media':
            one('schema', 'schema');
            if (family === '3.2') {
                one('itemSchema', 'schema');
                one('prefixEncoding', 'encoding-array');
                one('itemEncoding', 'encoding');
            }
            one('examples', 'example-map');
            one('encoding', 'encoding-map');
            break;
        case 'encoding-array':
        case 'encoding-map':
            entries('encoding');
            break;
        case 'encoding':
            one('headers', 'header-map');
            if (family === '3.2') {
                one('encoding', 'encoding-map');
                one('prefixEncoding', 'encoding-array');
                one('itemEncoding', 'encoding');
            }
            break;
        case 'example-map':
            entries('example');
            break;
        case 'link-map':
            entries('link');
            break;
        case 'link': one('server', 'server'); break;
        case 'callback-map':
            entries('callback');
            break;
        case 'callback':
            Object.entries(value).filter(([k]) => !k.startsWith('x-')).forEach(([k, v]) => out.push([k, v, 'path-item']));
            break;
        case 'security-map':
            entries('security');
            break;
        case 'security': one('flows', 'oauth-flows'); break;
        case 'oauth-flows':
            for (const flow of ['implicit', 'password', 'clientCredentials', 'authorizationCode', ...(family === '3.2' ? ['deviceAuthorization'] : [])]) one(flow, 'oauth-flow');
            break;
        case 'oauth-flow': one('scopes', 'string-map'); break;
        case 'discriminator': one('mapping', 'discriminator-map'); break;
        case 'schema-map':
        case 'schema-array':
            entries('schema');
            break;
        case 'schema':
            one('discriminator', 'discriminator');
            one('xml', 'xml');
            one('externalDocs', 'external-documentation');
            for (const k of ['properties', ...(modernFamily(family) ? ['patternProperties', '$defs', 'dependentSchemas'] : [])])
                one(k, 'schema-map');
            for (const k of ['items', ...(typeof value.additionalProperties === 'boolean' && !modernFamily(family) ? [] : ['additionalProperties']), 'not', ...(modernFamily(family) ? ['unevaluatedProperties', 'unevaluatedItems', 'contains', 'propertyNames', 'if', 'then', 'else', 'contentSchema'] : [])])
                one(k, 'schema');
            for (const k of ['allOf', 'anyOf', 'oneOf', ...(modernFamily(family) ? ['prefixItems'] : [])])
                one(k, 'schema-array');
            break;
    }
    return out;
}
export const referenceKinds = new Set(['path-item', 'response', 'parameter', 'header', 'request-body', 'example', 'link', 'callback', 'security', 'media', 'schema']);
// Shared traversal/projection boundary. Schema applicators and Path Item
// references keep their own sibling rules; other Reference Object siblings
// cannot become object definitions merely because their keys look familiar.
export function isReferenceObject(value:any,kind:string,family:string):boolean {
    return referenceKinds.has(kind) && (kind !== 'schema' || !modernFamily(family)) && kind !== 'path-item' &&
        (kind !== 'media' || family === '3.2') && typeof value?.$ref === 'string';
}
