import {GraphIssue, GraphScope, ReferenceGraph} from './reference_graph';
import {decimal} from './exact_numbers';
import {isReferenceObject} from './contexts';

/** Normative OAS 3.0 Schema Object rules absent from its informational schema
 * (3.0.4 §4.7.24). Assertions still execute in the pinned OAS evaluator. */
export function restrictedSchemaIssues(graph: ReferenceGraph): GraphIssue[] {
    const issues: GraphIssue[] = [];
    const add = (scope: GraphScope, field: string, code: string, message: string) =>
        issues.push({...scope, pointer: scope.pointer + (field ? '/' + field : ''), code, message});
    const requires = (scope: GraphScope, name: string, seen = new Set<string>()): boolean => {
        const identity = scope.resource + '#' + scope.pointer;
        if (seen.has(identity) || seen.size >= 128) return false;
        const value = graph.docs.get(scope.resource)?.dataNode(scope.pointer)?.value;
        if (!value || typeof value !== 'object') return false;
        const nested = new Set(seen); nested.add(identity);
        if (typeof value.$ref === 'string') {
            const ref = graph.resolve(value.$ref, scope);
            const target = ref.resolution === 'resolved' && graph.scopes.get(ref.targetResource + '#' + ref.targetPointer);
            return !!target && requires(target, name, nested);
        }
        if (Array.isArray(value.required) && value.required.includes(name)) return true;
        if (Array.isArray(value.allOf) && value.allOf.some((_: unknown, i: number) => requires(graph.scope(scope.resource, scope.pointer + '/allOf/' + i), name, nested))) return true;
        return ['oneOf', 'anyOf'].some(keyword => Array.isArray(value[keyword]) && value[keyword].length > 0 && value[keyword].every((_: unknown, i: number) => requires(graph.scope(scope.resource, scope.pointer + '/' + keyword + '/' + i), name, nested)));
    };
    for (const scope of graph.scopes.values()) {
        if (scope.kind !== 'schema' || scope.family !== '3.0') continue;
        const doc = graph.docs.get(scope.resource)!, node = doc.dataNode(scope.pointer), value = node?.value;
        if (!node || !doc.dataSyntaxSafe(scope.pointer) || !value || typeof value !== 'object' || Array.isArray(value) || isReferenceObject(value, 'schema', scope.family)) continue;
        if (value.type === 'array' && !Object.hasOwn(value, 'items'))
            add(scope, '', 'schema.items.required', 'An OpenAPI 3.0 array Schema Object must declare items');
        if (value.readOnly === true && value.writeOnly === true)
            add(scope, 'writeOnly', 'schema.access.conflicting', 'A property cannot be both readOnly and writeOnly');
        for (const [exclusive, bound] of [['exclusiveMinimum', 'minimum'], ['exclusiveMaximum', 'maximum']])
            if (value[exclusive] === true && !Object.hasOwn(value, bound))
                add(scope, exclusive, 'schema.bound.required', exclusive + ' requires ' + bound + ' in this Schema Object');
        for (const keyword of ['allOf', 'oneOf', 'anyOf'])
            if (Array.isArray(value[keyword]) && value[keyword].length === 0)
                add(scope, keyword, 'schema.composition.empty', keyword + ' must contain at least one Schema or Reference Object');
        const defaultNode = doc.dataNode(scope.pointer + '/default');
        if (defaultNode && typeof value.type === 'string') {
            const kind = defaultNode.value === null ? 'null' : Array.isArray(defaultNode.value) ? 'array' : typeof defaultNode.value;
            let valid = kind === value.type || kind === 'null' && value.nullable === true;
            if (value.type === 'integer' && kind === 'number') {
                const number = decimal(doc.dataJson(defaultNode.pointer));
                valid = number.coefficient === 0n || number.exponent >= 0n;
            }
            if (!valid) add(scope, 'default', 'schema.default.type', 'default must conform to the type defined in the same OpenAPI Schema Object');
        }
        if (typeof value.discriminator?.propertyName === 'string' && !requires(scope, value.discriminator.propertyName))
            add(scope, 'discriminator/propertyName', 'discriminator.required', 'OpenAPI 3.0 requires the discriminating property to be required by this schema');
    }
    return issues;
}
