import {flatSchemaContext} from './schema_context';
import {GraphIssue, GraphScope, ReferenceGraph} from './reference_graph';
import {decimal} from './exact_numbers';
import {isReferenceObject} from './contexts';
import {SourceError} from './document';

export const restrictedSchemaRevision='2';
type RequiredProof='required'|'not-established'|'incomplete';

/** Normative restricted Schema Object rules absent from the informational
 * artifacts (2.0 §6.4.18, 3.0.4 §4.7.24). Instance assertions still execute
 * in the pinned evaluator with exact CST values. */
export function restrictedSchemaIssues(graph: ReferenceGraph): GraphIssue[] {
    const issues: GraphIssue[] = [];
    const add = (scope: GraphScope, field: string, code: string, message: string) =>
        issues.push({...scope, pointer: scope.pointer + (field ? '/' + field : ''), code, message});
    let requirementWork=0,requirementCycles=0;
    const requirementProofs=new Map<GraphScope,Map<string,RequiredProof>>();
    const someProof=(values:unknown[],visit:(index:number)=>RequiredProof):RequiredProof=>{
        let incomplete=false;
        for(let index=0;index<values.length;index++){
            const proof=visit(index);if(proof==='required')return proof;
            if(requirementWork>20000)return 'incomplete';
            incomplete ||= proof==='incomplete';
        }
        return incomplete?'incomplete':'not-established';
    };
    const everyProof=(values:unknown[],visit:(index:number)=>RequiredProof):RequiredProof=>{
        let incomplete=false,established=values.length>0;
        for(let index=0;index<values.length;index++){
            const proof=visit(index);incomplete ||= proof==='incomplete';
            if(requirementWork>20000)return 'incomplete';
            established &&= proof==='required';
        }
        return established?'required':incomplete?'incomplete':'not-established';
    };
    const requires = (scope: GraphScope, name: string, seen = new Set<string>()): RequiredProof => {
        const identity = scope.resource + '#' + scope.pointer;
        if (seen.has(identity)){requirementCycles++;return 'not-established';}
        const cached=requirementProofs.get(scope)?.get(name);
        if(cached!==undefined)return cached;
        // A finite inheritance proof cannot turn its budget or an unavailable
        // reference into an OAS 3.0 §4.7.24.2.1 required-property violation.
        if (seen.size >= 128 || ++requirementWork>20000) return 'incomplete';
        const cycles=requirementCycles;
        const finish=(proof:RequiredProof):RequiredProof=>{
            // A negative result reached through an ancestor cycle is contextual.
            // Reuse only independent negatives and established positive proofs.
            if(proof!=='incomplete'&&(proof==='required'||cycles===requirementCycles)){
                let values=requirementProofs.get(scope);
                if(!values){values=new Map();requirementProofs.set(scope,values);}
                // Reuse captured identities and strings; copying an untrusted
                // property name into every visited node's key multiplies memory.
                values.set(name,proof);
            }
            return proof;
        };
        const value = graph.docs.get(scope.resource)?.dataNode(scope.pointer)?.value;
        if (!value || typeof value !== 'object') return finish('not-established');
        const nested = new Set(seen); nested.add(identity);
        if (typeof value.$ref === 'string') {
            const ref = graph.resolveReference(value.$ref, scope);
            const target = ref.resolution === 'resolved' && graph.scopes.get(ref.targetResource + '#' + ref.targetPointer);
            return finish(target ? requires(target, name, nested) : 'incomplete');
        }
        if (Array.isArray(value.required) && value.required.includes(name)) return finish('required');
        const proofs:RequiredProof[]=[];
        if (Array.isArray(value.allOf)){
            const proof=someProof(value.allOf,i=>requires(graph.scope(scope.resource,scope.pointer+'/allOf/'+i),name,nested));
            if(proof==='required')return finish(proof);proofs.push(proof);
        }
        for(const keyword of ['oneOf','anyOf'])if(Array.isArray(value[keyword])){
            const proof=everyProof(value[keyword],i=>requires(graph.scope(scope.resource,scope.pointer+'/'+keyword+'/'+i),name,nested));
            if(proof==='required')return finish(proof);proofs.push(proof);
        }
        return finish(proofs.includes('incomplete')?'incomplete':'not-established');
    };
    for (const scope of graph.scopes.values()) {
        const doc = graph.docs.get(scope.resource)!, node = doc.dataNode(scope.pointer), value = node?.value;
        const flat=flatSchemaContext(graph,scope);
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
        if (scope.family==='3.0'&&typeof value.discriminator?.propertyName === 'string'){
            const proof=requires(scope,value.discriminator.propertyName);
            if(proof==='incomplete')issues.push({...scope,pointer:scope.pointer+'/discriminator/propertyName',code:'discriminator.required.incomplete',message:'The bounded inheritance proof could not establish whether the discriminating property is required. Resolve unavailable references or simplify the inherited requirement path.',incomplete:true,severity:'warning'});
            else if(proof!=='required')add(scope,'discriminator/propertyName','discriminator.required','OpenAPI 3.0 requires the discriminating property to be required by this schema');
        }
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
