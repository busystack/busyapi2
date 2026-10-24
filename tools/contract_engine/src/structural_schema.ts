import Ajv2020 from 'ajv/dist/2020';
import schema30 from '../schemas/oas30.json';
import schema31 from '../schemas/oas31.json';
import schema32 from '../schemas/oas32.json';

const names: Record<string, string> = {
    Schema: 'schema', Reference: 'reference', MediaType: 'media-type', PathItem: 'path-item',
    RequestBody: 'request-body', SecurityScheme: 'security-scheme', ExternalDocumentation: 'external-documentation',
    ServerVariable: 'server-variable', OAuthFlows: 'oauth-flows', Callback: 'callbacks',
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
// OAS parameter/tag uniqueness is by semantic identity, not deep equality.
// The canonical relationship checks enforce those stronger normative rules.
// Ajv's deep-equality helper assumes Object.prototype methods, which canonical
// strict-JSON objects intentionally do not inherit. Do not clone/round numbers
// or change parser ownership merely to satisfy that helper.
delete bound30.properties.tags.uniqueItems;
delete bound30.$defs['path-item'].properties.parameters.uniqueItems;
delete bound30.$defs.operation.properties.parameters.uniqueItems;
const schemas: Readonly<Record<string, any>> = Object.freeze({'3.0': bound30, '3.1': schema31, '3.2': schema32});
export const structuralSchema = (family: string): any => schemas[family];
export const structuralRevisions = Object.freeze({'3.0': '2024-10-18', '3.1': '2025-09-15', '3.2': '2025-09-17'});
export const structuralEvaluator = new Ajv2020({strict: false, allErrors: true, validateFormats: false});
export const structuralValidators: Record<string, ReturnType<typeof structuralEvaluator.compile>> = {};
for (const [family, schema] of Object.entries(schemas))
    structuralValidators[family] = structuralEvaluator.compile(JSON.parse(JSON.stringify(schema).replaceAll('"$dynamicRef":"#meta"', '"$ref":"#/$defs/schema"')));

export function structuralDefinition(kind: string, family: string, value: any = {}, contextName = ''): any {
    const schema = structuralSchema(family);
    if (!schema) return undefined;
    if (kind === 'root') return schema;
    const name = ({security: 'security-scheme', media: 'media-type', callback: 'callbacks'} as Record<string, string>)[kind] ?? kind;
    if (family === '3.0' && kind === 'oauth-flow') {
        const flow = ({implicit: 'implicit-oauth-flow', password: 'password-oauth-flow', clientCredentials: 'client-credentials-flow', authorizationCode: 'authorization-code-oauth-flow'} as Record<string, string>)[contextName];
        return schema.$defs[flow];
    }
    return schema.$defs[name];
}
