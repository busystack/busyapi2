import {componentFamily,componentLocation} from './authoring';
import {referenceKinds} from './contexts';
import {escape,segments} from './document';
import {supportedSchemaDialect,type GraphIssue,type GraphScope,type ReferenceGraph} from './reference_graph';
import {isNativeFamily,modernFamily} from './specification';

export type MemberNamePolicy=Readonly<{allowEmpty:boolean;maxLength:number;pattern?:string}>;
const swaggerNames:MemberNamePolicy=Object.freeze({allowEmpty:true,maxLength:4096});
const componentNames:MemberNamePolicy=Object.freeze({allowEmpty:false,maxLength:4096,pattern:'^[a-zA-Z0-9._-]+$'});
const schemaNames:MemberNamePolicy=Object.freeze({allowEmpty:true,maxLength:4096});
const swaggerStatuses:MemberNamePolicy=Object.freeze({allowEmpty:false,maxLength:7,pattern:'^(?:default|[1-5][0-9]{2})$'});
const modernStatuses:MemberNamePolicy=Object.freeze({allowEmpty:false,maxLength:7,pattern:'^(?:default|[1-5](?:[0-9]{2}|XX))$'});

/** Swagger 2.0 §§6.4.20–23 define named maps without the 3.x Components
 * name restriction (3.0.4 §4.7.7). Empty JSON member names remain names.
 * The existing 4096 UTF-16 unit authoring budget is a product limit. */
export const componentNamePolicy=(family:string):MemberNamePolicy|undefined=>
    isNativeFamily(family)?family==='2.0'?swaggerNames:componentNames:undefined;
export const responseStatusNamePolicy=(family:string):MemberNamePolicy|undefined=>
    isNativeFamily(family)?family==='2.0'?swaggerStatuses:modernStatuses:undefined;

/** JSON Schema 2020-12 Core §8.2.4 defines $defs as independently named,
 * unapplied schemas. Their JSON member names have no Components restriction. */
export function schemaDefinitionNamePolicy(graph:ReferenceGraph,scope:GraphScope):MemberNamePolicy|undefined {
    if(scope.kind!=='schema'||!modernFamily(scope.family)||!supportedSchemaDialect(scope))return;
    const parts=segments(scope.pointer);
    if(parts.at(-2)!=='$defs')return;
    const parent='/'+parts.slice(0,-1).map(escape).join('/');
    const collection=graph.scopes.get(scope.resource+'#'+parent);
    if(collection)return schemaDefinitionMapNamePolicy(graph,collection);
}

function schemaDefinitionMapNamePolicy(graph:ReferenceGraph,scope:GraphScope):MemberNamePolicy|undefined {
    if(scope.kind!=='schema-map'||!modernFamily(scope.family)||!supportedSchemaDialect(scope))return;
    const parts=segments(scope.pointer);
    if(parts.at(-1)!=='$defs')return;
    const owner=parts.length===1?'':'/'+parts.slice(0,-1).map(escape).join('/');
    if(graph.scopes.get(scope.resource+'#'+owner)?.kind==='schema')return schemaNames;
}

/** The published Swagger structural artifact accepts any three digits. HTTP
 * permits codes 100–599 (RFC 9110 §15); 3.x artifacts already enforce this.
 * Named reusable responses and extension/example payloads are different maps. */
export function responseStatusIssues(graph:ReferenceGraph):GraphIssue[] {
    const issues:GraphIssue[]=[];
    for(const scope of graph.scopes.values()){
        if(scope.family!=='2.0'||scope.kind!=='response-map')continue;
        for(const name of graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.children.keys()??[])
            if(/^[0-9]{3}$/.test(name)&&!permitsMemberName(responseStatusNamePolicy(scope.family),name))
                issues.push({...scope,pointer:scope.pointer+'/'+escape(name),code:'response.status.invalid',message:'An HTTP response status code must be between 100 and 599'});
    }
    return issues;
}

export function permitsMemberName(policy:MemberNamePolicy|undefined,value:unknown):value is string {
    return !!policy&&typeof value==='string'&&value.length<=policy.maxLength&&
        (value.length===0?policy.allowEmpty:policy.pattern===undefined||new RegExp(policy.pattern).test(value));
}

/** Classify the actual collection, not a reference-looking pointer in payload
 * data or a Schema Object's independently named properties/definitions. */
export function collectionMemberNamePolicy(graph:ReferenceGraph,scope:GraphScope):MemberNamePolicy|undefined {
    const specification=graph.specifications.get(scope.resource);
    if(specification)for(const kind of referenceKinds){
        const group=componentFamily(kind,specification.family);
        if(group&&componentLocation(group,specification.family)===scope.pointer)
            return componentNamePolicy(specification.family);
    }
    if(scope.kind==='response-map')return responseStatusNamePolicy(scope.family);
    return schemaDefinitionMapNamePolicy(graph,scope);
}

export const reusableDefinitionPointer=(pointer:string,family:string):boolean=>{
    if(!isNativeFamily(family))return false;
    const parts=segments(pointer);
    return family==='2.0'?parts.length===2&&['definitions','parameters','responses','securityDefinitions'].includes(parts[0]):
        parts.length===3&&parts[0]==='components'&&Array.from(referenceKinds).some(kind=>componentFamily(kind,family)===parts[1]);
};
