import {createHash} from 'node:crypto';
import {SourceError,SourceDocument} from './document';
import {nativeNumberIsExact} from './exact_numbers';
import {discoverPolicy,policyDependencyUri} from './governance_configuration';
import {inspectPolicyCode} from './policy_code';
import {resolvePolicyCode} from './policy_code_resolution';

const hash=(value:string)=>createHash('sha256').update(value).digest('hex');
const retrieval=(value:string)=>{const uri=new URL(policyDependencyUri(value,value));uri.search='';uri.hash='';return uri.href;};

/** Source-only closure review. All syntax/module lookup uses the existing
 * canonical declarations, Acorn and the maintained snapshot-only Node resolver.
 * Unknown capabilities go back to the core. This never imports project code,
 * acquires resources, installs packages, or makes a trust decision.
 */
export function reviewPolicyCode(input:any) {
    if(!Array.isArray(input?.scopes)||input.scopes.length<1||input.scopes.length>128||
        input.scopes.some((id:any)=>typeof id!=='string'||!id.endsWith('/')))
        throw new SourceError('policy.code.scope','Code review needs explicit bounded module directory scopes');
    const scopes:string[]=[...new Set<string>(input.scopes.map((id:string)=>policyDependencyUri(id,id)))].sort();
    const inScope=(id:string)=>scopes.some(scope=>id===scope.slice(0,-1)||id.startsWith(scope));
    // Validate the same immutable metadata universe the resolver will consume.
    resolvePolicyCode({resources:input.resources,requests:[],scopes});
    const discovered=discoverPolicy(input.policy),declarations=discovered.code??[];
    const supplied=new Map<string,any>(),requests=new Map<string,any>(),issues:any[]=[
        ...discovered.issues.filter((value:any)=>value.code!=='policy.dependencies.executable')];
    // Function declarations are acquired from the separate code universe below;
    // they need not be redundantly copied into the declarative parser input.
    const declared=new Set(declarations.map((value:any)=>value.uri));
    for(const id of discovered.requests)if(!declared.has(id))
        requests.set(JSON.stringify([id,'content']),{id,capability:'content'});
    for(const resource of input.resources)for(const identity of [resource.id,...resource.aliases??[]])
        supplied.set(retrieval(identity),resource);
    const request=(id:string,capability='content')=>{
        if(!inScope(retrieval(id))) {issues.push({resource:id,code:'policy.code.scope'});return;}
        requests.set(JSON.stringify([id,capability]),{id:retrieval(id),capability});
        if(requests.size>2048)throw new SourceError('limit.policy.code.requests','Code review exceeds its acquisition bound');
    };
    const need=(id:string)=>{
        const resource=supplied.get(retrieval(id));
        if(!resource||resource.kind==='file'&&typeof resource.text!=='string') {request(id);return;}
        if(resource.kind!=='file') {issues.push({resource:resource.id,code:'policy.code.resource.'+resource.kind});return;}
        return resource;
    };
    // A package scope stops at the explicit environment boundary or at
    // node_modules, just as Node package scopes do. Package declarations remain
    // captured source; there is no parent package/global-module filesystem read.
    const format=(id:string,resource:any):string|undefined=>{
        const uri=new URL(id),extension=/\.([^.\/]+)$/.exec(uri.pathname)?.[1];
        if(extension==='mjs')return 'module';
        if(extension==='cjs')return 'commonjs';
        if(extension==='json')return 'json';
        if(extension==='node'||['ts','mts','cts','wasm'].includes(extension??'')) {
            issues.push({resource:resource.id,code:'policy.code.format'});return;
        }
        let directory=new URL('.',uri);
        for(let depth=0;depth<128;depth++) {
            if(!inScope(directory.href))break;
            if(directory.pathname.endsWith('/node_modules/'))break;
            const packageId=new URL('package.json',directory).href,metadata=supplied.get(packageId);
            if(!metadata||metadata.kind==='file'&&typeof metadata.text!=='string') {request(packageId);return;}
            if(metadata.kind==='denied'||metadata.kind==='directory') {
                issues.push({resource:metadata.id,code:'policy.code.package.unavailable'});return;
            }
            if(metadata.kind==='file') {
                let declaration:any;
                try{declaration=JSON.parse(metadata.text.replace(/^\uFEFF/,''));}
                catch{issues.push({resource:metadata.id,code:'policy.code.package.syntax'});return;}
                if(declaration?.type==='module')return 'module';
                if(declaration?.type==='commonjs')return 'commonjs';
                break;
            }
            const parent=new URL('../',directory);if(parent.href===directory.href)break;directory=parent;
        }
        // Node treats untyped node_modules JavaScript as CommonJS. Other
        // ambiguous source uses the pinned V8 wrapper syntax probe in Acorn's
        // inspection boundary; no function is invoked during that probe.
        return uri.pathname.includes('/node_modules/')?'commonjs':'detect';
    };
    const modules=new Map<string,any>(),bindings=new Map<string,any>();
    const pending=declarations.map((value:any)=>value.uri),visited=new Set<string>();
    let operations=0;
    while(pending.length) {
        if(++operations>1024)throw new SourceError('limit.policy.code.modules','Code review exceeds 1024 module occurrences');
        const uri=pending.shift()!;
        if(visited.has(uri))continue;visited.add(uri);
        const resource=need(uri);if(!resource)continue;
        const selected=format(uri,resource);if(!selected)continue;
        if(selected==='json') {
            // Node JSON modules otherwise offer a second parsing route that
            // can round contract/example data before any function-context
            // guard. Reuse the canonical strict JSON CST with the real source
            // identity, even when a local mapping has a different filename.
            try {
                const doc=new SourceDocument(resource.text,resource.id,true,'json');
                for(const issue of doc.issues)issues.push({resource:resource.id,code:'policy.code.json.syntax',range:issue.range});
                if(!doc.issues.length)for(const node of doc.nodes.values())if(typeof node.value==='number'&&!nativeNumberIsExact(doc.dataJson(node.pointer),node.value))
                    issues.push({resource:resource.id,pointer:node.pointer,range:node.range,code:'policy.code.json.numeric.incomplete'});
            } catch(error) {
                if(error instanceof SourceError&&!error.code.startsWith('limit.'))issues.push({resource:resource.id,code:'policy.code.json.syntax',range:error.range});
                else throw error;
            }
            if(issues.length>4096)throw new SourceError('limit.policy.code.issues','JSON code data review exceeds its finding bound');
            modules.set(uri,{uri,resource:resource.id,format:'json',identity:hash(resource.text)});continue;
        }
        const inspected=inspectPolicyCode({resource:resource.id,text:resource.text,format:selected});
        modules.set(uri,{uri,resource:resource.id,format:inspected.format,identity:inspected.identity});
        for(const issue of inspected.issues)issues.push({resource:resource.id,...issue});
        const lookups=inspected.dependencies.map((dependency:any)=>({from:uri,specifier:dependency.specifier,
            mode:['require','require.resolve'].includes(dependency.kind)?'require':'import'}));
        const resolved=resolvePolicyCode({resources:input.resources,requests:lookups,scopes});
        for(const item of resolved.requests)request(item.id,item.capability);
        for(const item of resolved.issues)issues.push(item);
        for(let index=0;index<resolved.resolutions.length;index++) {
            const binding={...resolved.resolutions[index],origin:{resource:resource.id,range:inspected.dependencies[index].range}};
            bindings.set(JSON.stringify([binding.from,binding.mode,binding.specifier]),binding);
            if(binding.target&&!binding.builtin&&!binding.supplied)pending.push(binding.target);
        }
        if(issues.length>4096||bindings.size>4096)throw new SourceError('limit.policy.code.bindings','Code review exceeds its dependency binding bound');
    }
    const byJSON=(left:any,right:any)=>JSON.stringify(left)<JSON.stringify(right)?-1:JSON.stringify(left)>JSON.stringify(right)?1:0;
    const source=input.resources.map((resource:any)=>({id:resource.id,kind:resource.kind,
        aliases:[...resource.aliases??[]].sort(),...(typeof resource.text==='string'?{identity:hash((resource.hasBom?'\uFEFF':'')+resource.text)}:{})})).sort(byJSON);
    const result={version:1,profile:'busyapi-node-captured-v1',runtime:'24.15.0',
        producer:{inspector:'acorn@8.19.0',resolver:'enhanced-resolve@5.26.0',dataParser:'jsonc-parser@3.3.1',numeric:'busyapi-exact-binary-v1'},
        scopes,declarations,modules:[...modules.values()].sort(byJSON),bindings:[...bindings.values()].sort(byJSON),
        requests:[...requests.values()].sort(byJSON),issues:issues.sort(byJSON),
        complete:requests.size===0&&issues.length===0,
        // API buffers/generations do not enter code trust. Source and package
        // identities, occurrences, lookup outcomes and bindings do. Execution
        // must separately revalidate freshness and the actual installed profile.
        identity:''};
    result.identity=hash(JSON.stringify({version:1,profile:result.profile,runtime:result.runtime,
        producer:result.producer,scopes,declarations,modules:result.modules,bindings:result.bindings,source,
        configuration:input.policy.resources.map((resource:any)=>({id:resource.id,aliases:resource.aliases??[],identity:hash(resource.text)})).sort(byJSON),
        entries:input.policy.entries}));
    return result;
}
