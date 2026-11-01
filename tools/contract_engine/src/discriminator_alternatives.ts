import type {GraphScope,ReferenceGraph} from './reference_graph';
import {supportedSchemaDialect} from './reference_graph';
import {projectSchemaReference} from './schema_reference_projection';

export type DiscriminatorAlternativeProblem=Readonly<{
    scope:GraphScope;
    code:string;
    message:string;
}>;
export type DiscriminatorAlternatives=Readonly<{
    alternatives:readonly GraphScope[];
    problems:readonly DiscriminatorAlternativeProblem[];
}>;
const identity=(scope:GraphScope)=>JSON.stringify([scope.resource,scope.pointer]);

/** OAS 3.2.1 Discriminator Object: fallback targets belong to the adjacent
 * oneOf/anyOf, or are schemas inheriting this parent through allOf. A mapping
 * entry alone establishes no composition relationship. This projection never
 * asserts discriminator metadata as JSON Schema validation constraints. */
export class DiscriminatorAlternativeSelection {
    private work=0;
    private readonly references=new Map<string,ReferenceGraph['references']>();
    constructor(private readonly graph:ReferenceGraph){
        for(const reference of graph.references){
            if(reference.kind!=='schema'||reference.connection)continue;
            const key=identity(reference),items=this.references.get(key)??[];
            items.push(reference);this.references.set(key,items);
        }
    }
    private spend(scope:GraphScope,problems:DiscriminatorAlternativeProblem[]):boolean {
        if(++this.work<=100000)return true;
        if(!problems.some(problem=>problem.code==='limit.discriminator.alternatives'))
            problems.push({scope,code:'limit.discriminator.alternatives',message:'Discriminator alternative discovery exceeded its bounded captured-graph work'});
        return false;
    }
    private target(initial:GraphScope,parent:GraphScope,problems:DiscriminatorAlternativeProblem[]):GraphScope|undefined {
        let scope=initial;
        const seen=new Set<string>();
        while(this.spend(scope,problems)){
            const key=identity(scope);
            if(key===identity(parent)||seen.has(key)){
                problems.push({scope:initial,code:'discriminator.alternative.circular',message:'The proposed alternative resolves to its containing discriminator or a circular reference chain'});
                return;
            }
            if(seen.size>=128){
                problems.push({scope:initial,code:'limit.discriminator.alternatives',message:'Discriminator reference discovery exceeded 128 captured links'});
                return;
            }
            seen.add(key);
            if(!supportedSchemaDialect(scope)){
                problems.push({scope,code:'discriminator.alternative.dialect',message:'The alternative requires a supported captured schema dialect'});
                return;
            }
            const value=this.graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
            // Only a bare reference is an alias. Modern reference siblings
            // remain part of the listed alternative, including constraints.
            if(value===null||typeof value!=='object'||Array.isArray(value)||
                Object.keys(value).length!==1||typeof value.$ref!=='string')return scope;
            const reference=this.graph.referenceAs(scope.resource,scope.pointer,'$ref','schema');
            const projection=reference&&projectSchemaReference(reference);
            if(projection?.state!=='fixed'){
                problems.push({scope,code:'discriminator.alternative.reference',message:'The alternative has no single captured schema target'});
                return;
            }
            const target=this.graph.scopeAs(projection.target.resource,projection.target.pointer,'schema');
            if(!target){
                problems.push({scope,code:'discriminator.alternative.context',message:'The alternative does not identify a captured Schema Object'});
                return;
            }
            scope=target;
        }
    }
    private inherits(scope:GraphScope,parent:GraphScope,seen:ReadonlySet<string>,problems:DiscriminatorAlternativeProblem[]):boolean {
        if(!this.spend(scope,problems))return false;
        const key=identity(scope);
        if(key===identity(parent))return true;
        if(seen.has(key))return false;
        if(seen.size>=128){
            problems.push({scope,code:'limit.discriminator.alternatives',message:'Discriminator inheritance discovery exceeded 128 captured schemas'});
            return false;
        }
        const next=new Set(seen).add(key);
        for(const reference of this.references.get(key)??[]){
            const projection=projectSchemaReference(reference);
            if(projection.state!=='fixed')continue;
            const target=this.graph.scopeAs(projection.target.resource,projection.target.pointer,'schema');
            if(target&&this.inherits(target,parent,next,problems))return true;
        }
        const list=this.graph.docs.get(scope.resource)!.dataNode(scope.pointer+'/allOf');
        if(list?.kind==='array')for(const index of list.children.keys()){
            const child=this.graph.scopeAs(scope.resource,scope.pointer+'/allOf/'+index,'schema');
            if(child&&this.inherits(child,parent,next,problems))return true;
        }
        return false;
    }
    discover(parent:GraphScope):DiscriminatorAlternatives {
        const problems:DiscriminatorAlternativeProblem[]=[],alternatives=new Map<string,GraphScope>();
        const doc=this.graph.docs.get(parent.resource)!,value=doc.dataNode(parent.pointer)?.value;
        const adjacent=['oneOf','anyOf'].filter(keyword=>Array.isArray(value?.[keyword]));
        if(adjacent.length>1){
            problems.push({scope:parent,code:'discriminator.alternative.composition',message:'Simultaneous adjacent oneOf and anyOf discriminator selection is not defined by OpenAPI'});
            return {alternatives:[],problems};
        }
        if(adjacent.length){
            const keyword=adjacent[0];
            for(const index of doc.dataNode(parent.pointer+'/'+keyword)!.children.keys()){
                const member=this.graph.scopeAs(parent.resource,parent.pointer+'/'+keyword+'/'+index,'schema');
                if(!member)continue;
                const target=this.target(member,parent,problems);
                if(target)alternatives.set(identity(target),target);
            }
        }else{
            for(const scope of this.graph.scopesFor('schema')){
                if(identity(scope)===identity(parent))continue;
                if(!this.spend(scope,problems))break;
                const list=this.graph.docs.get(scope.resource)!.dataNode(scope.pointer+'/allOf');
                if(list?.kind!=='array')continue;
                const inherited=[...list.children.keys()].some(index=>{
                    const branch=this.graph.scopeAs(scope.resource,scope.pointer+'/allOf/'+index,'schema');
                    return branch!==undefined&&this.inherits(branch,parent,new Set(),problems);
                });
                if(!inherited)continue;
                const target=this.target(scope,parent,problems);
                if(target)alternatives.set(identity(target),target);
            }
        }
        return {alternatives:[...alternatives.values()],problems};
    }
}
