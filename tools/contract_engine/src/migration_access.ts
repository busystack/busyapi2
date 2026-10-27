import {segments,SourceError} from './document';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import {modernFamily} from './specification';

const key=(scope:Pick<GraphScope,'resource'|'pointer'>)=>JSON.stringify([scope.resource,scope.pointer]);

/** 3.0 §4.7.24.2 changes required-property evaluation by direction; modern
 * OAS uses annotation semantics (§4.8.24.3.2 in 3.1). Optional property uses
 * need no required-list rewrite. Swagger's request exclusion is stronger. */
export class MigrationAccess {
    private incoming=new Map<string,GraphScope[]>();
    constructor(private graph:ReferenceGraph){
        for(const reference of graph.references){
            if(reference.kind!=='schema'||reference.keyword!=='$ref'||reference.resolution!=='resolved')continue;
            const scope=graph.scopes.get(reference.resource+'#'+reference.pointer);
            if(!scope||scope.kind!=='schema')continue;
            const id=key({resource:reference.targetResource!,pointer:reference.targetPointer!}),values=this.incoming.get(id)??[];
            values.push(scope);this.incoming.set(id,values);
        }
    }

    preserves(scope:GraphScope,from:string,to:string):boolean {
        if(from===to||modernFamily(from)&&modernFamily(to))return true;
        const value=this.graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        if(value?.readOnly!==true&&value?.writeOnly!==true)return true;
        // Swagger upgrades already own their explicit read-only exclusion
        // blocker. writeOnly has no standard Swagger representation either.
        if(from==='2.0')return true;
        if(!modernFamily(from)&&typeof value?.$ref==='string')return true;
        if(to==='2.0')return value?.readOnly!==true;
        const pending=[scope],seen=new Set<string>();let properties=0;
        while(pending.length){
            const current=pending.pop()!,id=key(current);if(seen.has(id))continue;
            if(seen.size>=2048)throw new SourceError('limit.migration.access','Access annotation use inspection exceeds 2048 schema occurrences');
            seen.add(id);
            const tokens=segments(current.pointer),parent=current.pointer.slice(0,current.pointer.lastIndexOf('/'));
            const owner=parent.endsWith('/properties')?this.graph.scopes.get(current.resource+'#'+parent.slice(0,-'/properties'.length)):undefined;
            if(tokens.at(-2)==='properties'&&owner?.kind==='schema'){
                const object=this.graph.docs.get(owner.resource)!.dataNode(owner.pointer)?.value;
                if(Array.isArray(object?.required)&&object.required.includes(tokens.at(-1)))return false;
                properties++;
            }else{
                const reusable=tokens.length===3&&tokens[0]==='components'&&tokens[1]==='schemas';
                const fragment=!this.graph.specifications.has(current.resource)&&this.graph.scope(current.resource,parent).kind==='root';
                if(!reusable&&!fragment)return false;
            }
            pending.push(...this.incoming.get(id)??[]);
        }
        return properties>0;
    }
}
