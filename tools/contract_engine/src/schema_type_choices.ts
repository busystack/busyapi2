import type {GraphScope,ReferenceGraph} from './reference_graph';
import {supportedSchemaDialect} from './reference_graph';
import {schemaAuthoringContext,sameSchemaAuthoringContext,type SchemaAuthoringContext} from './schema_authoring_context';

type JsonType='object'|'array'|'string'|'number'|'integer'|'boolean'|'null';
export type SchemaTypeChoices=Readonly<{
    revision:'1';supported:boolean;context:SchemaAuthoringContext;
    scalarTypes:readonly (JsonType|'file')[];unionTypes:readonly JsonType[];
}>;

/** Swagger §6.4.12 extends response-root scalar types with file, not the
 * Draft 4 type union. OAS 3.0 §4.7.24.1 permits only a single non-null type.
 * Every consumer uses this captured graph policy, including shared fragments. */
export function schemaTypeChoices(graph:ReferenceGraph,scope:GraphScope):SchemaTypeChoices {
    const supported=scope.kind==='schema'&&supportedSchemaDialect(scope);
    const types:JsonType[]=supported?['object','array','string','number','integer','boolean',...(scope.family==='3.0'?[]:['null' as const])]:[];
    const file=supported&&scope.family==='2.0'&&graph.swaggerFileTypeChoices().has(scope.resource+'#'+scope.pointer);
    return {
        revision:'1',supported,
        context:schemaAuthoringContext(graph,scope),
        scalarTypes:[...types,...(file?['file' as const]:[])],
        unionTypes:scope.family==='3.0'?[]:types,
    };
}

export function sameSchemaTypeChoices(expected:unknown,current:SchemaTypeChoices):boolean {
    if(!expected||typeof expected!=='object'||Array.isArray(expected))return false;
    const value=expected as Record<string,unknown>,context=value.context;
    if(value.revision!==current.revision||value.supported!==current.supported||!context||typeof context!=='object'||Array.isArray(context))return false;
    if(!sameSchemaAuthoringContext(context,current.context))return false;
    for(const key of ['scalarTypes','unionTypes'] as const){
        const supplied=value[key];
        if(!Array.isArray(supplied)||supplied.length!==current[key].length||supplied.some((entry,index)=>entry!==current[key][index]))return false;
    }
    return true;
}

/** Shape checking for a capability-bound Design action; Source remains free
 * to express invalid values for correction and receives ordinary diagnostics. */
export function allowedSchemaType(value:unknown,choices:SchemaTypeChoices):boolean {
    return choices.supported&&(value===undefined||typeof value==='string'&&choices.scalarTypes.includes(value as JsonType|'file')||
        Array.isArray(value)&&value.length>0&&new Set(value).size===value.length&&value.every(entry=>typeof entry==='string'&&choices.unionTypes.includes(entry as JsonType)));
}
