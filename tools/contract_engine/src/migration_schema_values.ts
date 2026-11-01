import {SourceError} from './document';

/** Standalone boolean schemas need object assertions in the restricted
 * families. Swagger permits allOf but not the 3.0 not keyword. */
export function restrictedBooleanSchema(value:boolean,target:string):Record<string,unknown> {
    if(target!=='2.0'&&target!=='3.0')throw new SourceError('migration.schema.target','Boolean-schema lowering requires a restricted target family');
    if(value)return {};
    return target==='2.0'?{allOf:[{type:'string'},{type:'integer'}]}:{not:{}};
}
