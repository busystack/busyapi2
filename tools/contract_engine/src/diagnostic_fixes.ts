import {createHash} from 'node:crypto';
import {analyse,createGraph,propose,Resource} from './engine';
import {SourceError} from './document';

/** Deliberately small, deterministic repairs. Missing bodies, authentication,
 * instance values or schema structure are never guessed to clear findings. */
export function planDiagnosticFix(input:any) {
    const diagnostic=input.diagnostic,target=input.target,resources=input.resources as Resource[];
    if(input.fix!=='path-parameter-required' || diagnostic?.code!=='parameter.path.required' ||
        diagnostic.category!=='openapi' || diagnostic.producer!=='busyapi' || diagnostic.producerVersion!=='0.1.0' ||
        diagnostic.pointerRedacted || diagnostic.resource!==target?.resource || diagnostic.pointer!==target.pointer ||
        diagnostic.root!==target.root || !Array.isArray(input.contexts) || !input.contexts.length)
        throw new SourceError('fix.unsupported','No deterministic repair is available for this captured finding');
    const context=input.contexts.find((context:any)=>context.root===diagnostic.root);
    if(!context || !Array.isArray(context.resources))throw new SourceError('fix.context','The diagnostic root is no longer selected');
    const source=resources.find(resource=>resource.id===target.resource);
    if(!source || source.generation!==target.generation)throw new SourceError('fix.stale','The diagnostic source changed');
    const frozen={root:context.root,snapshot:input.snapshot,resources:resources.filter(resource=>context.resources.includes(resource.id))};
    const current=analyse(frozen).findings.find((finding:any)=>finding.code===diagnostic.code && finding.resource===diagnostic.resource &&
        finding.pointer===diagnostic.pointer && JSON.stringify(finding.range)===JSON.stringify(diagnostic.range));
    if(!current || !current.fixes?.includes(input.fix))throw new SourceError('fix.stale','This captured diagnostic is no longer current or has no safe repair');
    const {docs,graph}=createGraph(frozen),doc=docs.get(source.id)!,node=doc.nodes.get(target.pointer);
    if(!node || node.shared || !doc.syntaxSafe(target.pointer) || graph.scopes.get(source.id+'#'+target.pointer)?.kind!=='parameter' ||
        node.kind!=='object' || typeof node.value?.$ref==='string' || node.value.in!=='path' || node.value.required===true ||
        JSON.stringify(node.range)!==JSON.stringify(target.range) || source.text.slice(...node.range)!==target.expected)
        throw new SourceError('fix.target','Choose the current, authored path Parameter definition');
    const result=propose({...input,target,actions:[{kind:'set',pointer:target.pointer+'/required',value:true}]});
    let after=source.text;
    for(const edit of [...result.edits].sort((a,b)=>b.start-a.start))after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
    const usages=new Map<string,any>();
    for(const entry of input.contexts) {
        const {graph}=createGraph({root:entry.root,resources:resources.filter(resource=>entry.resources.includes(resource.id))});
        for(const ref of graph.references)if(ref.kind==='parameter' && ref.resolution==='resolved' && ref.targetResource===source.id && ref.targetPointer===target.pointer) {
            const key=JSON.stringify([ref.resource,ref.pointer]),usage=usages.get(key)??{resource:ref.resource,pointer:ref.pointer,connection:'$ref',target:{resource:source.id,pointer:target.pointer},roots:[],effect:'definition-content-changes'};
            if(!usage.roots.includes(entry.root))usage.roots.push(entry.root);
            usages.set(key,usage);
        }
    }
    return {version:1,snapshot:input.snapshot,kind:'diagnostic-fix',fix:input.fix,
        identity:createHash('sha256').update(JSON.stringify({snapshot:input.snapshot,diagnostic,target,edits:result.edits})).digest('hex'),
        from:target,to:target,transitions:[],edits:result.edits,changes:[{resource:source.id,before:source.text,after}],
        checkedRoots:input.contexts.map((context:any)=>context.root),usages:[...usages.values()],blockers:[]};
}
