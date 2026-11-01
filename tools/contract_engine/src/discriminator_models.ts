import type {GraphScope,ReferenceGraph} from './reference_graph';
import {SourceError,escape} from './document';

export const discriminatorModelsRevision='2';

/** Swagger 2.0 §§6.4.18.1–6.4.18.2.1 select friendly names from the entry
 * definitions namespace. References are replacement objects; allOf establishes
 * inheritance. This table is shared by native evaluation and migration, so a
 * converter cannot choose a different set of model names or source owners.
 * The 3.x namespace is used only to preserve allOf discriminator hints during
 * migration (3.0 §4.7.25); it adds no schema-validation assertions. */
export class DiscriminatorModels {
    private work=0;
    private readonly tables=new Map<string,ReadonlyMap<string,GraphScope>>();
    constructor(private readonly graph:ReferenceGraph,private readonly namespace:'/definitions'|'/components/schemas'='/definitions'){}
    private spend():void {
        if(++this.work>1000000)
            throw new SourceError('limit.schema.discriminator','Named-model selection exceeds its bounded captured-graph work',undefined,'unsupported');
    }
    /** Resolve a legacy replacement-reference chain for model identity, not
     * instance validation. Composition is inspected separately by models(). */
    target(initial:GraphScope):GraphScope|undefined {
        let scope=initial;
        const seen=new Set<string>();
        while(true){
            this.spend();
            const key=scope.resource+'#'+scope.pointer;
            if(seen.has(key))return;
            if(seen.size>=128)
                throw new SourceError('limit.schema.discriminator','Named-model reference selection exceeds 128 captured links',undefined,'unsupported');
            seen.add(key);
            const value=this.graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
            if(typeof value?.$ref!=='string')return scope;
            const reference=this.graph.resolveReference(value.$ref,scope);
            if(reference.resolution!=='resolved')
                throw new SourceError('schema.discriminator.reference','The named-model table depends on an unresolved schema reference',undefined,'unsupported');
            scope=this.graph.scope(reference.targetResource!,reference.targetPointer!);
        }
    }
    models(base:Pick<GraphScope,'resource'|'pointer'>,required=true):ReadonlyMap<string,GraphScope> {
        const graph=this.graph,baseKey=base.resource+'#'+base.pointer,cached=this.tables.get(baseKey);
        if(cached){
            if(required&&!cached.size)throw new SourceError('schema.discriminator.context','Polymorphism requires a named model in the captured entry namespace');
            return cached;
        }
        const inherits=(scope:GraphScope,seen=new Set<string>()):boolean=>{
            this.spend();
            const target=this.target(scope);if(!target)return false;
            const key=target.resource+'#'+target.pointer;
            if(key===baseKey)return true;
            if(seen.has(key))return false;
            if(seen.size>=128)throw new SourceError('limit.schema.discriminator','Named-model inheritance selection exceeds 128 captured models',undefined,'unsupported');
            const next=new Set(seen);next.add(key);
            const branches=graph.docs.get(target.resource)!.dataNode(target.pointer+'/allOf');
            return branches?.kind==='array'&&[...branches.children.keys()].some(index=>inherits(graph.scope(target.resource,target.pointer+'/allOf/'+index),next));
        };
        const definitions=graph.docs.get(graph.root)!.dataNode(this.namespace),models=new Map<string,GraphScope>();
        if((definitions?.children.size??0)>20000)throw new SourceError('limit.schema.discriminator','Named-model selection exceeds its bounded definition count');
        for(const name of definitions?.children.keys()??[]){
            const scope=graph.scopes.get(graph.root+'#'+this.namespace+'/'+escape(name));
            if(scope&&inherits(scope))models.set(name,scope);
        }
        if(required&&!models.size)throw new SourceError('schema.discriminator.context','Polymorphism requires a named model in the captured entry namespace');
        this.tables.set(baseKey,models);
        return models;
    }
}
