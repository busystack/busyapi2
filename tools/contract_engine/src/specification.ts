/** Document declarations and schema dialects are separate identities. OAS
 * patch versions share their minor family's rules (OAS §Versions). */
export type SpecificationFamily = '3.0' | '3.1' | '3.2';
export type Specification = Readonly<{
    family: SpecificationFamily;
    declaredVersion: string;
    declaration: 'openapi';
    schemaDialect: string;
    capabilities: Readonly<{
        modernSchema: boolean; webhooks: boolean; reusablePathItems: boolean;
        additionalOperations: boolean; referenceAnnotations: boolean;
    }>;
}>;
export type SpecificationDeclaration =
    {status: 'supported'; specification: Specification} |
    {status: 'missing' | 'malformed' | 'unsupported' | 'conflicting'; code: string; pointer: string; message: string};

export const nativeFamilies: readonly SpecificationFamily[] = Object.freeze(['3.0', '3.1', '3.2']);
export const isNativeFamily = (family: string): family is SpecificationFamily => nativeFamilies.some(candidate => candidate === family);
export const restrictedSchemaDialect = 'https://spec.openapis.org/oas/3.0/dialect';
export const modernFamily = (family: string): boolean => family === '3.1' || family === '3.2';
export const defaultSchemaDialect = (family: string): string => family === '3.0'
    ? restrictedSchemaDialect : `https://spec.openapis.org/oas/${family}/dialect/base`;

export function specificationDeclaration(value: unknown): SpecificationDeclaration {
    const data = value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
    if (Object.hasOwn(data, 'openapi') && Object.hasOwn(data, 'swagger'))
        return {status: 'conflicting', code: 'version.conflicting', pointer: '/swagger', message: 'Declare exactly one specification version field: openapi or swagger'};
    if (!Object.hasOwn(data, 'openapi')) return Object.hasOwn(data, 'swagger')
        ? {status: 'unsupported', code: 'version.unsupported', pointer: '/swagger', message: 'This Swagger specification family is not yet available for native authoring'}
        : {status: 'missing', code: 'version.missing', pointer: '', message: 'Declare the OpenAPI specification version; info.version identifies the API, not its specification'};
    if (typeof data.openapi !== 'string' || !/^\d+\.\d+\.\d+$/.test(data.openapi))
        return {status: 'malformed', code: 'version.malformed', pointer: '/openapi', message: 'openapi must be a version string such as 3.0.4, 3.1.2 or 3.2.1'};
    const family = data.openapi.slice(0, data.openapi.lastIndexOf('.'));
    if (!isNativeFamily(family))
        return {status: 'unsupported', code: 'version.unsupported', pointer: '/openapi', message: 'Native authoring supports OpenAPI 3.0.x, 3.1.x and 3.2.x'};
    return {status: 'supported', specification: Object.freeze({
        family, declaredVersion: data.openapi, declaration: 'openapi',
        schemaDialect: modernFamily(family) && typeof data.jsonSchemaDialect === 'string' ? data.jsonSchemaDialect : defaultSchemaDialect(family),
        capabilities: Object.freeze({modernSchema: modernFamily(family), webhooks: modernFamily(family), reusablePathItems: modernFamily(family), additionalOperations: family === '3.2', referenceAnnotations: modernFamily(family)}),
    })};
}
