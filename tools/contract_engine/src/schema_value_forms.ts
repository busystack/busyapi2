import {supportedSchemaDialect} from './reference_graph';
import type {GraphScope} from './reference_graph';
import type {Node} from './document';

export type SchemaValueForm = 'object' | 'boolean' | 'object-array';
export type SchemaValueForms = Readonly<{
    version: 1;
    supported: boolean;
    forms: readonly SchemaValueForm[];
}>;

const objectForms: SchemaValueForms = Object.freeze({version: 1, supported: true, forms: Object.freeze(['object'] as const)});
const booleanForms: SchemaValueForms = Object.freeze({version: 1, supported: true, forms: Object.freeze(['object', 'boolean'] as const)});
const tupleForms: SchemaValueForms = Object.freeze({version: 1, supported: true, forms: Object.freeze(['object', 'object-array'] as const)});
const unavailableForms: SchemaValueForms = Object.freeze({version: 1, supported: false, forms: Object.freeze([])});

/** Field value forms come from the containing schema occurrence, rather than
 * from a universal meaning for the presentation type "schema". OAS 3.0.4
 * §4.7.24.1 permits booleans only for additionalProperties; Swagger §6.4.18
 * retains Draft 4 tuple items with Schema Objects in place of JSON Schemas. */
export function schemaValueForms(scope: GraphScope, field: {name: string; type?: string}): SchemaValueForms | undefined {
    if (field.type !== 'schema') return;
    if (!supportedSchemaDialect(scope)) return unavailableForms;
    if (scope.family === '3.0') return field.name === 'additionalProperties' ? booleanForms : objectForms;
    if (scope.family === '2.0') return field.name === 'additionalProperties' ? booleanForms
        : scope.kind === 'schema' && field.name === 'items' ? tupleForms : objectForms;
    return booleanForms;
}

export function sameSchemaValueForms(expected: unknown, actual: SchemaValueForms): boolean {
    if (!expected || typeof expected !== 'object' || Array.isArray(expected)) return false;
    const value = expected as Record<string, unknown>;
    return value.version === actual.version && value.supported === actual.supported &&
        Array.isArray(value.forms) && value.forms.length === actual.forms.length &&
        value.forms.every((form, index) => form === actual.forms[index]);
}

export function allowsSchemaValue(forms: SchemaValueForms, node: Node): boolean {
    if (!forms.supported) return false;
    if (node.kind === 'object') return forms.forms.includes('object');
    if (typeof node.value === 'boolean') return forms.forms.includes('boolean');
    if (node.kind !== 'array' || !forms.forms.includes('object-array')) return false;
    for (const child of node.children.values()) if (child.kind !== 'object') return false;
    return true;
}
