import {SourceError,segments} from './document';
import {record} from './engine_worker_client';
import {schemaLocation} from './mock_projection';
import type {ReferenceGraph,OperationOccurrence} from './reference_graph';
import {swaggerMedia} from './swagger_operation';

export type MockOperationLocation={path:string;method:string;pointer:string;defaultResponseMedia?:boolean};
const key=(resource:string,pointer:string)=>JSON.stringify([resource,pointer]);

/** Translate only physical locations proved by the existing bundle owner.
 * This cannot resolve references, infer fields or choose schema semantics. */
export class MockOperationProjection {
    private readonly locations=new Map<string,string>();
    constructor(private readonly graph:ReferenceGraph,output:string,provenance:unknown) {
        if(!Array.isArray(provenance)||provenance.length>200000)throw new SourceError('mock.validation.protocol','The derived mock provenance is unavailable');
        for(const entry of provenance){
            if(!record(entry)||typeof entry.kind!=='string')throw new SourceError('mock.validation.protocol','The derived mock provenance is malformed');
            const source=schemaLocation(entry.source),derived=schemaLocation(entry.derived);
            if(!source||!derived||derived.resource!==output||!graph.docs.has(source.resource))throw new SourceError('mock.validation.protocol','The derived mock location has no captured source owner');
            const identity=key(source.resource,source.pointer),prior=this.locations.get(identity);
            if(graph.scopes.get(source.resource+'#'+source.pointer)?.kind!==entry.kind)continue;
            if(prior!==undefined&&prior!==derived.pointer)throw new SourceError('mock.projection.ambiguous','A captured mock field has multiple derived locations');
            this.locations.set(identity,derived.pointer);
        }
    }

    private locate(resource:string,pointer:string):string {
        let parent=pointer;
        while(true){
            const found=this.locations.get(key(resource,parent));
            if(found!==undefined)return found+pointer.slice(parent.length);
            if(!parent)break;parent=parent.slice(0,parent.lastIndexOf('/'));
        }
        throw new SourceError('mock.projection.missing','The derived artifact omitted a captured operation field');
    }

    private value(document:Record<string,unknown>,pointer:string):unknown {
        let value:unknown=document;
        for(const part of segments(pointer)){
            if((!record(value)&&!Array.isArray(value))||!Object.hasOwn(value,part))throw new SourceError('mock.projection.missing','A proved derived operation field is unavailable');
            value=Reflect.get(value,part);
        }
        return value;
    }

    private unsupported(operation:OperationOccurrence,message:string):never {
        const source=operation.source,range=this.graph.docs.get(source.resource)!.dataNode(source.pointer)!.range;
        throw new SourceError('mock.operation.unsupported',message,range,'unsupported',{...source,range});
    }

    document(document:Record<string,unknown>):{document:Record<string,unknown>;operations:MockOperationLocation[]} {
        const paths=new Map<string,Record<string,unknown>>(),operations:MockOperationLocation[]=[];
        for(const operation of this.graph.operations()){
            if(operation.role!=='operation')continue;
            if(operation.customMethod)this.unsupported(operation,'The pinned mock router cannot preserve this custom operation method');
            const view=this.graph.pathItem(operation.pathItem);
            if(!view.complete||!view.chainComplete)this.unsupported(operation,'The captured Path Item inheritance is incomplete');
            if(!paths.has(operation.path)){
                // Effective fields and their ownership come from the original
                // graph. Values retain the bundle's repaired local references.
                paths.set(operation.path,Object.fromEntries([...view.fields].map(([name,source])=>[name,this.value(document,this.locate(source.resource,source.pointer))])));
            }
            const media=this.graph.scopes.get(operation.source.resource+'#'+operation.source.pointer)?.family==='2.0'
                ?swaggerMedia(this.graph,operation.source.resource,operation.source.pointer,'produces'):undefined;
            operations.push({path:operation.path,method:operation.method,pointer:this.locate(operation.source.resource,operation.source.pointer),
                ...(media?.length===1&&media[0]==='*/*'?{defaultResponseMedia:true}:{})});
        }
        return {document:{...document,paths:Object.fromEntries(paths)},operations};
    }
}
