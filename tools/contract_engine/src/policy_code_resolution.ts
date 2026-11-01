import {ResolverFactory} from 'enhanced-resolve';
import {createHash} from 'node:crypto';
import {isBuiltin} from 'node:module';
import {posix as path} from 'node:path';
import {policyDependencyUri} from './governance_configuration';
import {SourceError} from './document';
import {policyBuiltinModules} from './policy_builtin_modules';

type Resource={id:string;aliases?:string[];kind:'file'|'directory'|'absent'|'denied';text?:string};
const hash=(value:string)=>createHash('sha256').update(value).digest('hex');

/** Node-code dependency lookup, not another OpenAPI reference graph/resolver.
 * The maintained package resolver receives ONLY this immutable virtual FS.
 * Requests are metadata/content capabilities for the core to acquire, never
 * permission for this adapter/library to read a path, directory or network.
 */
export function resolvePolicyCode(input:any) {
    if(!Array.isArray(input?.resources)||input.resources.length>2048||
        !Array.isArray(input?.requests)||input.requests.length>1024)
        throw new SourceError('limit.policy.code.resolution','Code resolution exceeds its captured resource/request bound');
    // This is an explicitly bounded module environment, not Node's ambient
    // filesystem/global module tree. Outside roots are excluded from lookup;
    // their physical absence is neither asserted nor acquired. The runtime
    // loader must enforce these same captured bindings without fallback.
    if(input.scopes!==undefined&&(!Array.isArray(input.scopes)||input.scopes.length<1||input.scopes.length>128))
        throw new SourceError('policy.code.scope','Choose bounded code module directory scopes');
    const scopes:string[]|undefined=input.scopes?.map((value:any)=>{
        if(typeof value!=='string'||!value.endsWith('/'))throw new SourceError('policy.code.scope','Choose explicit code module directory scopes');
        return policyDependencyUri(value,value);
    });
    const inScope=(id:string)=>scopes===undefined||scopes.some(scope=>id===scope.slice(0,-1)||id.startsWith(scope));
    const files=new Map<string,{resource:Resource;uri:string}>(),directories=new Set<string>();
    const origins=new Map<string,string>(),requests=new Map<string,{id:string;capability:string}>(),issues:any[]=[];
    let text=0,work=0;
    const exportsOrigin=Symbol('BusyAPI selected exports origin'),moduleIdentity=Symbol('BusyAPI module URI');
    let selectedRecord:any;
    let executionFailure:SourceError|undefined;
    const spend=()=>{
        if(executionFailure)throw executionFailure;
        if(++work>20000)throw executionFailure??=new SourceError('limit.policy.code.work','Code dependency resolution exceeds its work bound');
    };
    const toPath=(spelling:string)=>{
        if(typeof spelling!=='string'||spelling.length>16384)throw new SourceError('policy.code.uri','Invalid captured code URI');
        const uri=new URL(policyDependencyUri(spelling,spelling));
        if(!['file:','http:','https:'].includes(uri.protocol)||uri.username||uri.password||
            uri.protocol!=='file:'&&(uri.search||uri.hash)||/%(?:2f|5c|00)/i.test(uri.pathname))
            throw new SourceError('policy.code.uri','Code resource identity needs an unambiguous approved hierarchical URI');
        if(uri.protocol!=='file:'&&/%(?:2[13456789abc]|3[abdf]|40|5[b-d])/i.test(uri.pathname))
            throw new SourceError('policy.code.uri.encoded-delimiter','An encoded remote delimiter cannot be equated with a local module filename');
        const origin=uri.protocol+'//'+uri.host,prefix='/__busyapi_policy__/'+hash(origin);
        if(origins.has(prefix)&&origins.get(prefix)!==origin)throw new SourceError('policy.code.identity','Conflicting code origin identities');
        origins.set(prefix,origin);
        const value=prefix+decodeURIComponent(uri.pathname);
        const clean=value.replace(/\/$/,'');
        if(value.includes('\0')||path.normalize(clean)!==clean)
            throw new SourceError('policy.code.uri','Code resource URI has ambiguous path segments');
        const retrieval=new URL(uri);retrieval.search='';retrieval.hash='';
        return {path:clean,uri:uri.href,retrieval:retrieval.href};
    };
    const fromPath=(value:string)=>{
        for(const [prefix,origin]of origins)if(value===prefix||value.startsWith(prefix+'/')) {
            const suffix=value.slice(prefix.length)||'/';
            // URL pathname encoding retains legal pchar such as scoped-package
            // '@'. encodeURIComponent would change that to %40 and could request
            // a different HTTP identity. Literal filesystem '%' must be escaped.
            const uri=new URL(origin+'/');uri.pathname=suffix.replaceAll('%','%25');return inScope(uri.href)?uri.href:undefined;
        }
        return undefined;
    };
    for(const source of input.resources as Resource[]) {
        if(!source||!['file','directory','absent','denied'].includes(source.kind)||
            source.text!==undefined&&(typeof source.text!=='string'||source.text.length>256*1024||(text+=source.text.length*2)>2*1024*1024)||
            source.aliases!==undefined&&(!Array.isArray(source.aliases)||source.aliases.length>64))
            throw new SourceError('limit.policy.code.resources','Captured code resources exceed their type or text bound');
        for(const identity of [source.id,...source.aliases??[]]) {
            const location=toPath(identity),before=files.get(location.path);
            if(before&&before.resource!==source)throw new SourceError('policy.code.identity','Ambiguous captured code identity');
            files.set(location.path,{resource:source,uri:location.retrieval});
            if(source.kind==='file'||source.kind==='directory') {
                for(let parent=path.dirname(location.path);fromPath(parent);parent=path.dirname(parent))directories.add(parent);
                if(source.kind==='directory')directories.add(location.path);
            }
        }
    }
    for(const [location,{resource}]of files)if(directories.has(location)&&['file','absent'].includes(resource.kind))
        throw new SourceError('policy.code.snapshot','Conflicting file/directory observations in the captured code snapshot');
    const missing=()=>Object.assign(Error('The captured code lookup is unavailable'),{code:'ENOENT'});
    const observe=(value:string,capability:string)=>{
        spend();
        const id=fromPath(value);
        if(id===undefined)return;
        const key=JSON.stringify([id,capability]);
        if(!requests.has(key)&&requests.size>=2048)throw new SourceError('limit.policy.code.requests','Code dependency acquisition exceeds its request bound');
        requests.set(key,{id,capability});
    };
    const denied=new Set<string>();
    const lookup=(value:string)=>{
        spend();
        if(fromPath(value)===undefined)return undefined;
        const found=files.get(value);
        if(found?.resource.kind==='denied') {
            denied.add(found.uri);throw Object.assign(Error('The code resource capability is denied'),{code:'EACCES'});
        }
        return found;
    };
    const filesystem={
        statSync(value:string) {
            const found=lookup(value);
            if(found?.resource.kind==='absent')throw missing();
            if(found?.resource.kind==='file')return {isFile:()=>true,isDirectory:()=>false,isSymbolicLink:()=>false};
            if(directories.has(value))return {isFile:()=>false,isDirectory:()=>true,isSymbolicLink:()=>false};
            observe(value,'metadata');throw missing();
        },
        readFileSync(value:string) {
            const found=lookup(value);
            if(found?.resource.kind==='absent')throw missing();
            if(found?.resource.kind==='directory')throw Object.assign(Error('A code description must be a captured file'),{code:'EISDIR'});
            if(typeof found?.resource.text==='string')return Buffer.from(found.resource.text);
            observe(value,'content');throw missing();
        },
        readlinkSync() {throw new SourceError('policy.code.symlink','Code symlinks require an explicit approved resource mapping');},
        readdirSync() {throw new SourceError('policy.code.directory','Ambient code directory enumeration is not authorized');},
    };
    const resolvers=new Map<string,ReturnType<typeof ResolverFactory.createResolver>>();
    const resolutions=input.requests.map((request:any)=>{
        if(typeof request?.from!=='string'||typeof request.specifier!=='string'||request.specifier.length>4096||
            !request.specifier.length||/[\u0000-\u001f]/u.test(request.specifier)||!['import','require'].includes(request.mode))
            throw new SourceError('policy.code.request','Invalid captured code import request');
        const result={from:request.from,specifier:request.specifier,mode:request.mode};
        const source=toPath(request.from),owner=files.get(source.path);
        if(!inScope(source.retrieval))throw new SourceError('policy.code.scope','The importing code resource is outside the captured module environment');
        if(owner?.resource.kind!=='file')throw new SourceError('policy.code.importer','The importing code resource is not captured');
        if(isBuiltin(request.specifier))return {...result,builtin:true,target:request.specifier.startsWith('node:')?request.specifier:'node:'+request.specifier};
        if(Object.hasOwn(policyBuiltinModules,request.specifier))return {...result,
            supplied:policyBuiltinModules[request.specifier],target:policyBuiltinModules[request.specifier].target};
        const uriRequest=request.mode==='import'&&(/^(?:\.{1,2}\/|\/|[A-Za-z][A-Za-z0-9+.-]*:)/.test(request.specifier));
        const direct=uriRequest?toPath(policyDependencyUri(request.specifier,source.uri)):undefined;
        if(direct&&!inScope(direct.retrieval)) {
            issues.push({...result,code:'policy.code.scope'});return result;
        }
        if(!uriRequest&&(request.specifier.includes('?')||request.specifier.includes('#')&&!request.specifier.startsWith('#'))) {
            issues.push({...result,code:'policy.code.specifier.suffix'});return result;
        }
        // Absolute native paths can themselves contain '?' or '#'. Passing a
        // file URL through the supported resolver API retains those filenames.
        const nativeURI=new URL('file:///');nativeURI.pathname=request.specifier.replaceAll('%','%25');
        const absoluteRequire=request.mode==='require'&&request.specifier.startsWith('/')?
            toPath(nativeURI.href):undefined;
        if(absoluteRequire&&!inScope(absoluteRequire.retrieval)) {
            issues.push({...result,code:'policy.code.scope'});return result;
        }
        const specifier=direct?new URL('file://'+direct.path.split('/').map(encodeURIComponent).join('/')):absoluteRequire?.path??request.specifier;
        // No browser aliases, PnP hooks, tsconfig, package-map executable loader
        // or ambient configuration can enter this public resolver instance.
        const key=request.mode;
        let resolver=resolvers.get(key);
        if(!resolver) {
            resolver=ResolverFactory.createResolver({fileSystem:filesystem as any,useSyncFileSystemCalls:true,
                conditionNames:['node',key,'module-sync','node-addons'],extensions:['.js','.json','.node'],
                fullySpecified:key==='import',symlinks:false,unsafeCache:false,
                pnpApi:null,tsconfig:false,aliasFields:[],mainFields:['main'],mainFiles:['index'],
                importsFields:['imports'],exportsFields:['exports'],modules:['node_modules'],roots:[],plugins:[]});
            // FS errors may be intentionally swallowed while trying another
            // candidate. A public resolve-step hook propagates our global work
            // bound rather than letting that turn into more fallback work.
            resolver.hooks.resolveStep.tap('BusyAPISnapshotWork',()=>spend());
            resolver.getHook('resolve-in-package').tapAsync({name:'BusyAPIExportsOrigin',stage:-100},(value:any,context:any,callback:any)=>{
                delete value[exportsOrigin];
                const declaration=value.descriptionFileData?.exports;
                if(declaration==null)return callback();
                if(typeof declaration!=='string'&&typeof declaration!=='object')
                    throw executionFailure??=new SourceError('policy.code.package.exports','Invalid Node package exports declaration');
                const owner=files.get(value.descriptionFilePath);
                if(!owner||owner.resource.kind!=='file'||path.dirname(value.descriptionFilePath)!==value.descriptionFileRoot)
                    throw executionFailure??=new SourceError('policy.code.provenance','The selected package declaration has no captured origin');
                value[exportsOrigin]={root:value.descriptionFileRoot,uri:owner.uri};
                callback();
            });
            const nodeTarget=(value:any,context:any,callback:any,imports:boolean)=>{
                const proof=imports?{root:value.descriptionFileRoot,uri:files.get(value.descriptionFilePath)?.uri}:value[exportsOrigin];
                if(!proof)return callback();
                if(typeof proof.uri!=='string'||proof.root!==value.descriptionFileRoot||typeof value.relativePath!=='string'||!value.relativePath.startsWith('./'))
                    return callback(new SourceError('policy.code.provenance','The selected Node package URI target has no captured proof'));
                if(value.relativePath.slice(2).split('/').some((segment:string)=>{
                    const name=decodeURIComponent(segment).toLowerCase();return name==='.'||name==='..'||name==='node_modules';
                }))return callback(new SourceError('policy.code.package.target','Invalid Node package URI target segment'));
                const logical=toPath(policyDependencyUri(value.relativePath+(value.query??'')+(value.fragment??''),proof.uri));
                Object.assign(value,{path:logical.path,relativePath:'./'+path.relative(proof.root,logical.path),fullySpecified:true,
                    query:'',fragment:'',[moduleIdentity]:logical.uri});
                delete value[exportsOrigin];
                callback();
            };
            // The public step hooks observe the maintained resolver's selected
            // target, not our own exports-condition/pattern implementation.
            // 5.26.0 uses `relative` for exports and the distinct imports hook.
            // Decode that proven URL once, retain its module identity, and use
            // exact-file semantics (Node never guesses extensions for exports).
            resolver.getHook('relative').tapAsync({name:'BusyAPINodeExportsURI',stage:-100},(value:any,context:any,callback:any)=>nodeTarget(value,context,callback,false));
            resolver.getHook('imports-field-relative').tapAsync({name:'BusyAPINodeImportsURI',stage:-100},(value:any,context:any,callback:any)=>nodeTarget(value,context,callback,true));
            resolver.hooks.result.tap('BusyAPICapturedModuleResult',(value:any)=>{
                selectedRecord={path:value.path,query:value.query??'',fragment:value.fragment??'',uri:value[moduleIdentity]};
                return value;
            });
            resolvers.set(key,resolver);
        }
        try {
            selectedRecord=undefined;
            const selected=resolver.resolveSync({},path.dirname(source.path),specifier as any);
            if(executionFailure)throw executionFailure;
            const selectedPath=selectedRecord?.path;
            const target=typeof selectedPath==='string'?files.get(selectedPath):undefined;
            if(!target||target.resource.kind!=='file'||typeof target.resource.text!=='string'||!inScope(target.uri)) {
                if(typeof selectedPath==='string')observe(selectedPath,'content');
                issues.push({...result,code:'policy.code.resolution.incomplete'});return result;
            }
            const logical=new URL(selectedRecord.uri??direct?.uri??target.uri);
            if(request.mode==='require') {logical.search='';logical.hash='';}
            if(toPath(logical.href).path!==selectedPath)
                throw new SourceError('policy.code.provenance','The selected module URI does not identify its captured resource');
            return {...result,target:logical.href,resource:target.resource.id};
        } catch(error) {
            if(executionFailure)throw executionFailure;
            if(error instanceof SourceError)throw error;
            issues.push({...result,code:'policy.code.resolution.incomplete'});return result;
        }
    });
    for(const resource of [...denied].sort())issues.push({resource,code:'policy.code.resource.denied'});
    return {version:1,snapshot:input.snapshot,resolver:{name:'enhanced-resolve',version:'5.26.0',node:'24.15.0'},
        ...(scopes?{scopes:[...scopes].sort()}:{}),
        complete:requests.size===0&&issues.length===0,resolutions,
        requests:[...requests.values()].sort((a,b)=>JSON.stringify(a)<JSON.stringify(b)?-1:JSON.stringify(a)>JSON.stringify(b)?1:0),issues};
}
