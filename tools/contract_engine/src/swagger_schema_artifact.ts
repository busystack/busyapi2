import schema20 from '../schemas/oas20.json';

export const swaggerSchemaRulesRevision = '1';

const definition = schema20.definitions.schema;
const field = definition.properties.items;
const tuple = field.anyOf.find(branch => 'type' in branch);
if (!tuple || !('type' in tuple) || tuple.type !== 'array' ||
    !('minItems' in tuple) || tuple.minItems !== 1 ||
    !('items' in tuple) || tuple.items.$ref !== '#/definitions/schema' || Object.keys(tuple).length !== 3)
    throw new Error('Unexpected pinned Swagger tuple items artifact');

/** Swagger §6.4.18 adopts Draft 4 validation §5.3.1.1 with Schema Object
 * substitutions. That text does not require a nonempty items array. Remove
 * only the informational artifact's extra minimum, for both validator owners;
 * composition arrays and flat Parameter/Header/Items remain unchanged. */
export const swaggerSchemaArtifact = {
    ...schema20,
    definitions: {...schema20.definitions, schema: {...definition, properties: {
        ...definition.properties,
        items: {...field, anyOf: field.anyOf.map(branch => branch === tuple ? {type: tuple.type, items: tuple.items} : branch)},
    }}},
};
