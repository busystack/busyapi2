import {SourceDocument,SourceError} from './document';
import {resolveUri} from './reference_graph';

export const policyFunctionKey=(resource:string,pointer:string,name:string)=>JSON.stringify([resource,pointer,name]);

/** Policy declarations accept URL/path references with interior spaces. Encode
 * that presentation spelling, then use the canonical identity primitive. Both
 * discovery and execution consume this function; it never acquires a resource.
 */
export function policyDependencyUri(value:string,base:string):string {
    try {
        if(value!==value.trim()||/[\\\u0000-\u001f]/u.test(value))throw Error();
        return resolveUri(new URL(value,base).href,base).href;
    } catch {throw new SourceError('policy.uri','Invalid ruleset resource reference');}
}

/** Enumerate declarative dependencies only. The core decides which requested
 * identity may be retrieved. Project JS/functions are data, never imported.
 */
export function discoverPolicy(input:any) {
    if(!Array.isArray(input.resources)||input.resources.length>64||!Array.isArray(input.entries)||input.entries.length>16)
        throw new SourceError('limit.policy.configuration','Too many policy configuration resources');
    const supplied=new Map<string,SourceDocument>();
    const code=new Map<string,string>();
    const issues=new Map<string,{resource:string;pointer:string;code:string}>();
    const issue=(resource:string,pointer:string,code:string)=>{
        const value={resource,pointer,code},key=JSON.stringify(value);
        if(!issues.has(key)&&issues.size>=256)throw new SourceError('limit.policy.declarations','Policy dependency issues exceed their bound');
        issues.set(key,value);
    };
    let bytes=0;
    for(const resource of input.resources) {
        if(typeof resource?.id!=='string'||resource.id.length>16384||typeof resource.text!=='string'||resource.text.length>256*1024||(bytes+=resource.text.length*2)>2*1024*1024||
            resource.aliases!==undefined&&(!Array.isArray(resource.aliases)||resource.aliases.length>256||resource.aliases.some((value:any)=>typeof value!=='string'||value.length>16384)))
            throw new SourceError('limit.policy.configuration','Policy configuration exceeds its text bound');
        const identities=[resource.id,...resource.aliases??[]].map(id=>policyDependencyUri(id,id));
        for(const id of identities)if(supplied.has(id)||code.has(id))throw new SourceError('policy.identity','Ambiguous policy resource identity');
        if(!/\.(?:ya?ml|json)$/i.test(new URL(resource.id).pathname)) {
            for(const id of identities)code.set(id,resource.id);
            continue;
        }
        const doc=new SourceDocument(resource.text,resource.id,true);
        for(const id of identities)supplied.set(id,doc);
    }
    const missing=new Set<string>(),visited=new Set<string>(),loading=new Set<string>();
    const codeDeclarations=new Map<string,any>();
    const declareCode=(uri:string,role:string,origin:{resource:string;pointer:string},name?:string,document?:SourceDocument)=>{
        const doc=document??supplied.get(origin.resource),node=doc?.dataNode(origin.pointer)??doc?.root;
        const declaration={uri,role,...origin,...(node?{range:node.range}:{}),...(name===undefined?{}:{name})};
        codeDeclarations.set(JSON.stringify([uri,role,origin.resource,origin.pointer,name]),declaration);
    };
    let declarations=0;
    const visit=(id:string,depth:number,origin?:{resource:string;pointer:string})=>{
        if(depth>64)throw new SourceError('limit.policy.extends','Ruleset extension nesting exceeds its bound');
        if(['busyapi:recommended','spectral:oas'].includes(id))return;
        if(loading.has(id)) {issue(origin!.resource,origin!.pointer,'policy.dependencies.cycle');return;}
        if(visited.has(id))return;
        visited.add(id);
        if(code.has(id)) {issue(code.get(id)!,'','policy.dependencies.executable');declareCode(id,'ruleset',{resource:code.get(id)!,pointer:''});return;}
        const doc=supplied.get(id);
        if(!doc) {missing.add(id);return;}
        if(doc.issues.length) {issue(doc.id,'','policy.dependencies.syntax');return;}
        loading.add(id);
        const active=new WeakSet<object>();
        const walk=(value:any,pointer:string,nesting:number)=>{
            if(nesting>64)throw new SourceError('limit.policy.extends','Ruleset override nesting exceeds its bound');
            if(++declarations>10000)throw new SourceError('limit.policy.declarations','Policy declarations exceed their bound');
            if(!value||typeof value!=='object'||Array.isArray(value)) {issue(doc.id,pointer,'policy.dependencies.configuration');return;}
            if(active.has(value)) {issue(doc.id,pointer,'policy.dependencies.cycle');return;}
            active.add(value);
            if(Object.hasOwn(value,'functions')||Object.hasOwn(value,'functionsDir')) {
                issue(doc.id,pointer,'policy.dependencies.executable');
                const directory=Object.hasOwn(value,'functionsDir')?value.functionsDir:'./functions',
                    definitions=Object.hasOwn(value,'functions')?value.functions:[];
                if(typeof directory!=='string'||directory.length>4096||!Array.isArray(definitions)||definitions.length>128)
                    issue(doc.id,pointer,'policy.dependencies.configuration');
                else for(let index=0;index<definitions.length;index++) {
                    const name=definitions[index],
                        at=pointer+'/functions/'+index;
                    if(typeof name!=='string'||!name.length||name.length>128||/[\u0000-\u001f]/u.test(name)) {
                        issue(doc.id,at,'policy.dependencies.configuration');continue;
                    }
                    try {
                        const uri=policyDependencyUri(directory.replace(/\/$/,'')+'/'+name.split('/').map(encodeURIComponent).join('/')+'.js',id);
                        declareCode(uri,'function',{resource:doc.id,pointer:at},name,doc);
                        if(!supplied.has(uri)&&!code.has(uri))missing.add(uri);
                    }catch{issue(doc.id,at,'policy.dependencies.configuration');}
                }
            }
            const entries=value.extends===undefined?[]:Array.isArray(value.extends)?value.extends:[value.extends];
            if(entries.length>256)throw new SourceError('limit.policy.extends','Ruleset extension list exceeds its bound');
            for(let index=0;index<entries.length;index++) {
                const entry=entries[index],at=pointer+'/extends'+(Array.isArray(value.extends)?'/'+index:'');
                const target=Array.isArray(entry)?entry[0]:entry;
                if(typeof target!=='string'||!target.length||target.length>16384) {issue(doc.id,at,'policy.dependencies.configuration');continue;}
                let uri:string;
                try {uri=['busyapi:recommended','spectral:oas'].includes(target)?target:policyDependencyUri(target,id);}
                catch {issue(doc.id,at,'policy.dependencies.configuration');continue;}
                visit(uri,depth+1,{resource:doc.id,pointer:at});
            }
            if(value.overrides!==undefined) {
                if(!Array.isArray(value.overrides))issue(doc.id,pointer+'/overrides','policy.dependencies.configuration');
                else {
                    if(value.overrides.length>256)throw new SourceError('limit.policy.overrides','Ruleset overrides exceed their bound');
                    for(let index=0;index<value.overrides.length;index++)walk(value.overrides[index],pointer+'/overrides/'+index,nesting+1);
                }
            }
            active.delete(value);
        };
        walk(doc.root.value,'',0);
        loading.delete(id);
    };
    for(const entry of input.entries) {
        if(typeof entry!=='string'||entry.length>16384)throw new SourceError('policy.entry','Invalid ruleset identity');
        visit(['busyapi:recommended','spectral:oas'].includes(entry)?entry:policyDependencyUri(entry,entry),0);
    }
    const ordered=[...issues.values()].sort((a,b)=>{
        const left=JSON.stringify(a),right=JSON.stringify(b);return left<right?-1:left>right?1:0;
    });
    return {version:1,requests:[...missing].sort(),complete:!missing.size&&!ordered.length,issues:ordered,
        ...(codeDeclarations.size?{code:[...codeDeclarations.values()]}:{})};
}
