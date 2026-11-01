import {SourceDocument,SourceError,escape} from './document';
import {decimal} from './exact_numbers';
import {record} from './engine_worker_client';
import type {Resource} from './engine';
import type {GraphReference} from './reference_graph';

export type SecurityBindingChange={root:string;before:GraphReference;after:GraphReference};
type BindingCopy={kind:'createData';pointer:string;raw:string};

/** Refactoring preserves a scheme's meaning; changing its binding spelling
 * must preserve configured execution too. Keep original environment bindings
 * for other operations/roots and add exact captured aliases. Credentials are
 * neither read nor generated, and conflicting destination settings block the
 * entire reviewed edit rather than replacing a user's configuration. */
export function securityConfigurationCopies(value:unknown,bindings:readonly SecurityBindingChange[]) {
    if(value===undefined||value===null)return;
    const changed=new Map<string,Map<string,SecurityBindingChange>>();
    for(const binding of bindings){
        if(binding.before.value===binding.after.value)continue;
        if(binding.before.connection!=='security'||binding.after.connection!=='security'||binding.before.resolution!=='resolved'||binding.after.resolution!=='resolved')
            throw new SourceError('refactor.configuration.proof','Authentication aliases require proved security bindings');
        const key=JSON.stringify([binding.before.value,binding.after.value]),origins=changed.get(key)??new Map<string,SecurityBindingChange>();
        origins.set(JSON.stringify([binding.root,binding.before.targetResource,binding.before.targetPointer]),binding);
        changed.set(key,origins);
    }
    if(!changed.size)return;
    if(!record(value)||typeof value.id!=='string'||typeof value.text!=='string'||value.text.length>65536||typeof value.identity!=='string'||
        typeof value.generation!=='number'||!Number.isSafeInteger(value.generation)||value.generation<0)
        throw new SourceError('refactor.configuration.snapshot','Expected one bounded captured project configuration');
    const source:Resource={id:value.id,text:value.text,generation:value.generation,identity:value.identity};
    const doc=new SourceDocument(source.text,source.id,true);
    if(doc.issues.length||doc.root.value?.version!==1){
        const range=doc.issues[0]?.range??doc.root.range;
        throw new SourceError('refactor.configuration.syntax','Repair the project configuration before preserving its authentication bindings',range,undefined,{resource:source.id,pointer:'',range});
    }
    const fail=(pointer:string,code:string,message:string):never=>{
        const range=doc.dataNode(pointer)?.range??doc.root.range;
        throw new SourceError(code,message,range,code.startsWith('limit.')?'unsupported':undefined,{resource:source.id,pointer,range});
    };
    const environments=doc.dataNode('/environments');
    if(!environments)return;
    if(environments.kind!=='object')fail('/environments','refactor.configuration.authentication','Environments must be a mapping');
    const identity=(pointer:string,depth=0):string=>{
        if(depth>32)fail(pointer,'limit.refactor.configuration','Authentication configuration exceeds its bounded nesting depth');
        const node=doc.dataNode(pointer)!;
        if(node.kind==='object')return '{'+[...node.children.keys()].sort().map(name=>JSON.stringify(name)+':'+identity(pointer+'/'+escape(name),depth+1)).join(',')+'}';
        if(node.kind==='array')return '['+[...node.children.keys()].map(name=>identity(pointer+'/'+name,depth+1)).join(',')+']';
        if(typeof node.value==='number'){
            const number=decimal(doc.dataJson(pointer));
            return 'number:'+number.coefficient+'e'+number.exponent;
        }
        return JSON.stringify(node.value);
    };
    const actions:BindingCopy[]=[],planned=new Map<string,string>();
    const usages=new Map<string,{resource:string;pointer:string;connection:'security';roots:string[];target:{resource:string;pointer:string};effect:string}>();
    for(const origins of changed.values()){
        const binding=origins.values().next().value!;
        for(const name of environments.children.keys()){
            const owner='/environments/'+escape(name)+'/authentication/schemes',schemes=doc.dataNode(owner);
            if(!schemes)continue;
            if(schemes.kind!=='object')fail(owner,'refactor.configuration.authentication','Authentication schemes must be a mapping');
            const from=owner+'/'+escape(binding.before.value),to=owner+'/'+escape(binding.after.value),original=doc.dataNode(from);
            if(!original)continue;
            if(original.kind!=='object')fail(from,'refactor.configuration.authentication','A configured security binding must be an object');
            const expected=identity(from),existing=doc.dataNode(to);
            if(existing&&identity(to)!==expected||planned.has(to)&&planned.get(to)!==expected)
                fail(to,'refactor.configuration.collision','The destination authentication binding has different settings; resolve that configuration explicitly before refactoring');
            if(!existing&&bindings.some(other=>other.before.value===other.after.value&&other.after.value===binding.after.value))
                fail(to,'refactor.configuration.ambiguous','Adding this authentication alias would also configure an unchanged security binding; choose a different name or explicitly resolve its environment settings before refactoring');
            if(!existing&&!planned.has(to)){
                actions.push({kind:'createData',pointer:to,raw:doc.dataJson(from)});
                planned.set(to,expected);
            }
            for(const origin of origins.values()){
                const key=JSON.stringify([from,origin.before.targetResource,origin.before.targetPointer]);
                const usage=usages.get(key)??{resource:source.id,pointer:from,connection:'security',roots:[],target:{resource:origin.before.targetResource!,pointer:origin.before.targetPointer!},effect:'retain-and-alias-configuration'};
                if(!usage.roots.includes(origin.root))usage.roots.push(origin.root);
                usages.set(key,usage);
            }
        }
    }
    return {source,actions,usages:[...usages.values()]};
}
