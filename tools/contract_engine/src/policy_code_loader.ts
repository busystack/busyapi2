import {registerHooks,isBuiltin,createRequire} from 'node:module';
import * as core from '@stoplight/spectral-core';
import * as functions from '@stoplight/spectral-functions';
import * as formats from '@stoplight/spectral-formats';
import oasModule from '@stoplight/spectral-rulesets/dist/oas';
import {SourceError} from './document';
import {reviewPolicyCode} from './policy_code_review';
import {policyBuiltinModules} from './policy_builtin_modules';
import {policyFunctionKey} from './governance_configuration';
import {pathToFileURL} from 'node:url';

export type ExecutedPolicyCode={
    identity:string;
    rulesets:Map<string,{resource:string;definition:any}>;
    functions:Map<string,Function>;
    denials:Set<string>;
    close():void;
};

/** Called ONLY after the native restriction has succeeded. Node's supported
 * synchronous hooks load the exact immutable sources/bindings that were
 * reviewed. There is no nextResolve/nextLoad filesystem/network fallback for
 * project code, no transpiler, require shim or second dependency resolver.
 */
export async function loadPolicyCode(input:any,observeFailure?:(error:unknown)=>void):Promise<ExecutedPolicyCode> {
    const execution=input.policy?.execution;
    if(!execution||typeof execution.identity!=='string'||!Array.isArray(execution.resources))
        throw new SourceError('policy.code.approval','Choose a reviewed code identity');
    const review=reviewPolicyCode({policy:{entries:input.policy.entries,resources:input.policy.resources},
        resources:execution.resources,scopes:execution.scopes});
    if(!review.complete||review.identity!==execution.identity)
        throw new SourceError('policy.code.stale','Executable code does not match its reviewed identity');
    const records=new Map(execution.resources.filter((value:any)=>value.kind==='file'&&typeof value.text==='string').map((value:any)=>[value.id,value]));
    const modules=new Map(review.modules.map((value:any)=>[value.uri,value]));
    const bindings=new Map(review.bindings.map((value:any)=>[JSON.stringify([value.from,value.mode,value.specifier]),value]));
    const entryUris=new Set(review.declarations.map((value:any)=>value.uri)),denials=new Set<string>();
    const deny=(code:string):never=>{
        denials.add(code);throw new SourceError(code,'A code load is outside the reviewed immutable dependency closure');
    };
    // A fixed, temporary bridge exposes only these reviewed bundled public APIs
    // to generated adapter modules. It is not a security boundary: the process's
    // kernel restrictions remain mandatory, and no project code runs beforehand.
    const apis:Record<string,any>={
        '@stoplight/spectral-core':Object.freeze({...core}),
        '@stoplight/spectral-functions':Object.freeze({...functions}),
        '@stoplight/spectral-formats':Object.freeze({...formats}),
        '@stoplight/spectral-rulesets':Object.freeze({oas:(oasModule as any).default??oasModule}),
    };
    const bridgeName='__busyapi_policy_api_'+review.identity;
    if(Object.hasOwn(globalThis,bridgeName))throw new SourceError('policy.code.bridge','Conflicting policy API adapter ownership');
    Object.defineProperty(globalThis,bridgeName,{value:Object.freeze(apis),configurable:true});
    const supplied=new Map(Object.entries(policyBuiltinModules).map(([name,value])=>[value.target,{name,...value}]));
    const nativeRequire=createRequire(__filename),loadingCommonJS=new Set<string>();
    const hooks=registerHooks({
        resolve(specifier,context,nextResolve) {
            if(isBuiltin(specifier))return nextResolve(specifier,context);
            const parent=context.parentURL??'',mode=context.conditions.includes('require')?'require':'import';
            const binding=bindings.get(JSON.stringify([parent,mode,specifier])) as any;
            if(binding?.target)return {url:binding.target,shortCircuit:true};
            if(parent===pathToFileURL(__filename).href&&modules.has(specifier)||!modules.has(parent)&&entryUris.has(specifier))
                return {url:specifier,shortCircuit:true};
            return deny('policy.code.load.unreviewed');
        },
        load(url,context,nextLoad) {
            if(url.startsWith('node:'))return nextLoad(url,context);
            const api=supplied.get(url);
            if(api) {
                const value=apis[api.name],exports=Object.keys(value).filter(name=>name!=='default'&&/^[A-Za-z_$][\w$]*$/.test(name));
                const origin=`globalThis[${JSON.stringify(bridgeName)}][${JSON.stringify(api.name)}]`;
                return {format:'module',shortCircuit:true,source:`const api=${origin};\n`+
                    exports.map(name=>`export const ${name}=api[${JSON.stringify(name)}];`).join('\n')+'\nexport default api;'};
            }
            const module=modules.get(url) as any,resource=module&&records.get(module.resource) as any;
            if(!resource)return deny('policy.code.load.unreviewed');
            if(module.format==='commonjs'&&!loadingCommonJS.has(url)) {
                // Node 24's imported-CJS translator still has an ambient
                // _resolveFilename path. Enter the authentic synchronous CJS
                // loader here instead, under these same source/binding hooks.
                // Its normal cache supplies ESM interop afterwards. Only this
                // currently requested module is evaluated, not eager closure
                // preloading or an independently implemented require wrapper.
                loadingCommonJS.add(url);
                try{nativeRequire(url);}finally{loadingCommonJS.delete(url);}
            }
            return {format:module.format,source:resource.text,shortCircuit:true};
        },
    });
    const result:ExecutedPolicyCode={identity:review.identity,rulesets:new Map(),functions:new Map(),denials,
        close(){hooks.deregister();delete (globalThis as any)[bridgeName];}};
    try {
        for(const declaration of review.declarations) {
            // Preserve native ESM/CommonJS interop and evaluation; the hooks
            // supply source, never interpret JavaScript or execute a fake VM.
            const namespace=await import(declaration.uri),value=namespace.default??namespace;
            if(declaration.role==='ruleset')result.rulesets.set(declaration.uri,{resource:declaration.resource,definition:value});
            else {
                if(typeof value!=='function')throw new SourceError('policy.code.function','A reviewed custom function must export a callable function');
                result.functions.set(policyFunctionKey(declaration.resource,declaration.pointer.replace(/\/functions\/\d+$/,''),declaration.name!),value);
            }
        }
        if(denials.size)throw new SourceError('policy.code.load.unreviewed','Code attempted to load an unreviewed dependency');
        return result;
    } catch(error) {
        observeFailure?.(error);
        result.close();
        if(error instanceof SourceError)throw error;
        // An exception may contain contract values, code, secrets or paths.
        throw new SourceError('policy.code.load.failed','Reviewed code could not be loaded');
    }
}
