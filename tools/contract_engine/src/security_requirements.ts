import {GraphIssue, GraphTarget, ReferenceGraph} from './reference_graph';
import {escape} from './document';

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
            let target: GraphTarget | undefined = {resource: reference.targetResource!, pointer: reference.targetPointer!, kind: 'security'};
            const seen = new Set<string>();
            while (target) {
                const at = target.resource + '#' + target.pointer;
                if (seen.has(at) || seen.size >= 128) {target = undefined; break;}
                seen.add(at);
                const value = graph.docs.get(target.resource)?.dataNode(target.pointer)?.value;
                if (typeof value?.$ref !== 'string') break;
                const resolved = graph.resolveReference(value.$ref, graph.scope(target.resource, target.pointer));
                target = resolved.resolution === 'resolved' ? {resource: resolved.targetResource!, pointer: resolved.targetPointer!, kind: 'security'} : undefined;
            }
            definitions.set(identity, target);
        }
        const target = definitions.get(identity);
        if (!target) continue;
        const value = graph.docs.get(target.resource)!.dataNode(target.pointer)?.value;
        const pointer = reference.pointer + '/' + escape(reference.keyword);
        const scopes = graph.docs.get(reference.resource)!.dataNode(pointer);
        if (scopes?.kind !== 'array') continue;
        if (reference.family !== '3.2' && value?.type !== 'oauth2' && value?.type !== 'openIdConnect' && scopes.children.size > 0)
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
