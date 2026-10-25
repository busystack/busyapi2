import {componentFamily,componentLocation} from './authoring';
import {referenceKinds} from './contexts';
import {segments} from './document';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import {isNativeFamily} from './specification';

export type MemberNamePolicy=Readonly<{allowEmpty:boolean;maxLength:number;pattern?:string}>;
const swaggerNames:MemberNamePolicy=Object.freeze({allowEmpty:true,maxLength:4096});
const componentNames:MemberNamePolicy=Object.freeze({allowEmpty:false,maxLength:4096,pattern:'^[a-zA-Z0-9._-]+$'});
const swaggerStatuses:MemberNamePolicy=Object.freeze({allowEmpty:false,maxLength:7,pattern:'^(?:default|[1-5][0-9]{2})$'});
const modernStatuses:MemberNamePolicy=Object.freeze({allowEmpty:false,maxLength:7,pattern:'^(?:default|[1-5](?:[0-9]{2}|XX))$'});

/** Swagger 2.0 §§6.4.20–23 define named maps without the 3.x Components
 * name restriction (3.0.4 §4.7.7). Empty JSON member names remain names.
 * The existing 4096 UTF-16 unit authoring budget is a product limit. */
export const componentNamePolicy=(family:string):MemberNamePolicy|undefined=>
    isNativeFamily(family)?family==='2.0'?swaggerNames:componentNames:undefined;
export const responseStatusNamePolicy=(family:string):MemberNamePolicy|undefined=>
    isNativeFamily(family)?family==='2.0'?swaggerStatuses:modernStatuses:undefined;

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
}

export const reusableDefinitionPointer=(pointer:string,family:string):boolean=>{
    if(!isNativeFamily(family))return false;
    const parts=segments(pointer);
    return family==='2.0'?parts.length===2&&['definitions','parameters','responses','securityDefinitions'].includes(parts[0]):
        parts.length===3&&parts[0]==='components'&&Array.from(referenceKinds).some(kind=>componentFamily(kind,family)===parts[1]);
};
