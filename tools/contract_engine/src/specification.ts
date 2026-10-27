import {isUri} from '@hyperjump/uri';

/** Document declarations and schema dialects are separate identities. OAS
 * patch versions share their minor family's rules (OAS §Versions). */
export const dialectUriRevision='1';
export type SpecificationFamily = '2.0' | '3.0' | '3.1' | '3.2';
export type SpecificationCapabilities = Readonly<{
    modernSchema: boolean; webhooks: boolean; reusablePathItems: boolean;
    additionalOperations: boolean; referenceAnnotations: boolean;
    securityRequirementUris: boolean;
}>;
export type Specification = Readonly<{
    family: SpecificationFamily;
    declaredVersion: string;
    declaration: 'openapi' | 'swagger';
    schemaDialect: string|null;
    capabilities: SpecificationCapabilities;
}>;
export type SpecificationDeclaration =
    {status: 'supported'; specification: Specification} |
    {status: 'missing' | 'malformed' | 'unsupported' | 'conflicting'; code: string; pointer: string; message: string};

export const nativeFamilies: readonly SpecificationFamily[] = Object.freeze(['2.0', '3.0', '3.1', '3.2']);
export const isNativeFamily = (family: string): family is SpecificationFamily => nativeFamilies.some(candidate => candidate === family);
export const restrictedSchemaDialect = 'https://spec.openapis.org/oas/3.0/dialect';
export const swaggerSchemaDialect = 'urn:busyapi:schema-dialect:swagger-2.0';
export const modernFamily = (family: string): boolean => family === '3.1' || family === '3.2';
const familyCapabilities = (family: SpecificationFamily): SpecificationCapabilities => Object.freeze({
    modernSchema: modernFamily(family), webhooks: modernFamily(family), reusablePathItems: modernFamily(family),
    additionalOperations: family === '3.2', referenceAnnotations: modernFamily(family), securityRequirementUris: family === '3.2',
});
const capabilities:Readonly<Record<SpecificationFamily,SpecificationCapabilities>>=Object.freeze({
    '2.0':familyCapabilities('2.0'),'3.0':familyCapabilities('3.0'),
    '3.1':familyCapabilities('3.1'),'3.2':familyCapabilities('3.2'),
});
export const capabilitiesFor = (family:SpecificationFamily):SpecificationCapabilities => capabilities[family];
export const defaultSchemaDialect = (family: string): string => family === '2.0' ? swaggerSchemaDialect : family === '3.0'
    ? restrictedSchemaDialect : `https://spec.openapis.org/oas/${family}/dialect/base`;

/** JSON Schema Core 8.1.1 / OAS OpenAPI Object: an explicit dialect must be
 * a URI with a scheme. The pinned RFC 3986 validator allows URI fragments;
 * the ASCII guard also rejects trailing line terminators before a JS $ anchor.
 * Null is an unavailable selection, never permission to use the OAS default. */
export function declaredSchemaDialect(value:unknown):string|null {
    if(typeof value!=='string'||/[^\x21-\x7e]/u.test(value))return null;
    try{return isUri(value)?value:null;}
    catch(error){
        // URI 1.3.9 throws for IPvFuture only after matching RFC 3986
        // grammar. Retain that explicit identifier; the dialect registry
        // reports unsupported evaluation instead of choosing a fallback.
        if(!(error instanceof Error)||!error.message.startsWith('Unsupported IP version in host: '))throw error;
        return value;
    }
}

export function specificationDeclaration(value: unknown): SpecificationDeclaration {
    const data = value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
    if (Object.hasOwn(data, 'openapi') && Object.hasOwn(data, 'swagger'))
        return {status: 'conflicting', code: 'version.conflicting', pointer: '/swagger', message: 'Declare exactly one specification version field: openapi or swagger'};
    if (Object.hasOwn(data, 'swagger')) {
        if (data.swagger !== '2.0') return {status: typeof data.swagger === 'string' ? 'unsupported' : 'malformed', code: typeof data.swagger === 'string' ? 'version.unsupported' : 'version.malformed', pointer: '/swagger', message: 'swagger must declare the supported string version "2.0"'};
        return {status: 'supported', specification: Object.freeze({family: '2.0', declaredVersion: '2.0', declaration: 'swagger', schemaDialect: swaggerSchemaDialect,
            capabilities: capabilitiesFor('2.0')})};
    }
    if (!Object.hasOwn(data, 'openapi')) return {status: 'missing', code: 'version.missing', pointer: '', message: 'Declare openapi or swagger; info.version identifies the API, not its specification'};
    if (typeof data.openapi !== 'string' || !/^\d+\.\d+\.\d+$/.test(data.openapi))
        return {status: 'malformed', code: 'version.malformed', pointer: '/openapi', message: 'openapi must be a version string such as 3.0.4, 3.1.2 or 3.2.1'};
    const family = data.openapi.slice(0, data.openapi.lastIndexOf('.'));
    if (!isNativeFamily(family) || family === '2.0')
        return {status: 'unsupported', code: 'version.unsupported', pointer: '/openapi', message: 'Native authoring supports swagger: "2.0" and OpenAPI 3.0.x, 3.1.x and 3.2.x'};
    return {status: 'supported', specification: Object.freeze({
        family, declaredVersion: data.openapi, declaration: 'openapi',
        // Only absence selects the OAS default. A malformed declaration has no
        // evaluable dialect, while a well-formed unknown URI stays explicit.
        schemaDialect: modernFamily(family)&&Object.hasOwn(data,'jsonSchemaDialect') ? declaredSchemaDialect(data.jsonSchemaDialect) : defaultSchemaDialect(family),
        capabilities: capabilitiesFor(family),
    })};
}
