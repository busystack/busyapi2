import {escape, segments} from './document';
import {GraphTarget, ReferenceGraph} from './reference_graph';

export type ParameterOccurrence = {
    source: GraphTarget; definition?: GraphTarget; inherited: boolean;
    identity?: string; name?: string; location?: string;
    state: 'resolved' | 'invalid' | 'unresolved' | 'cycle'; overridden?: boolean;
};
type ParameterList = {source?: GraphTarget; entries: ParameterOccurrence[]; valid: boolean; complete: boolean};
export type ParameterIssue = GraphTarget & {code: string; message: string; incomplete?: boolean; severity?: string; range?: number[]};
const key = (target: {resource:string;pointer:string}) => JSON.stringify([target.resource,target.pointer]);

/** Located consumers of the canonical graph, not another resolver or merged
 * document model. Reference occurrences and definitions retain their separate
 * physical locations; only name+in establishes an inheritance override. */
export class ParameterSemantics {
    private edges;
    private resolved = new Map<string, Omit<ParameterOccurrence,'inherited'>>();
    private lists = new Map<string,ParameterList>();
    constructor(readonly graph: ReferenceGraph) {
        this.edges = new Map(graph.references.filter(ref=>ref.keyword==='$ref' && ref.kind==='parameter').map(ref=>[key(ref),ref]));
    }
    occurrence(source: GraphTarget, inherited = false): ParameterOccurrence {
        const cached = this.resolved.get(key(source));
        if(cached)return {...cached,inherited};
        let target = source;
        const visited = new Set<string>();
        let result: Omit<ParameterOccurrence,'inherited'> = {source,state:'unresolved'};
        for(let depth=0;depth<=128;depth++) {
            if(visited.has(key(target))) {result={source,state:'cycle'};break;}
            visited.add(key(target));
            const doc=this.graph.docs.get(target.resource), node=doc?.dataNode(target.pointer);
            if(!doc || !node)break;
            if(!doc.dataSyntaxSafe(target.pointer)) {result={source,state:'unresolved'};break;}
            if(node.kind!=='object') {result={source,definition:target,state:'invalid'};break;}
            if(typeof node.value?.$ref==='string') {
                const ref=this.edges.get(key(target));
                if(!ref || ref.resolution!=='resolved')break;
                target={resource:ref.targetResource!,pointer:ref.targetPointer!,kind:'parameter'};continue;
            }
            const value=node.value;
            result={source,definition:{...target,pointer:node.pointer},state:'resolved',
                ...(typeof value?.name==='string'&&typeof value?.in==='string'?
                    {name:value.name,location:value.in,identity:JSON.stringify([value.in,value.name])}:{})};
            break;
        }
        this.resolved.set(key(source),result);
        return {...result,inherited};
    }
    list(owner: GraphTarget, inherited = false): ParameterList {
        const source={resource:owner.resource,pointer:owner.pointer+'/parameters',kind:'parameter-array'};
        let result=this.lists.get(key(source));
        if(!result) {
            const node=this.graph.docs.get(owner.resource)?.dataNode(source.pointer);
            result=!node?{entries:[],valid:true,complete:true}:
                node.kind!=='array'?{source,entries:[],valid:false,complete:false}:
                {source,entries:[...node.children.keys()].map(index=>this.occurrence({resource:owner.resource,pointer:source.pointer+'/'+escape(index),kind:'parameter'})),valid:true,complete:true};
            result.complete=result.complete&&result.entries.every(entry=>entry.state==='resolved');
            this.lists.set(key(source),result);
        }
        return {...result,entries:result.entries.map(entry=>({...entry,inherited}))};
    }
    operation(resource:string,pointer:string,path?:GraphTarget) {
        if(!path) {
            const tokens=segments(pointer);
            tokens.splice(tokens.at(-2)==='additionalOperations'?-2:-1);
            const parent=tokens.length?'/'+tokens.map(escape).join('/'):'';
            const scope=this.graph.scopes.get(resource+'#'+parent);
            if(scope?.kind==='path-item')path=scope;
        }
        const view=path?this.graph.pathItem(path):undefined,field=view?.fields.get('parameters');
        const inherited=field?this.list({resource:field.resource,pointer:field.pointer.slice(0,-'/parameters'.length),kind:'path-item'},true):{entries:[],valid:true,complete:!view||view.chainComplete&&!view.conflicts.includes('parameters')};
        if(view&&!view.chainComplete)inherited.complete=false;
        const local=this.list({resource,pointer,kind:'operation'});
        const overrides=new Set(local.entries.map(entry=>entry.identity).filter(identity=>identity!==undefined));
        const entries=[...inherited.entries.map(entry=>({...entry,...(entry.identity&&overrides.has(entry.identity)?{overridden:true}:{})})),...local.entries];
        return {entries,visible:entries.filter(entry=>!entry.overridden),complete:inherited.complete&&local.complete,valid:inherited.valid&&local.valid};
    }
    checks(operations:any[]):ParameterIssue[] {
        const issues=new Map<string,ParameterIssue>();
        const add=(target:GraphTarget,code:string,message:string,incomplete=false,severity='error')=>{
            const issue={...target,code,message,...(incomplete?{incomplete}:{}),...(severity!=='error'?{severity}:{})};
            issues.set(JSON.stringify([target.resource,target.pointer,code]),issue);
        };
        for(const scope of this.graph.scopes.values()) {
            const doc=this.graph.docs.get(scope.resource)!,node=doc.dataNode(scope.pointer);
            if(!node||!doc.dataSyntaxSafe(scope.pointer))continue;
            if(['path-item','operation'].includes(scope.kind)) {
                const list=this.list(scope);
                if(!list.valid)add(list.source!,'parameter.container.type','Parameters must be arrays');
                const seen=new Set<string>();
                for(const entry of list.entries) {
                    if(entry.state==='invalid')add(entry.source,'parameter.object.type','A parameter must be an object');
                    if(entry.state==='cycle')add(entry.source,'parameter.reference.cycle','This Parameter reference cycle has no concrete definition',true);
                    if(entry.identity!==undefined) {
                        if(seen.has(entry.identity))add(entry.source,'parameter.duplicate','Duplicate parameter name and location in one declaration list');
                        seen.add(entry.identity);
                    }
                }
            }
            if(scope.kind==='parameter' && node.kind==='object' && typeof node.value?.$ref!=='string') {
                if(node.value.in==='path' && node.value.required!==true)
                    add({...scope,pointer:node.pointer},'parameter.path.required','Path parameters must explicitly declare required: true');
                if(scope.family==='3.2' && node.value.in==='querystring') {
                    for(const name of ['schema','style','explode','allowReserved']) if(node.children.has(name))
                        add({...scope,pointer:scope.pointer+'/'+name},'parameter.querystring.field','Querystring parameters must use content, without schema serialization fields');
                    if(!node.children.has('content'))add(scope,'parameter.querystring.content','Querystring parameters must declare content');
                }
                if(scope.family==='3.2' && node.value.in==='cookie' && node.children.has('schema') && node.value.explode===false)
                    add({...scope,pointer:scope.pointer+'/explode'},'parameter.cookie.explode','Cookie parameters using schema must not declare explode: false');
            }
        }
        // Only the entry Paths Object defines HTTP endpoint templates.
        // Callback expressions and webhook names have separate grammars.
        const root=this.graph.docs.get(this.graph.root)!, paths=root.dataNode('/paths');
        const hierarchies=new Map<string,GraphTarget>();
        for(const [name,node] of paths?.children??[]) {
            if(name.startsWith('x-'))continue;
            const at={resource:root.id,pointer:'/paths/'+escape(name),kind:'path-item'};
            const expressions=[...name.matchAll(/\{([^{}]+)\}/gu)], hierarchy=name.replace(/\{[^{}]+\}/gu,'{}');
            const previous=hierarchies.get(hierarchy);
            if(previous&&expressions.length) {
                add(previous,'path.template.equivalent','Paths with the same hierarchy must not differ only in template names');
                add(at,'path.template.equivalent','Paths with the same hierarchy must not differ only in template names');
            } else hierarchies.set(hierarchy,at);
            if(this.graph.scope(root.id,'').family==='3.2') {
                const names=expressions.map(match=>match[1]);
                if(new Set(names).size!==names.length)add(at,'path.template.repeated','A template expression must not appear more than once in a path');
                // OAS 3.2 §4.8.2: expressions allow all characters except
                // braces; literals use RFC 3986 pchar and slash separators.
                // Each literal run must contain complete percent-encoded
                // tokens. Removing expressions would join e.g. %{id}20.
                const literals=name.split(/\{[^{}]+\}/gu);
                // Expressions occupy a nonempty segment even when their names
                // contain slashes. Literal empty segments are not in this ABNF.
                const segments=name.replace(/\{[^{}]+\}/gu,'a');
                if(!name.startsWith('/')||segments.includes('//')||literals.some(literal=>!/^(?:[A-Za-z0-9._~!$&'()*+,;=:@/\-]|%[A-Fa-f0-9]{2})*$/u.test(literal)))
                    add(at,'path.template.syntax','The path does not follow OpenAPI 3.2 path-template syntax');
            }
            // Diagnostics identify the authored path key rather than its body.
            for(const code of ['path.template.equivalent','path.template.repeated','path.template.syntax']) {
                const issue=issues.get(JSON.stringify([root.id,at.pointer,code]));
                if(issue)issue.range=node.keyRange;
            }
        }
        for(const issue of issues.values())if(issue.code==='path.template.equivalent')
            issue.range=root.dataNode(issue.pointer)?.keyRange;
        const ids=new Map<string,GraphTarget>();
        for(const scope of this.graph.scopes.values()) if(scope.kind==='operation') {
            const doc=this.graph.docs.get(scope.resource)!,node=doc.dataNode(scope.pointer),id=node?.value?.operationId;
            if(!node || !doc.dataSyntaxSafe(scope.pointer) || typeof id!=='string')continue;
            const previous=ids.get(id);
            if(previous && key(previous)!==key(scope))add({...scope,pointer:scope.pointer+'/operationId'},'operation.id.duplicate','operationId must identify a unique physical Operation Object');
            else ids.set(id,scope);
        }
        for(const operation of operations) {
            const parameters=this.operation(operation.resource,operation.pointer,operation.pathContext?{...operation.pathContext,kind:'path-item'}:undefined);
            if(this.graph.scope(operation.resource,operation.pointer).family==='2.0') {
                const bodies=parameters.visible.filter(entry=>entry.location==='body'),forms=parameters.visible.filter(entry=>entry.location==='formData');
                if(bodies.length>1)for(const entry of bodies)add(entry.source,'parameter.body.multiple','Swagger permits at most one effective body parameter');
                if(bodies.length&&forms.length)for(const entry of [...bodies,...forms])add(entry.source,'parameter.body.form-data','Swagger body and formData parameters cannot apply to the same operation');
                const operationValue=this.graph.docs.get(operation.resource)!.dataNode(operation.pointer)?.value;
                const media=Object.hasOwn(operationValue??{},'consumes')?operationValue.consumes:this.graph.docs.get(this.graph.root)!.root.value?.consumes;
                if(forms.some(entry=>this.graph.docs.get(entry.definition!.resource)!.dataNode(entry.definition!.pointer)?.value?.type==='file')&&
                    Array.isArray(media)&&!media.includes('multipart/form-data'))
                    add(forms[0].source,'parameter.file.media','A file formData parameter requires multipart/form-data in the effective consumes declaration');
            }
            if(this.graph.scope(operation.resource,operation.pointer).family==='3.2') {
                const querystrings=parameters.visible.filter(entry=>entry.location==='querystring');
                if(querystrings.length>1)for(const entry of querystrings.slice(1))add(entry.source,'parameter.querystring.duplicate','Only one effective querystring parameter may apply to an operation');
                if(querystrings.length && parameters.visible.some(entry=>entry.location==='query'))
                    add(querystrings[0].source,'parameter.querystring.mixed','Query and querystring parameters must not apply to the same operation');
            }
            // Webhook names and callback runtime expressions are not Paths
            // Object templates. Do not interpret their braces as path inputs.
            if(operation.role!=='operation' || typeof operation.path!=='string')continue;
            const names=new Set([...operation.path.matchAll(/\{([^}]+)\}/g)].map(match=>match[1]));
            if(parameters.complete)for(const name of names)
                if(!parameters.visible.some(entry=>entry.location==='path'&&entry.name===name))
                    add({resource:operation.resource,pointer:operation.pointer,kind:'operation'},'parameter.path.missing','A path template expression has no effective path parameter');
            for(const entry of parameters.visible)if(entry.location==='path'&&entry.name!==undefined&&!names.has(entry.name))
                add(entry.source,'parameter.path.name','This effective path parameter has no matching expression in the Paths Object template');
        }
        return [...issues.values()];
    }
}
