import Ajv2020 from 'ajv/dist/2020';
import schema30 from '../schemas/oas30.json';
import schema20 from '../schemas/oas20.json';
import draft04 from '../schemas/draft04.json';
import schema31 from '../schemas/oas31.json';
import schema32 from '../schemas/oas32.json';

const names: Record<string, string> = {
    Schema: 'schema', Reference: 'reference', MediaType: 'media-type', PathItem: 'path-item',
    RequestBody: 'request-body', SecurityScheme: 'security-scheme', ExternalDocumentation: 'external-documentation',
    ServerVariable: 'server-variable', OAuthFlows: 'oauth-flows', Callback: 'callbacks',
    pathItem: 'path-item', securityRequirement: 'security-requirement', externalDocs: 'external-documentation',
    primitivesItems: 'items', jsonReference: 'reference',
};
const definitionName = (name: string): string => names[name] ?? name.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase();

/** Bind the dated Draft 4 informational artifact to the existing structural
 * validator. Only trusted schema data is adapted; authored contracts never
 * undergo dialect conversion. The original publication remains unmodified. */
function bindDraft4(value: any): any {
    if (!value || typeof value !== 'object') return value;
    if (Array.isArray(value)) return value.map(bindDraft4);
    const output: Record<string, any> = {};
    for (const [key, child] of Object.entries(value)) {
        if (key === '$schema' || key === 'id' || key === 'exclusiveMinimum' || key === 'exclusiveMaximum') continue;
        if (key === 'definitions') output.$defs = Object.fromEntries(Object.entries(child).map(([name, definition]) => [definitionName(name), bindDraft4(definition)]));
        else if (key === '$ref' && typeof child === 'string' && child.startsWith('#/definitions/')) output.$ref = '#/$defs/' + definitionName(child.slice('#/definitions/'.length));
        else if (key === '$ref' && typeof child === 'string' && child.startsWith('http://json-schema.org/draft-04/schema#')) {
            const fragment=child.slice('http://json-schema.org/draft-04/schema'.length);
            output.$ref='urn:busyapi:structural:draft04'+(fragment.startsWith('#/definitions/')?'#/$defs/'+definitionName(fragment.slice('#/definitions/'.length)):fragment);
        }
        else if (key === 'dependencies') {
            for (const [name, dependency] of Object.entries(child)) {
                const field = Array.isArray(dependency) ? 'dependentRequired' : 'dependentSchemas';
                (output[field] ??= {})[name] = bindDraft4(dependency);
            }
        } else if (['properties', 'patternProperties'].includes(key))
            output[key] = Object.fromEntries(Object.entries(child).map(([name, definition]) => [name, bindDraft4(definition)]));
        else if (['allOf', 'anyOf', 'oneOf', 'items', 'additionalItems', 'additionalProperties', 'not'].includes(key)) output[key] = bindDraft4(child);
        else output[key] = child;
    }
    for (const [exclusive, bound] of [['exclusiveMinimum', 'minimum'], ['exclusiveMaximum', 'maximum']])
        if (value[exclusive] === true && typeof value[bound] === 'number') {output[exclusive] = value[bound]; delete output[bound];}
    return output;
}
const bound30 = bindDraft4(schema30);
bound30.$id = 'urn:busyapi:structural:3.0:2024-10-18';
// OAS 3.0 §4.7.7 requires the component-name pattern. The informational
// artifact leaves unmatched keys open. Bind name constraints separately from
// value constraints, avoiding Ajv 8.20's ordinary-object pattern tracker under
// Node's prototype guard. Only trusted schema assets are adapted here.
for(const name of Object.keys(bound30.$defs.components.properties)) {
    const map=bound30.$defs.components.properties[name];
    const patterns=Object.keys(map.patternProperties??{});
    if(map.type!=='object'||patterns.length!==1||Object.hasOwn(map,'additionalProperties'))
        throw new Error('Unexpected pinned OpenAPI 3.0 component-map schema');
    map.propertyNames={pattern:patterns[0]};
    map.additionalProperties=map.patternProperties[patterns[0]];
    delete map.patternProperties;
}
// OAS parameter/tag uniqueness is by semantic identity, not deep equality.
// The canonical relationship checks enforce those stronger normative rules.
// Ajv's deep-equality helper assumes Object.prototype methods, which canonical
// strict-JSON objects intentionally do not inherit. Do not clone/round numbers
// or change parser ownership merely to satisfy that helper.
delete bound30.properties.tags.uniqueItems;
delete bound30.$defs['path-item'].properties.parameters.uniqueItems;
delete bound30.$defs.operation.properties.parameters.uniqueItems;
// The fast JS projection cannot decide exact decimal positivity or value
// equality. restrictedSchemaIssues owns multipleOf positivity; the awaited
// exact-CST meta evaluator owns enum uniqueness (including object values).
delete bound30.$defs.schema.properties.multipleOf.exclusiveMinimum;
const bound20 = bindDraft4(schema20);
bound20.$id = 'urn:busyapi:structural:2.0:2017-08-27';
delete bound20.$defs['parameters-list'].uniqueItems;
delete bound20.$defs.security.uniqueItems;
const schemas: Readonly<Record<string, any>> = Object.freeze({'2.0': bound20, '3.0': bound30, '3.1': schema31, '3.2': schema32});
export const structuralSchema = (family: string): any => schemas[family];
export const structuralRevisions = Object.freeze({'2.0': '2017-08-27', '3.0': '2024-10-18', '3.1': '2026-08-03', '3.2': '2026-08-30'});
export const structuralEvaluator = new Ajv2020({strict: false, allErrors: true, validateFormats: false});
const boundDraft04 = bindDraft4(draft04);
boundDraft04.$id = 'urn:busyapi:structural:draft04';
delete boundDraft04.properties.multipleOf.exclusiveMinimum;
delete boundDraft04.properties.enum.uniqueItems;
structuralEvaluator.addSchema(boundDraft04);
export function structuralReference(reference:string,standard:any):any {
    const prefix='urn:busyapi:structural:draft04';
    const source=reference.startsWith(prefix)?boundDraft04:standard;
    const fragment=reference.startsWith(prefix)?reference.slice(prefix.length):reference;
    if(!fragment.startsWith('#/'))return;
    return fragment.slice(2).split('/').reduce((value:any,key:string)=>value?.[key.replaceAll('~1','/').replaceAll('~0','~')],source);
}
export const structuralValidators: Record<string, ReturnType<typeof structuralEvaluator.compile>> = {};
for (const [family, schema] of Object.entries(schemas))
    structuralValidators[family] = structuralEvaluator.compile(JSON.parse(JSON.stringify(schema).replaceAll('"$dynamicRef":"#meta"', '"$ref":"#/$defs/schema"')));

export function structuralDefinition(kind: string, family: string, value: any = {}, contextName = ''): any {
    const schema = structuralSchema(family);
    if (!schema) return undefined;
    if (kind === 'root') return schema;
    if (family === '2.0' && kind === 'parameter') {
        const name = value?.in === 'body' ? 'body-parameter' : ({query:'query-parameter-sub-schema',header:'header-parameter-sub-schema',path:'path-parameter-sub-schema',formData:'form-data-parameter-sub-schema'} as Record<string,string>)[value?.in];
        return name ? {...schema.$defs[name],required:[...new Set([...(schema.$defs[name].required??[]),'name','in',...(value.in==='body'?['schema']:['type'])])]} : schema.$defs.parameter;
    }
    if (family === '2.0' && kind === 'security') {
        const name = value?.type === 'basic' ? 'basic-authentication-security' : value?.type === 'apiKey' ? 'api-key-security' : value?.type === 'oauth2'
            ? ({implicit:'oauth2-implicit-security',password:'oauth2-password-security',application:'oauth2-application-security',accessCode:'oauth2-access-code-security'} as Record<string,string>)[value?.flow] : undefined;
        return name ? schema.$defs[name] : schema.$defs['security-definitions'].additionalProperties;
    }
    const name = ({security: 'security-scheme', media: 'media-type', callback: 'callbacks'} as Record<string, string>)[kind] ?? kind;
    if (family === '3.0' && kind === 'oauth-flow') {
        const flow = ({implicit: 'implicit-oauth-flow', password: 'password-oauth-flow', clientCredentials: 'client-credentials-flow', authorizationCode: 'authorization-code-oauth-flow'} as Record<string, string>)[contextName];
        return schema.$defs[flow];
    }
    return schema.$defs[name];
}
