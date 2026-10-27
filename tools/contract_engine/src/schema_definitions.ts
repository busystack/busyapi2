/** Validation 2020-12 Appendix A retains definitions in the default meta-schema
 * and recommends the same unapplied-schema behavior as $defs. Modern OAS uses
 * those vocabularies. These are schema containers, never component namespaces. */
export type SchemaDefinitionKeyword='$defs'|'definitions';
export const schemaDefinitionKeywords:readonly SchemaDefinitionKeyword[]=Object.freeze(['$defs','definitions']);
export const isSchemaDefinitionKeyword=(value:unknown):value is SchemaDefinitionKeyword=>schemaDefinitionKeywords.some(keyword=>keyword===value);
