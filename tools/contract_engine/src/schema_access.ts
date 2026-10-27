import {escape,SourceError} from './document';
import type {GraphTarget,ReferenceGraph} from './reference_graph';

export type PropertyAccess=Readonly<{readOnly:boolean;writeOnly:boolean}>;
const unmarked:PropertyAccess={readOnly:false,writeOnly:false};

/** Legacy Schema Object references replace their occurrence and ignore
 * siblings. Access flags belong to that resolved property schema, including
 * when its physical definition is outside a properties map (2.0 §6.4.18.1;
 * 3.0 §4.7.24.2). This does not apply modern annotation/required semantics. */
export function propertyAccess(graph:ReferenceGraph,owner:GraphTarget,name:string):PropertyAccess {
    let target=graph.scopes.get(owner.resource+'#'+owner.pointer+'/properties/'+escape(name));
    const seen=new Set<string>();
    while(target){
        const identity=target.resource+'#'+target.pointer;
        if(seen.has(identity))return unmarked;
        if(seen.size>=128)throw new SourceError('limit.schema.access','Property access reference inspection exceeds its bounded depth');
        seen.add(identity);
        const value=graph.docs.get(target.resource)?.dataNode(target.pointer)?.value;
        if(typeof value?.$ref!=='string')return {readOnly:value?.readOnly===true,writeOnly:value?.writeOnly===true};
        const resolved=graph.resolveReference(value.$ref,target);
        if(resolved.resolution!=='resolved')throw new SourceError('schema.access.reference','Property access annotations require a resolved schema reference',undefined,'unsupported');
        target=graph.scopes.get(resolved.targetResource+'#'+resolved.targetPointer);
    }
    return unmarked;
}
