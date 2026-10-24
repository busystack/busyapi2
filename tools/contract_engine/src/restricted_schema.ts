import {GraphIssue, GraphScope, ReferenceGraph} from './reference_graph';
import {decimal} from './exact_numbers';
import {isReferenceObject} from './contexts';
import {SourceError} from './document';

/** Normative restricted Schema Object rules absent from the informational
 * artifacts (2.0 §6.4.18, 3.0.4 §4.7.24). Instance assertions still execute
 * in the pinned evaluator with exact CST values. */
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
            const ref = graph.resolveReference(value.$ref, scope);
            const target = ref.resolution === 'resolved' && graph.scopes.get(ref.targetResource + '#' + ref.targetPointer);
            return !!target && requires(target, name, nested);
        }
        if (Array.isArray(value.required) && value.required.includes(name)) return true;
        if (Array.isArray(value.allOf) && value.allOf.some((_: unknown, i: number) => requires(graph.scope(scope.resource, scope.pointer + '/allOf/' + i), name, nested))) return true;
        return ['oneOf', 'anyOf'].some(keyword => Array.isArray(value[keyword]) && value[keyword].length > 0 && value[keyword].every((_: unknown, i: number) => requires(graph.scope(scope.resource, scope.pointer + '/' + keyword + '/' + i), name, nested)));
    };
    for (const scope of graph.scopes.values()) {
        const doc = graph.docs.get(scope.resource)!, node = doc.dataNode(scope.pointer), value = node?.value;
        const flat=scope.family==='2.0'&&(scope.kind==='parameter'&&value?.in!=='body'&&typeof value?.$ref!=='string'||['header','items'].includes(scope.kind));
        if ((!flat&&scope.kind !== 'schema') || !['2.0','3.0'].includes(scope.family)) continue;
        if (!node || !doc.dataSyntaxSafe(scope.pointer) || !value || typeof value !== 'object' || Array.isArray(value) || isReferenceObject(value, 'schema', scope.family)) continue;
        if(typeof value.multipleOf==='number') {
            try {
                if(decimal(doc.dataJson(scope.pointer+'/multipleOf')).coefficient<=0n)
                    add(scope,'multipleOf','schema.multipleOf.positive','multipleOf must be strictly greater than zero');
            }catch(error) {
                if(!(error instanceof SourceError))throw error;
                issues.push({...scope,pointer:scope.pointer+'/multipleOf',code:error.code,message:error.message,incomplete:true,severity:'warning'});
            }
        }
        if (value.type === 'array' && (scope.family==='3.0'||flat) && !Object.hasOwn(value, 'items'))
            add(scope, '', 'schema.items.required', 'An array in this OpenAPI object must declare items');
        if (scope.family==='3.0'&&value.readOnly === true && value.writeOnly === true)
            add(scope, 'writeOnly', 'schema.access.conflicting', 'A property cannot be both readOnly and writeOnly');
        for (const [exclusive, bound] of [['exclusiveMinimum', 'minimum'], ['exclusiveMaximum', 'maximum']])
            if (value[exclusive] === true && !Object.hasOwn(value, bound))
                add(scope, exclusive, 'schema.bound.required', exclusive + ' requires ' + bound + ' in this Schema Object');
        for (const keyword of ['allOf', 'oneOf', 'anyOf'])
            if (Array.isArray(value[keyword]) && value[keyword].length === 0)
                add(scope, keyword, 'schema.composition.empty', keyword + ' must contain at least one Schema or Reference Object');
        const defaultNode = doc.dataNode(scope.pointer + '/default');
        if (defaultNode && (typeof value.type === 'string'||scope.family==='2.0'&&Array.isArray(value.type))) {
            const kind = defaultNode.value === null ? 'null' : Array.isArray(defaultNode.value) ? 'array' : typeof defaultNode.value;
            const types=Array.isArray(value.type)?value.type:[value.type];
            let valid = types.includes(kind) || scope.family==='3.0'&&kind === 'null' && value.nullable === true;
            if (!valid&&types.includes('integer') && kind === 'number') {
                try {
                    const number = decimal(doc.dataJson(defaultNode.pointer));
                    valid = number.coefficient === 0n || number.exponent >= 0n;
                }catch(error){
                    if(!(error instanceof SourceError))throw error;
                    issues.push({...scope,pointer:defaultNode.pointer,code:error.code,message:error.message,incomplete:true,severity:'warning'});
                    continue;
                }
            }
            if (!valid) add(scope, 'default', 'schema.default.type', 'default must conform to the type defined in the same OpenAPI Schema Object');
        }
        if (scope.family==='3.0'&&typeof value.discriminator?.propertyName === 'string' && !requires(scope, value.discriminator.propertyName))
            add(scope, 'discriminator/propertyName', 'discriminator.required', 'OpenAPI 3.0 requires the discriminating property to be required by this schema');
        if(scope.family==='2.0') {
            if(scope.kind==='items'&&typeof value.type!=='string')add(scope,'type','items.type.required','A Swagger Items Object must declare its primitive type');
            if(value.type==='file'&&scope.kind==='parameter'&&value.in!=='formData')add(scope,'type','parameter.file.location','Swagger file parameters must use in: formData');
            if(value.collectionFormat==='multi'&&!['query','formData'].includes(value.in))add(scope,'collectionFormat','parameter.collection.location','collectionFormat: multi is limited to query and formData parameters');
            if(typeof value.discriminator==='string') {
                const name=value.discriminator;
                if(!Object.hasOwn(value.properties??{},name)||!Array.isArray(value.required)||!value.required.includes(name))
                    add(scope,'discriminator','discriminator.required','A Swagger discriminator must name a property declared and required in this Schema Object');
            }
        }
    }
    return issues;
}
