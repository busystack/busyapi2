import {children} from './contexts';
import {SourceDocument,SourceError,escape,segments} from './document';
import {ReferenceGraph} from './reference_graph';
import {modernFamily} from './specification';

export type PolicyOrigin={resource:string;pointer:string;kind:string};

/** A disposable policy input, never a document authority or another resolver.
 * Only graph-proven OAS Reference Objects and unambiguous Path Items have a
 * replacement view. Schema applicators remain authored: no allOf map merging,
 * static binding of dynamic scope, or traversal of literal payload references.
 */
export function governanceProjection(graph:ReferenceGraph,resolved:boolean) {
    const origins=new Map<string,PolicyOrigin>(),kinds=new Map<string,string>();
    const references=new Map(graph.references.filter(ref=>ref.keyword==='$ref'&&!ref.connection)
        .map(ref=>[JSON.stringify([ref.resource,ref.pointer]),ref]));
    let nodes=0,text=0;
    const problems:{origin:PolicyOrigin;code:string}[]=[];
    const walk=(origin:PolicyOrigin,output:string,ancestors:ReadonlySet<string>,depth:number):any=>{
        if(++nodes>400000||depth>128)throw new SourceError('limit.policy.projection','Governance projection exceeds its node or nesting bound');
        const doc=graph.docs.get(origin.resource)!;
        const node=doc.dataNode(origin.pointer);
        if(!node)throw new SourceError('policy.provenance','Governance source is absent');
        origins.set(output,origin);kinds.set(output,origin.kind);
        const value=node.value;
        const scope={...graph.scope(origin.resource,origin.pointer),kind:origin.kind},family=scope.family;
        const referenceObject=graph.referenceObject(value,scope);
        if(resolved&&origin.kind==='path-item'&&value&&typeof value.$ref==='string') {
            const view=graph.pathItem(origin),identity=JSON.stringify([origin.resource,origin.pointer,origin.kind]);
            if(!view.complete)problems.push({origin,code:view.conflicts.length?'policy.path-item.ambiguous':view.cyclic?'policy.reference.cycle':'policy.reference.incomplete'});
            else if(ancestors.has(identity))problems.push({origin,code:'policy.reference.cycle'});
            else {
                const result={},seen=new Set(ancestors);seen.add(identity);
                for(const [name,field]of view.fields)Object.defineProperty(result,name,{
                    value:walk(field,output+'/'+escape(name),seen,depth+1),enumerable:true,writable:true,configurable:true,
                });
                return result;
            }
        }
        if(resolved && value && typeof value.$ref==='string' && (referenceObject||origin.kind==='path-item')) {
            const ref=references.get(JSON.stringify([origin.resource,origin.pointer]));
            const key=JSON.stringify([origin.resource,origin.pointer,origin.kind]);
            if(origin.kind==='path-item') {
                // The graph already diagnosed its specific overlap/cycle or
                // unavailable owner above. Retain authored fields, not a guess.
            } else if(!ref||ref.resolution!=='resolved') {
                problems.push({origin,code:'policy.reference.incomplete'});
            } else if(ancestors.has(key)) {
                problems.push({origin,code:'policy.reference.cycle'});
            } else {
                const seen=new Set(ancestors);seen.add(key);
                const target={resource:ref.targetResource!,pointer:ref.targetPointer!,kind:origin.kind};
                const result=walk(target,output,seen,depth+1);
                if(referenceObject && result && typeof result==='object'&&!Array.isArray(result)) {
                    // Only defined Reference Object annotations override the
                    // definition, with their own original-source provenance.
                    for(const name of ['summary','description'])if(modernFamily(family)&&Object.hasOwn(value,name))
                        Object.defineProperty(result,name,{value:walk({...origin,pointer:origin.pointer+'/'+name,kind:'data'},output+'/'+name,seen,depth+1),enumerable:true,writable:true,configurable:true});
                }
                return result;
            }
        }
        if(value===null||typeof value!=='object') {
            if(typeof value==='string')text+=value.length;
            if(text>32*1024*1024)throw new SourceError('limit.policy.projection','Governance projection exceeds its text bound');
            return value;
        }
        const contexts=new Map((referenceObject?[]:children(value,origin.kind,family)).map(([name,,kind])=>[String(name),kind]));
        const result=Array.isArray(value)?[]:{};
        for(const name of Object.keys(value)) {
            text+=name.length;
            const pointer=origin.pointer+'/'+escape(name),destination=output+'/'+escape(name);
            const item=walk({...origin,pointer,kind:contexts.get(name)??'data'},destination,ancestors,depth+1);
            Object.defineProperty(result,name,{value:item,enumerable:true,writable:true,configurable:true});
        }
        return result;
    };
    const value=walk({resource:graph.root,pointer:'',kind:'root'},'',new Set(),0);
    return {value,origins,kinds,problems,
        origin(path:ReadonlyArray<string|number>) {
            let pointer=path.length?'/'+path.map(String).map(escape).join('/'):'';
            while(!origins.has(pointer)&&pointer)pointer=pointer.slice(0,pointer.lastIndexOf('/'));
            return origins.get(pointer)!;
        },
        aliases() {
            const paths=(kind:string)=>[...kinds].filter(([,value])=>value===kind).map(([pointer])=>
                '$'+segments(pointer).map(segment=>'['+JSON.stringify(segment)+']').join(''));
            // Empty aliases still use a real nonmatching path; `$..` would
            // invent operations in extension/example data.
            const list=(kind:string)=>paths(kind).length?paths(kind):['$["\u0000busyapi-no-occurrence"]'];
            const arrays=[...kinds].filter(([pointer,kind])=>{
                    if(kind!=='schema')return false;
                    const origin=origins.get(pointer)!;const type=graph.docs.get(origin.resource)!.dataNode(origin.pointer)?.value?.type;
                    return type==='array'||Array.isArray(type)&&type.includes('array');
                }).map(([pointer])=>'$'+segments(pointer).map(segment=>'['+JSON.stringify(segment)+']').join(''));
            return {PathItem:list('path-item'),OperationObject:list('operation'),ServerObject:list('server'),ResponseObject:list('response'),LinkObject:list('link'),
                SecurityRequirementObject:list('security-requirement'),ArrayProperties:arrays.length?arrays:['$["\u0000busyapi-no-occurrence"]']};
        },
    };
}

export function policyRange(doc:SourceDocument,pointer:string) {
    const node=doc.dataNode(pointer)??doc.root;
    return {pointer:node.pointer,range:node.range};
}
