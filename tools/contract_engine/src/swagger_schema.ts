import {registerSchema} from '@hyperjump/json-schema/draft-04';
import {defineVocabulary,loadDialect} from '@hyperjump/json-schema/experimental';
import schema20 from '../schemas/oas20.json';
import {swaggerSchemaDialect} from './specification';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import {swaggerDiscriminatorKeyword} from './swagger_discriminator';
import {isReferenceObject} from './contexts';
import {swaggerFileContexts} from './swagger_file';

export const swaggerMetaIdentity='http://swagger.io/v2/schema.json';

/** The OAS 2.0 listed Draft 4 subset, not a modern JSON Schema dialect and
 * not an invented source declaration. The identifier is internal evaluation
 * context; it is never written into an authored contract (2.0 §6.4.18). */
export function installSwaggerSchemaDialect():void {
    const keyword=(name:string)=>'https://json-schema.org/keyword/'+name;
    const ordinary=['additionalProperties','allOf','default','description','enum','maxItems','maxLength','maxProperties','minItems','minLength','minProperties','multipleOf','pattern','properties','readOnly','required','title','type','uniqueItems'];
    const vocabulary:Record<string,string>=Object.fromEntries(ordinary.map(name=>[name,keyword(name)]));
    vocabulary.discriminator=swaggerDiscriminatorKeyword;
    for(const name of ['$ref','exclusiveMaximum','exclusiveMinimum','format','items','maximum','minimum'])
        vocabulary[name]=keyword('draft-04/'+(name==='$ref'?'ref':name));
    defineVocabulary(swaggerSchemaDialect,vocabulary);
    loadDialect(swaggerSchemaDialect,{[swaggerSchemaDialect]:true},true);
    registerSchema(schema20);
    registerSchema({id:swaggerSchemaDialect,$schema:'http://json-schema.org/draft-04/schema#',$ref:swaggerMetaIdentity+'#/definitions/schema'});
}

export type SchemaEvaluationScope=GraphScope&{objectKind:string;file?:boolean};
/** Flat Parameter/Header/Items validation retains its physical graph owner.
 * This projection selects an evaluator address; it adds no reference edges,
 * identities, source objects or competing API model. */
export function schemaEvaluationScopes(graph:ReferenceGraph):SchemaEvaluationScope[] {
    const scopes:SchemaEvaluationScope[]=[],{contexts}=swaggerFileContexts(graph);
    for(const scope of graph.scopes.values()) {
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        const flat=scope.family==='2.0'&&(scope.kind==='parameter'&&value?.in!=='body'&&typeof value?.$ref!=='string'||['header','items'].includes(scope.kind));
        if(scope.kind!=='schema'&&!flat)continue;
        const fileContext=scope.kind==='parameter'&&value?.in==='formData'||contexts.has(scope.resource+'#'+scope.pointer);
        scopes.push({...scope,kind:'schema',objectKind:scope.kind,file:scope.family==='2.0'&&fileContext&&value?.type==='file'&&!isReferenceObject(value,'schema',scope.family)});
    }
    return scopes;
}
export function swaggerMetaAddress(scope:SchemaEvaluationScope):string {
    return swaggerMetaIdentity+'#/definitions/'+(scope.objectKind==='parameter'?'nonBodyParameter':scope.objectKind==='items'?'primitivesItems':scope.objectKind==='header'?'header':scope.file?'fileSchema':'schema');
}
