import type {GraphScope,ReferenceGraph} from './reference_graph';
import {SourceError,escape} from './document';

export const swaggerDiscriminatorModelsRevision='1';

/** Swagger 2.0 §§6.4.18.1–6.4.18.2.1 select friendly names from the entry
 * definitions namespace. References are replacement objects; allOf establishes
 * inheritance. This table is shared by native evaluation and migration, so a
 * converter cannot choose a different set of model names or source owners. */
export class SwaggerDiscriminatorModels {
    private work=0;
    private readonly tables=new Map<string,ReadonlyMap<string,GraphScope>>();
    constructor(private readonly graph:ReferenceGraph){}
    models(base:Pick<GraphScope,'resource'|'pointer'>):ReadonlyMap<string,GraphScope> {
        const graph=this.graph,baseKey=base.resource+'#'+base.pointer,cached=this.tables.get(baseKey);
        if(cached)return cached;
        const spend=()=>{if(++this.work>1000000)throw new SourceError('limit.schema.discriminator','Swagger named-model selection exceeds its bounded captured-graph work',undefined,'unsupported');};
        const resolve=(initial:GraphScope):GraphScope|undefined=>{
            let scope=initial;
            const seen=new Set<string>();
            while(true){
                spend();
                const key=scope.resource+'#'+scope.pointer;
                if(seen.has(key))return;
                if(seen.size>=128)throw new SourceError('limit.schema.discriminator','Swagger model reference selection exceeds 128 captured links',undefined,'unsupported');
                seen.add(key);
                const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
                if(typeof value?.$ref!=='string')return scope;
                const reference=graph.resolveReference(value.$ref,scope);
                if(reference.resolution!=='resolved')throw new SourceError('schema.discriminator.reference','The named-model table depends on an unresolved schema reference',undefined,'unsupported');
                scope=graph.scope(reference.targetResource!,reference.targetPointer!);
            }
        };
        const inherits=(scope:GraphScope,seen=new Set<string>()):boolean=>{
            spend();
            const target=resolve(scope);if(!target)return false;
            const key=target.resource+'#'+target.pointer;
            if(key===baseKey)return true;
            if(seen.has(key))return false;
            if(seen.size>=128)throw new SourceError('limit.schema.discriminator','Swagger inheritance selection exceeds 128 captured models',undefined,'unsupported');
            const next=new Set(seen);next.add(key);
            const branches=graph.docs.get(target.resource)!.dataNode(target.pointer+'/allOf');
            return branches?.kind==='array'&&[...branches.children.keys()].some(index=>inherits(graph.scope(target.resource,target.pointer+'/allOf/'+index),next));
        };
        const definitions=graph.docs.get(graph.root)!.dataNode('/definitions'),models=new Map<string,GraphScope>();
        if((definitions?.children.size??0)>20000)throw new SourceError('limit.schema.discriminator','Swagger model selection exceeds its bounded definition count');
        for(const name of definitions?.children.keys()??[]){
            const scope=graph.scopes.get(graph.root+'#/definitions/'+escape(name));
            if(scope&&inherits(scope))models.set(name,scope);
        }
        if(!models.size)throw new SourceError('schema.discriminator.context','Swagger polymorphism requires a named model in the captured definitions namespace');
        this.tables.set(baseKey,models);
        return models;
    }
}
