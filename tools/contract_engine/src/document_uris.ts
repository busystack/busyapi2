import {isUriReference} from '@hyperjump/uri';
import {escape} from './document';
import type {GraphIssue,GraphScope,ReferenceGraph} from './reference_graph';

export const documentUriRevision='1';
type UriScope=Pick<GraphScope,'kind'|'family'>;

/** Passive document URI positions, not API endpoints or payload keys.
 * Swagger 2.0 §6.4.2 termsOfService is text; OAS 3.x Info makes it a URL.
 * Server templates retain their separate substitution and base rules. */
export function documentUriFields(scope:UriScope,value?:unknown):readonly string[] {
    if(scope.kind==='example'&&value!==null&&typeof value==='object'&&'$ref' in value&&typeof value.$ref==='string')return [];
    if(scope.kind==='info')return scope.family==='2.0'?[]:['termsOfService'];
    return ({contact:['url'],license:['url'],'external-documentation':['url'],example:['externalValue'],server:['url']} as Record<string,readonly string[]>)[scope.kind]??[];
}

/** RFC 3986 URI references exclude whitespace and non-ASCII characters.
 * The pinned parser recognizes IPvFuture syntax but cannot evaluate its host;
 * report that exact limitation rather than making a false validity claim. */
export function documentUriValidity(value:string):'valid'|'invalid'|'unsupported' {
    if(/[^\x21-\x7e]/u.test(value))return 'invalid';
    try{return isUriReference(value)?'valid':'invalid';}
    catch(error){
        if(!(error instanceof Error)||!error.message.startsWith('Unsupported IP version in host: '))throw error;
        return 'unsupported';
    }
}

/** Typed occurrences never acquire externalValue or traverse example data. */
export function* documentUriOccurrences(graph:ReferenceGraph):Generator<{scope:GraphScope;pointer:string;field:string;value:string}> {
    for(const scope of graph.scopes.values()){
        const doc=graph.docs.get(scope.resource)!,node=doc.dataNode(scope.pointer);
        for(const field of documentUriFields(scope,node?.value)){
            const pointer=scope.pointer+'/'+escape(field),value=doc.dataNode(pointer)?.value;
            if(typeof value==='string')yield {scope,pointer,field,value};
        }
    }
}

/** OAS URL/URI metadata has normative syntax requirements even when the
 * informational structural schema uses non-validating format annotations.
 * Relative references remain permitted; Server templates are not URI literals. */
export function documentUriRelationships(graph:ReferenceGraph):GraphIssue[] {
    const issues:GraphIssue[]=[];
    for(const occurrence of documentUriOccurrences(graph)){
        if(occurrence.scope.kind==='server')continue;
        const validity=documentUriValidity(occurrence.value);
        if(validity==='invalid')issues.push({...occurrence.scope,pointer:occurrence.pointer,code:'metadata.uri',message:'This field must be a URI reference; escape spaces and non-ASCII characters'});
        if(validity==='unsupported')issues.push({...occurrence.scope,pointer:occurrence.pointer,code:'metadata.uri.unsupported',message:'The URI validator cannot evaluate this metadata host notation',incomplete:true,severity:'warning'});
    }
    return issues;
}
