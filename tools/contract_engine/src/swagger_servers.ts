import {SourceError,type Range} from './document';
import {structuralEvaluator,structuralSchema} from './structural_schema';
import {isIriReference,parseIriReference} from '@hyperjump/uri';
import type {GraphIssue,GraphScope,ReferenceGraph} from './reference_graph';
import type {LocatedSource} from './swagger_operation';
import {serverUrlValidity} from './server_semantics';

type Locate=(resource:string,pointer:string)=>LocatedSource;
export const swaggerServerContextRevision='1';
type Validity='valid'|'invalid'|'unsupported';
type SwaggerServerProblem={resource:string;pointer:string;code:string;message:string;range:Range;unsupported:boolean};

/** Swagger 2.0 §6.4.1: a host is a host/optional port,
 * not a URL or an authority with user-info. Keep the URL
 * spelling and use the pinned grammar; parsing never retrieves a resource. */
export function swaggerHostValidity(value:string):Validity {
    try {
        const reference='//'+value,parts=parseIriReference(reference);
        if(parts.authority!==value||!parts.host||parts.scheme!==undefined||parts.userinfo!==undefined||parts.path!==''||parts.query!==undefined||parts.fragment!==undefined)return 'invalid';
        return isIriReference(reference)?'valid':'invalid';
    }catch(error){
        if(!(error instanceof Error))throw error;
        if(error.message.startsWith('Invalid IRI-reference: '))return 'invalid';
        if(error.message.startsWith('Unsupported IP version in host: '))return 'unsupported';
        throw error;
    }
}

/** basePath is a fixed path (§6.4.1), not a Server URL template. Apply the
 * existing URL-literal policy to its path without inventing an API host or
 * changing the authored Unicode or escape spelling. ASCII whitespace must
 * be percent-encoded, consistently with the existing Server URL policy. */
export function swaggerBasePathValidity(value:string):Validity {
    if(!value.startsWith('/')||/[{}?#]/u.test(value))return 'invalid';
    return serverUrlValidity('https://api.example.invalid'+value,'https://api.example.invalid/');
}

function swaggerRootServerRelationships(graph:ReferenceGraph,resource:string):GraphIssue[] {
    const issues:GraphIssue[]=[];
    const scope=graph.scope(resource,''),doc=graph.docs.get(resource)!;
    for(const [field,validate]of [['host',swaggerHostValidity],['basePath',swaggerBasePathValidity]] as const){
        const value=doc.dataNode('/'+field)?.value;
        if(typeof value!=='string')continue;
        const validity=validate(value);
        if(validity==='valid')continue;
        const at:GraphScope={...scope,pointer:'/'+field};
        issues.push({...at,code:'swagger.'+field+(validity==='unsupported'?'.unsupported':'.syntax'),message:validity==='unsupported'?'The URL implementation cannot evaluate this Swagger '+field+' notation':field==='host'?'Swagger host must contain only a host name or bracketed IP address and optional port; omit scheme, user-info, path, query, fragment and templates':'Swagger basePath must be a fixed URL path beginning with /; escape invalid URL characters and omit templates, query and fragment',...(validity==='unsupported'?{incomplete:true,severity:'warning' as const}:{})});
    }
    return issues;
}

export function swaggerServerRelationships(graph:ReferenceGraph):GraphIssue[] {
    return [...graph.specifications].flatMap(([resource,specification])=>specification.family==='2.0'?swaggerRootServerRelationships(graph,resource):[]);
}

/** A read-only projection may show an invalid description for correction.
 * Shared consumers must not turn malformed components into another URL, or
 * silently default a non-string field. Reference retains the located problem;
 * request preparation and conversion refuse it. */
export function swaggerServerContextProblem(graph:ReferenceGraph,resource:string,pointer:string,descriptionRoot=graph.root):SwaggerServerProblem|undefined {
    const root=graph.docs.get(descriptionRoot)!;
    const problem=(owner:string,at:string,code:string,message:string,unsupported=false):SwaggerServerProblem=>{
        const range=graph.docs.get(owner)!.dataNode(at)!.range;
        return {resource:owner,pointer:at,code,message,range,unsupported};
    };
    for(const field of ['host','basePath'])if(root.root.children.has(field)){
        if(!root.dataSyntaxSafe('/'+field))return problem(root.id,'/'+field,'request.source','The captured Swagger server field is syntactically ambiguous');
        if(typeof root.root.value[field]!=='string')return problem(root.id,'/'+field,'swagger.'+field+'.type','The captured Swagger server field must be a string');
    }
    const issue=swaggerRootServerRelationships(graph,descriptionRoot)[0];
    if(issue)return problem(issue.resource,issue.pointer,issue.code,issue.message,issue.incomplete===true);
    const operation=graph.docs.get(resource)!.dataNode(pointer)!,local=pointer!==''&&operation.children.has('schemes');
    const schemes=local?operation.value.schemes:root.root.value.schemes;
    if(schemes!==undefined){
        const owner=local?resource:root.id,at=local?pointer+'/schemes':'/schemes';
        if(!graph.docs.get(owner)!.dataSyntaxSafe(at))return problem(owner,at,'request.source','The captured Swagger scheme list is syntactically ambiguous');
        const schema=structuralSchema('2.0'),validate=structuralEvaluator.getSchema(schema.$id+'#/$defs/schemes-list');
        if(!validate)throw new Error('The pinned Swagger scheme-list validator is unavailable');
        if(!Array.isArray(schemes)||schemes.some(value=>typeof value!=='string')||!validate(schemes))
            return problem(local?resource:root.id,local?pointer+'/schemes':'/schemes','swagger.schemes.invalid','Swagger schemes must be a unique array of supported protocol names');
    }
}

export function swaggerServers(graph:ReferenceGraph,resource:string,pointer:string,locate:Locate,descriptionRoot=graph.root) {
    const problem=swaggerServerContextProblem(graph,resource,pointer,descriptionRoot);
    if(problem)throw new SourceError(problem.code,problem.message,problem.range,problem.unsupported?'unsupported':undefined,{resource:problem.resource,pointer:problem.pointer,range:problem.range});
    const root=graph.docs.get(descriptionRoot)!,operation=graph.docs.get(resource)!.dataNode(pointer)!,retrieval=graph.retrievals.get(descriptionRoot)!;
    const base=new URL(retrieval),host=root.root.value.host??(base.protocol==='http:'||base.protocol==='https:'?base.host:undefined);
    const operationSchemes=pointer!==''&&operation.children.has('schemes');
    const declared=operationSchemes?operation.value.schemes:root.root.value.schemes;
    const schemes=declared?.length?declared:[base.protocol==='http:'||base.protocol==='https:'?base.protocol.slice(0,-1):undefined];
    const path=root.root.value.basePath??'/';
    return schemes.map((scheme:string|undefined)=>({url:host?(scheme?scheme+':':'')+'//'+host+path:path,variables:{},base:retrieval,
        origin:operationSchemes?'operation':'root',source:locate(root.id,''),
        sources:[...['host','basePath'].filter(field=>root.root.children.has(field)).map(field=>locate(root.id,'/'+field)),...(operationSchemes?[locate(resource,pointer+'/schemes')]:root.root.children.has('schemes')?[locate(root.id,'/schemes')]:[])]}));
}
