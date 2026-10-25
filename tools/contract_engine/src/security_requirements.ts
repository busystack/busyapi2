import {GraphIssue, GraphReference, GraphTarget, ReferenceGraph} from './reference_graph';
import {escape} from './document';
import {modernFamily} from './specification';

/** Resolve only the Reference Objects allowed at a Security Scheme position.
 * Shared by list constraints and native binding choices. */
export function securityRequirementDefinition(graph:ReferenceGraph,target:GraphTarget):GraphTarget|undefined {
    const seen=new Set<string>();
    while(true){
        const at=target.resource+'#'+target.pointer;
        if(seen.has(at)||seen.size>=128)return;
        seen.add(at);
        const scope=graph.scopes.get(at),node=graph.docs.get(target.resource)?.dataNode(target.pointer);
        if(!scope||node?.kind!=='object')return;
        if(!graph.referenceObject(node.value,scope))return target;
        const resolved=graph.resolveReference(node.value.$ref,scope);
        if(resolved.resolution!=='resolved'||resolved.targetResource===undefined||resolved.targetPointer===undefined)return;
        target={resource:resolved.targetResource,pointer:resolved.targetPointer,kind:'security'};
    }
}

export function securityRequirementValuesAllowed(family:string,type:unknown,count:number):boolean {
    return count===0||modernFamily(family)||type==='oauth2'||family!=='2.0'&&type==='openIdConnect';
}

export function securityRequirementValueRule(graph:ReferenceGraph,reference:Pick<GraphReference,'family'|'resolution'|'targetResource'|'targetPointer'>):'scopes'|'roles'|'empty'|'unresolved' {
    if(reference.resolution!=='resolved'||reference.targetResource===undefined||reference.targetPointer===undefined)return 'unresolved';
    const target=securityRequirementDefinition(graph,{resource:reference.targetResource,pointer:reference.targetPointer,kind:'security'});
    const type=target?graph.docs.get(target.resource)!.dataNode(target.pointer)?.value?.type:undefined;
    if(typeof type!=='string')return 'unresolved';
    if(type==='oauth2'||reference.family!=='2.0'&&type==='openIdConnect')return 'scopes';
    return securityRequirementValuesAllowed(reference.family,type,1)?'roles':'empty';
}

/** Security Requirement semantics are not expressible by the structural map
 * schema: scope/role meaning depends on the graph-resolved Security Scheme
 * (3.0.4 §4.7.30, 3.1.2 §4.8.30, 3.2.1 §4.30). */
export function securityRequirementIssues(graph: ReferenceGraph): GraphIssue[] {
    const issues: GraphIssue[] = [];
    for(const scope of graph.scopes.values())if(scope.family==='2.0'&&scope.kind==='security') {
        const node=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!;
        if(node.value?.type==='oauth2'&&!Object.hasOwn(node.value,'scopes'))issues.push({...scope,pointer:scope.pointer+'/scopes',code:'security.scopes.required',message:'A Swagger OAuth2 Security Scheme must declare its scopes map (2.0 §6.4.24)'});
    }
    const definitions = new Map<string, GraphTarget | undefined>();
    for (const reference of graph.references) {
        if (reference.connection !== 'security' || reference.resolution !== 'resolved') continue;
        const identity = reference.targetResource + '#' + reference.targetPointer;
        if (!definitions.has(identity)) {
            definitions.set(identity, securityRequirementDefinition(graph,{resource: reference.targetResource!, pointer: reference.targetPointer!, kind: 'security'}));
        }
        const target = definitions.get(identity);
        if (!target) continue;
        const value = graph.docs.get(target.resource)!.dataNode(target.pointer)?.value;
        const pointer = reference.pointer + '/' + escape(reference.keyword);
        const scopes = graph.docs.get(reference.resource)!.dataNode(pointer);
        if (scopes?.kind !== 'array') continue;
        if (!securityRequirementValuesAllowed(reference.family,value?.type,scopes.children.size))
            issues.push({...reference, pointer, code: 'security.scopes.empty', message: 'This specification requires an empty scope array for a non-OAuth security scheme'});
        if (value?.type === 'oauth2' && value.flows && typeof value.flows === 'object') {
            const available = new Set(Object.values(value.flows).flatMap((flow: any) => Object.keys(flow?.scopes ?? {})));
            for (const [index, scope] of scopes.children)
                if (typeof scope.value === 'string' && !available.has(scope.value))
                    issues.push({...reference, pointer: pointer + '/' + index, code: 'security.scope.undeclared', severity: 'warning', message: 'The required OAuth scope is absent from the scopes documented by this Security Scheme'});
        }
    }
    return issues;
}
