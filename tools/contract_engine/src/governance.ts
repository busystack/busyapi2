import {createHash} from 'node:crypto';
import {Spectral,Ruleset} from '@stoplight/spectral-core';
import * as functions from '@stoplight/spectral-functions';
import {oas2,oas3,oas3_1,oas3_2} from '@stoplight/spectral-formats';
import * as trustedFormats from '@stoplight/spectral-formats';
import oasModule from '@stoplight/spectral-rulesets/dist/oas';
import {createGraph,analyse} from './engine';
import {SourceDocument,SourceError,escape} from './document';
import {safeFinding} from './security_design';
import {governanceProjection,policyRange} from './governance_projection';
import {compare,decimal,createExactNumericAdapter,nativeNumberIsExact} from './exact_numbers';
import {evaluateSchemas} from './schema_evaluation';
import {serverVariableAdvice} from './authoring_relationships';
import {policyDependencyUri,policyFunctionKey} from './governance_configuration';
import type {ExecutedPolicyCode} from './policy_code_loader';
import {policyFunctionContext} from './policy_function_context';
import {policyExpressionNeedsIsolation as needsIsolation} from './policy_expression';

export const policyProducer={name:'spectral+busyapi-graph',version:'1.24.0+7'};
const formats={oas2,oas3,oas3_1,oas3_2};
const levels=['error','warning','information','hint'];
const hash=(value:string)=>createHash('sha256').update(value).digest('hex');
const recommended={
    aliases:{OperationObject:['$.paths[*][get,put,post,delete,options,head,patch,trace]']},
    formats:[oas2,oas3],
    rules:{'operation-summary':{description:'Give each operation an informative summary.',given:'#OperationObject',then:{field:'summary',function:functions.truthy},severity:'warn',recommended:true},
        'server-variable-declarations':{description:'Review unmapped or unused Server URL variables. This is authoring advice, not a security verdict.',given:'#ServerObject',then:{function:function busyapiServerVariables(value:any,_options:any,context:any){return serverVariableAdvice(value).map(item=>({...item,path:[...context.path,...item.path]}));}},severity:'warn',recommended:true}},
};
const oas=(oasModule as any).default??oasModule;
const builtin:Record<string,any>={'busyapi:recommended':recommended,'spectral:oas':oas};
const configurationKeys=new Set(['extends','rules','aliases','formats','overrides','parserOptions','documentationUrl','description','functions','functionsDir']);

/** Spectral only receives parsed canonical values and graph-owned projections.
 * This explicit public resolver capability has no readers, URI lookup, parser,
 * file or network path. It cannot follow a literal payload $ref or externalValue.
 * Spectral's resolved/unresolved rules run against separate captured views.
 */
const suppliedOnlyResolver=()=>({uriCache:new Map(),resolve:async(value:any)=>({result:value,graph:null,errors:[]})});

export async function govern(input:any,observeFailure?:(error:unknown)=>void,executed?:ExecutedPolicyCode) {
    const {docs,graph,family}=createGraph(input);
    const resources=input.policy?.resources??[],entries=input.policy?.entries??['busyapi:recommended'];
    if(!Array.isArray(resources)||resources.length>64||!Array.isArray(entries)||entries.length>16)
        throw new SourceError('limit.policy.configuration','Governance configuration exceeds its bounded resource limit');
    const configurations=new Map<string,SourceDocument>(),provenance=new Map<string,any[]>(),failures:any[]=[];
    const codeSources=new Map(resources.filter((value:any)=>! /\.(?:ya?ml|json)$/i.test(new URL(value.id).pathname)).map((value:any)=>[value.id,value]));
    const codeLocation=(resource:string)=>{
        const executedSource=executed?.rulesets.get(resource)?.resource??resource,source=codeSources.get(executedSource) as any;
        return source?{resource:source.id,pointer:'',range:[0,source.text.length]}:undefined;
    };
    const knownFunctions=new Set<Function>(Object.values(functions));
    const customFunctions=new Set<Function>([...(executed?.functions.values()??[])].filter(fn=>!knownFunctions.has(fn)));
    const customFormats=new Map<Function,{resource:string;pointer:string}>();
    const knownFormats=new Set(Object.values(trustedFormats));
    const executableAliases=new WeakSet<object>();
    const optionOrigins=new WeakMap<object,{doc:SourceDocument;pointer:string}>();
    const ruleSources=new WeakMap<object,{doc?:SourceDocument;pointer:string;fields:Set<string>}>();
    let configurationBytes=0,ruleCount=0;
    const issue=(resource:string,pointer:string,code:string)=>{
        const doc=configurations.get(resource)??docs.get(resource)??docs.get(input.root)!;
        const location=policyRange(doc,pointer);
        failures.push({...codeLocation(resource)??{resource:doc.id,...location},code});
    };
    for(const resource of resources) {
        if(typeof resource?.id!=='string'||typeof resource?.text!=='string'||configurations.has(resource.id))
            throw new SourceError('policy.configuration','Governance resource identity is missing or duplicated');
        configurationBytes+=resource.text.length*2;
        if(resource.text.length>256*1024||configurationBytes>2*1024*1024)
            throw new SourceError('limit.policy.configuration','Governance configuration exceeds its text limit');
        if(!/\.(?:ya?ml|json)$/i.test(new URL(resource.id).pathname)) {
            if(!executed)issue(input.root,'','policy.code.approval-required');continue;
        }
        const doc=new SourceDocument(resource.text,resource.id,true);
        for(const id of [resource.id,...resource.aliases??[]]) {
            const identity=policyDependencyUri(id,id);
            if(configurations.has(identity)&&configurations.get(identity)!==doc)throw new SourceError('policy.identity','Ambiguous policy resource identity');
            configurations.set(identity,doc);
        }
        if(doc.issues.length)issue(resource.id,'','policy.configuration.syntax');
    }
    const chain=(name:string,resource:string,pointer:string,action:string,definition?:any)=>{
        const doc=configurations.get(resource);
        const history=provenance.get(name)??[];
        const record={...codeLocation(resource)??{resource:doc?.id??resource,pointer,...(doc?{range:policyRange(doc,pointer).range}:{})},action};
        ruleSources.set(record,{doc,pointer,fields:new Set(definition&&typeof definition==='object'?Object.keys(definition):[])});
        history.push(record);provenance.set(name,history);
    };
    const convertFormats=(value:any)=>{
        if(!Array.isArray(value)||value.some(name=>!Object.hasOwn(formats,name)))throw new SourceError('policy.format','Unknown policy format selector');
        return value.map(name=>formats[name]);
    };
    const loaded=new Map<string,any>(),loading=new Set<string>();
    const definitionSources=new WeakMap<object,{source:string;pointer:string}>();
    const load=(id:string):any=>{
        if(!Object.hasOwn(builtin,id))id=policyDependencyUri(id,id);
        if(loading.has(id)) {issue(id,'/extends','policy.ruleset.cycle');return {rules:{}};}
        if(loaded.has(id))return loaded.get(id);
        if(Object.hasOwn(builtin,id)) {
            for(const name of Object.keys(builtin[id].rules))chain(name,id,'/rules/'+escape(name),'definition',builtin[id].rules[name]);
            loaded.set(id,builtin[id]);return builtin[id];
        }
        const source=configurations.get(id);
        const code=executed?.rulesets.get(id);
        if(!source&&!code) {issue(input.root,'','policy.resource.unapproved');return {rules:{}};}
        loading.add(id);
        let nodes=0;
        const compile=(value:any,pointer:string):any=>{
            if(++nodes>2048)throw new SourceError('limit.policy.configuration','Ruleset expansion exceeds its work bound');
            if(code&&value instanceof Ruleset)value=value.definition;
            if(!value||typeof value!=='object'||Array.isArray(value))throw new SourceError('policy.configuration','Expected a declarative ruleset');
            if(Object.keys(value).some(name=>!configurationKeys.has(name)))throw new SourceError('policy.configuration','Unknown ruleset setting');
            const result:any={...value};
            const selectedFormats=(selected:any)=>{
                if(code&&Array.isArray(selected)&&selected.every(item=>typeof item==='function')) {
                    for(const format of selected)if(!knownFormats.has(format))customFormats.set(format,{resource:code.resource,pointer:''});
                    if(customFormats.size>128)throw new SourceError('limit.policy.formats','Too many executable format selectors');
                    return selected;
                }
                return convertFormats(selected);
            };
            if(Object.hasOwn(value,'functions')||Object.hasOwn(value,'functionsDir')) {
                if(code)throw new SourceError('policy.configuration','JavaScript rulesets declare functions directly through the selected public API');
                if(!executed)issue(id,pointer,'policy.code.approval-required');
                else if(!Array.isArray(value.functions??[])||(value.functions??[]).some((entry:any)=>{
                    return typeof entry!=='string'||!executed.functions.has(policyFunctionKey(source!.id,pointer,entry));
                }))issue(id,pointer,'policy.code.function.unavailable');
                delete result.functions;delete result.functionsDir;
            }
            if(value.extends!==undefined) {
                const list=Array.isArray(value.extends)?value.extends:[value.extends];
                if(list.length>16)throw new SourceError('limit.policy.extends','Too many ruleset extensions');
                result.extends=list.map((entry,index)=>{
                    const [target,severity]=Array.isArray(entry)?entry:[entry,undefined];
                    if(code&&target&&typeof target==='object') {
                        const preset=Object.keys(builtin).find(key=>builtin[key]===target);
                        const definition=preset?load(preset):compile(target,pointer+'/extends/'+index);
                        return severity===undefined?definition:[definition,severity];
                    }
                    if(typeof target!=='string'||severity!==undefined&&!['off','recommended','all'].includes(severity))throw new SourceError('policy.extends','Invalid ruleset extension');
                    const key=Object.hasOwn(builtin,target)?target:policyDependencyUri(target,id);
                    return severity===undefined?load(key):[load(key),severity];
                });
            }
            if(value.formats!==undefined)result.formats=selectedFormats(value.formats);
            if(value.aliases!==undefined) {
                result.aliases={};
                for(const [name,alias]of Object.entries(value.aliases)) {
                    if(['__proto__','prototype','constructor'].includes(name))throw new SourceError('policy.alias','Unsafe reserved alias identifier');
                    const validate=(expressions:any)=>{
                        if(!Array.isArray(expressions)||expressions.length>256||expressions.some(expression=>typeof expression!=='string'||expression.length>4096))throw new SourceError('policy.alias','Invalid ruleset alias');
                        const unsafe=expressions.some(expression=>needsIsolation(expression));
                        if(unsafe&&!executed)throw new SourceError('policy.expression.isolation','Executable JSONPath expressions require isolated policy execution');
                        const captured=[...expressions];if(unsafe)executableAliases.add(captured);
                        return captured;
                    };
                    result.aliases[name]=Array.isArray(alias)?validate(alias):{...alias as any,targets:(alias as any).targets.map(target=>({...target,given:validate(target.given),formats:selectedFormats(target.formats)}))};
                }
            }
            if(value.rules!==undefined) {
                result.rules={};
                for(const [name,definition]of Object.entries(value.rules)) {
                    if(++ruleCount>512||!/^[A-Za-z0-9_.-]{1,128}$/.test(name)||['__proto__','prototype','constructor'].includes(name))throw new SourceError('policy.rule.identifier','Invalid, reserved or excessive rule identifiers');
                    const at=pointer+'/rules/'+escape(name);
                    chain(name,id,at,definition&&typeof definition==='object'?'definition':'severity',definition);
                    if(!definition||typeof definition!=='object') {result.rules[name]=definition;continue;}
                    const rule:any={...definition};
                    if(rule.formats!==undefined)rule.formats=selectedFormats(rule.formats);
                    const given=Array.isArray(rule.given)?rule.given:[rule.given];
                    if(given.length>256||given.some(expression=>typeof expression!=='string'||expression.length>4096))throw new SourceError('policy.given','Invalid rule selector');
                    if(given.some(expression=>needsIsolation(expression))&&!executed) {issue(id,at,'policy.expression.isolation');continue;}
                    const actions=Array.isArray(rule.then)?rule.then:[rule.then];
                    const select=(action:any)=>typeof action?.function==='function'&&code?action.function:
                        executed?.functions.get(policyFunctionKey(source?.id??code!.resource,pointer,action?.function))??
                        (typeof action?.function==='string'&&Object.hasOwn(functions,action.function)?(functions as any)[action.function]:undefined);
                    if(actions.some(action=>!action||typeof select(action)!=='function')) {
                        issue(id,at,'policy.code.approval-required');continue;
                    }
                    if(actions.some(action=>action.field!==undefined&&(typeof action.field!=='string'||action.field.length>4096||needsIsolation(action.field,true)&&!executed))) {
                        issue(id,at,'policy.expression.isolation');continue;
                    }
                    rule.then=actions.map((action,index)=>{
                        if(source&&action.functionOptions&&typeof action.functionOptions==='object')optionOrigins.set(action.functionOptions,{doc:source,pointer:at+'/then'+(Array.isArray(rule.then)?'/'+index:'')+'/functionOptions'});
                        const selected=select(action);if(code&&!knownFunctions.has(selected))customFunctions.add(selected);
                        return {...action,function:selected};
                    });
                    result.rules[name]=rule;
                }
            }
            if(value.overrides!==undefined) {
                if(!Array.isArray(value.overrides)||value.overrides.length>128)throw new SourceError('limit.policy.overrides','Too many ruleset overrides');
                result.overrides=value.overrides.map((override,index)=>{
                    const {files,...definition}=override;
                    if(!Array.isArray(files)||files.length>128||files.some(file=>typeof file!=='string'||file.length>4096))throw new SourceError('policy.override','Invalid override file selectors');
                    return {files,...compile(definition,pointer+'/overrides/'+index)};
                });
            }
            if(!result.rules&&!result.extends&&!result.overrides)result.rules={};
            definitionSources.set(result,{source:id,pointer});
            return result;
        };
        let result:any;
        try {result=compile(source?.root.value??code!.definition,'');}
        catch(error) {issue(id,'',error instanceof SourceError?error.code:'policy.configuration');result={rules:{}};}
        loading.delete(id);loaded.set(id,result);return result;
    };
    const definitions=entries.map(entry=>{
        if(typeof entry!=='string')throw new SourceError('policy.entry','Expected a ruleset identity');return load(entry);
    });
    const definition=definitions.length===1?definitions[0]:{extends:definitions};
    const configuration=hash(JSON.stringify({version:1,entries,resources:resources.map(resource=>({id:resource.id,sha256:hash(resource.text)})).sort((a,b)=>a.id.localeCompare(b.id)),producer:policyProducer,
        ...(executed?{code:executed.identity}:{})}));
    let complete=docs.size===input.resources.length&&!graph.issues.some(issue=>issue.incomplete)&&![...docs.values()].some(doc=>doc.issues.length);
    const findings:any[]=[],effective:any[]=[],exact=createExactNumericAdapter();
    const numericContextFindings=new Set<string>();
    function firstInexact(value:any,origin:(path:string[])=>{doc:SourceDocument;pointer:string},path:string[]=[],work={nodes:0}):{doc:SourceDocument;pointer:string}|undefined {
        if(++work.nodes>400000)throw new SourceError('limit.policy.numeric','Governance exactness review exceeds its work bound');
        if(typeof value==='number') {
            const location=origin(path);
            try {if(nativeNumberIsExact(location.doc.dataJson(location.pointer),value))return;}
            catch{}
            return location;
        }
        if(value&&typeof value==='object')for(const [key,child]of Object.entries(value)) {
            const found=firstInexact(child,origin,[...path,key],work);if(found)return found;
        }
    }
    let instanceEvaluation:Promise<any>|undefined;
    let nativeAnalysis:ReturnType<typeof analyse>|undefined;
    const instanceFindings=new Set<string>();
    const add=(origin:{resource:string;pointer:string},code:string,severity:string,extra:any={})=>{
        if(findings.length>=10000)throw new SourceError('limit.policy.findings','Governance findings exceed their limit');
        const doc=docs.get(origin.resource)??configurations.get(origin.resource)??docs.get(input.root)!;
        const location=policyRange(doc,origin.pointer),safe=safeFinding('',location.pointer);
        findings.push({version:1,category:'policy',root:input.root,...codeLocation(origin.resource)??{resource:doc.id,range:location.range,pointer:safe.pointer},
            ...(location.pointer!==origin.pointer?{occurrencePointer:safeFinding('',origin.pointer).pointer}:{}),code,severity,
            message:code.startsWith('policy.rule.')?'The originating value does not satisfy this effective governance rule. Inspect its source and rule definition.':'Required governance work did not complete. Inspect the effective rule configuration.',
            producer:policyProducer.name,producerVersion:policyProducer.version,snapshot:input.snapshot,configuration,...extra});
    };
    const formatResults=new Map<Function,boolean|null>();
    let authoredFormatValue:any,authoredNumberCheck:()=>ReturnType<typeof firstInexact>;
    for(const resolved of [false,true]) {
        const projection=governanceProjection(graph,resolved);
        let documentNumbers:ReturnType<typeof firstInexact>,documentNumbersChecked=false;
        const inexactDocument=()=>{
            if(!documentNumbersChecked) {
                documentNumbersChecked=true;
                documentNumbers=firstInexact(projection.value,path=>{
                    const origin=projection.origin(path);return {doc:docs.get(origin.resource)!,pointer:origin.pointer};
                });
            }
            return documentNumbers;
        };
        const pathsByOrigin=new Map<string,(string|number)[][]>();
        for(const [pointer,origin]of projection.origins) {
            const key=JSON.stringify([origin.resource,origin.pointer]),paths=pathsByOrigin.get(key)??[];
            paths.push(pointer===''?[]:pointer.slice(1).split('/').map(part=>part.replaceAll('~1','/').replaceAll('~0','~')));pathsByOrigin.set(key,paths);
        }
        const freeze=(value:any)=>{if(value&&typeof value==='object'){for(const child of Object.values(value))freeze(child);Object.freeze(value);}};
        freeze(projection.value);
        if(!resolved){authoredFormatValue=projection.value;authoredNumberCheck=inexactDocument;}
        if(resolved)for(const problem of projection.problems) {complete=false;add(problem.origin,problem.code,'warning');}
        let ruleset:Ruleset;
        const pointerLayers=new Map<string,any[]>(),activeDeclarations=new Set<string>();
        // Each declarative file owns its relative override globs. Apply the
        // pinned public fromSource API at that node before inheriting it; the
        // upstream constructor otherwise ignores all inherited override blocks.
        // Pointer severity layers retain their original ruleset source rather
        // than rebasing them to the entry ruleset or flattened contract.
        const sourceKey=(source:string,pointer:string)=>JSON.stringify([source,pointer]);
        const selectedProvenance=(name:string)=>(provenance.get(name)??[]).filter(item=>activeDeclarations.has(sourceKey(item.resource,ruleSources.get(item)?.pointer??item.pointer)));
        const severityFor=(rule:any,path:(string|number)[])=>{
            let severity=rule.severity;
            for(const layer of pointerLayers.get(rule.name)??[]) {
                const before=layer.severity;layer.severity=severity;
                try {severity=layer.getSeverityForSource(input.root,path);}finally {layer.severity=before;}
            }
            return severity;
        };
        try {
            let normalizedNodes=0;
            const bind=(value:any):any=>{
                if(++normalizedNodes>2048)throw new SourceError('limit.policy.overrides','Ruleset override expansion exceeds its work bound');
                const owner=definitionSources.get(value),source=owner?.source??input.policy?.source??input.root;
                const physical=configurations.get(source)?.id??executed?.rulesets.get(source)?.resource??source;
                const normalizeEntry=(entry:any)=>Array.isArray(entry)?[bind(entry[0]),entry[1]]:bind(entry);
                const base:any={...value,aliases:{...value.aliases,...projection.aliases()},
                    ...(value.extends?{extends:(Array.isArray(value.extends)?value.extends:[value.extends]).map(normalizeEntry)}:{})};
                const builtinId=Object.keys(builtin).find(id=>builtin[id]===value);
                for(const name of Object.keys(value.rules??{}))if(owner||builtinId)
                    activeDeclarations.add(sourceKey(builtinId??physical,(owner?.pointer??'')+'/rules/'+escape(name)));
                const overrides=(value.overrides??[]).map((override,index)=>{
                    const priorDeclarations=new Set(activeDeclarations),priorLayers=new Map([...pointerLayers].map(([name,layers])=>[name,[...layers]]));
                    const {files,...body}=override;
                    const bound={...body,...(body.aliases?{aliases:{...body.aliases,...projection.aliases()}}:{}),
                        ...(body.extends?{extends:(Array.isArray(body.extends)?body.extends:[body.extends]).map(normalizeEntry)}:{})};
                    const block={files,...bound};
                    const probe=new Ruleset({...base,overrides:[block]},{source});
                    if(probe.fromSource(input.root)!==probe) {
                        for(const name of Object.keys(body.rules??{}))activeDeclarations.add(sourceKey(physical,(owner?.pointer??'')+'/overrides/'+index+'/rules/'+escape(name)));
                    } else {
                        activeDeclarations.clear();for(const item of priorDeclarations)activeDeclarations.add(item);
                        pointerLayers.clear();for(const [name,layers]of priorLayers)pointerLayers.set(name,layers);
                    }
                    return block;
                });
                const applied=new Ruleset({...base,...(overrides.length?{overrides}:{})},{source}).fromSource(input.root);
                for(const [name,rule]of Object.entries(applied.rules))if(rule.overrides) {
                    const layers=pointerLayers.get(name)??[];
                    if(!layers.some(layer=>layer.overrides===rule.overrides))layers.push(rule);
                    pointerLayers.set(name,layers);
                }
                const {overrides:_,...normalized}=applied.definition;
                return normalized;
            };
            ruleset=new Ruleset(bind(definition),{source:input.policy?.source??input.root});
        }catch(error) {observeFailure?.(error);complete=false;add({resource:input.root,pointer:''},'policy.configuration','error');continue;}
        const detectedFormats=new Set<any>(family==='2.0'?[oas2]:[oas3,...(family==='3.0'?[]:[family==='3.1'?oas3_1:oas3_2])]);
        const registered=new Set<any>(ruleset.formats);
        for(const rule of Object.values(ruleset.rules))for(const alias of Object.values(rule.owner.aliases??{}) as any[])
            for(const target of alias?.targets??[])for(const format of target.formats??[])registered.add(format);
        for(const format of registered)if(customFormats.has(format)) {
            if(!formatResults.has(format)) {
                const authoredFormatNumbers=authoredNumberCheck!();
                if(authoredFormatNumbers) {
                    complete=false;add({resource:authoredFormatNumbers.doc.id,pointer:authoredFormatNumbers.pointer},'policy.numeric.format.incomplete','warning');
                    formatResults.set(format,null);
                } else try {
                    const result=await format(authoredFormatValue,input.root);
                    if(typeof result!=='boolean')throw new SourceError('policy.format.result','An executable format must return a boolean');
                    formatResults.set(format,result);
                }catch(error) {
                    observeFailure?.(error);complete=false;add(customFormats.get(format)!,error instanceof SourceError?error.code:'policy.format.execution.failed','error');
                    formatResults.set(format,null);
                }
            }
            if(formatResults.get(format)===true)detectedFormats.add(format);
        }
        const selectorProofs=new WeakMap<object,boolean>();
        const projectSelector=(rule:any,provenance:any[])=>{
            const owner=[...provenance].reverse().find(entry=>ruleSources.get(entry)?.fields.has('given'));
            if(owner&&!Object.hasOwn(builtin,owner.resource)&&rule.given.some(expression=>needsIsolation(expression)))return true;
            if(rule.then.some(action=>typeof action.field==='string'&&needsIsolation(action.field,true)))return true;
            if(selectorProofs.has(rule))return selectorProofs.get(rule)!;
            // Ask the public Ruleset API to expand an inert alias probe. Only
            // marked project expressions are substituted, never API data or
            // executed policy. This preserves nested/format-scoped alias logic
            // without implementing another alias interpreter.
            let marked=false;
            const expanded=rule.getGivenForFormats(detectedFormats);
            let nonce=0,sentinel:string;
            do {sentinel='$["busyapi-isolated-alias-'+nonce+++'"]';}
            while(expanded.some(expression=>expression.includes(sentinel)));
            const aliases:any={};
            for(const [name,value]of Object.entries(rule.owner.aliases??{}) as [string,any][]) {
                if(Array.isArray(value)) {
                    const unsafe=executableAliases.has(value);marked||=unsafe;aliases[name]=unsafe?[sentinel]:value;
                } else aliases[name]={...value,targets:value.targets.map((target:any)=>{
                    const unsafe=executableAliases.has(target.given);marked||=unsafe;
                    return {...target,formats:[...target.formats],given:unsafe?[sentinel]:target.given};
                })};
            }
            let unsafe=false;
            if(marked) {
                const probe=new Ruleset({aliases,rules:{probe:{given:rule.given,then:{function:functions.truthy}}}});
                unsafe=probe.rules.probe.getGivenForFormats(detectedFormats).some(expression=>expression.includes(sentinel));
            }
            selectorProofs.set(rule,unsafe);return unsafe;
        };
        const rules:any={};
        let invocations=0,produced=0;
        for(const [name,rule]of Object.entries(ruleset.rules)) {
            if(rule.resolved!==resolved)continue;
            const ruleProvenance=selectedProvenance(name);
            effective.push({name,severity:rule.severity<0?'off':levels[rule.severity],enabled:rule.enabled&&rule.severity>=0||pointerLayers.has(name),resolved:rule.resolved,
                applicable:rule.matchesFormat(detectedFormats),
                provenance:ruleProvenance,functions:rule.then.map(action=>customFunctions.has(action.function)?'reviewed-custom-function':action.function.name),
                given:rule.given,documentationUrl:rule.documentationUrl});
            if((!rule.enabled||rule.severity<0)&&!pointerLayers.has(name)||!rule.matchesFormat(detectedFormats))continue;
            if(executed&&projectSelector(rule,ruleProvenance)) {
                const location=inexactDocument();
                if(location) {complete=false;add({resource:location.doc.id,pointer:location.pointer},'policy.numeric.selector.incomplete','warning',{rule:name});continue;}
            }
            const fieldNumbers=new Map<string,ReturnType<typeof firstInexact>>();
            const inexactRuleField=(field:'then'|'extensions',optionsIndex?:number)=>{
                const key=field+':'+(optionsIndex??'all');
                if(fieldNumbers.has(key))return fieldNumbers.get(key);
                for(const declaration of [...ruleProvenance].reverse()) {
                    const source=ruleSources.get(declaration);
                    if(!source?.fields.has(field))continue;
                    // JS-authored values have JavaScript numeric semantics;
                    // they were not parsed from canonical YAML/JSON data.
                    if(!source.doc)break;
                    const base=source.pointer+'/'+field;
                    let node=source.doc.dataNode(base);
                    if(optionsIndex!==undefined)node=source.doc.dataNode(base+
                        (Array.isArray(node?.value)?'/'+optionsIndex:'')+'/functionOptions');
                    const found=node?firstInexact(node.value,path=>({doc:source.doc!,pointer:node!.pointer+
                        (path.length?'/'+path.map(escape).join('/'):'')})):undefined;
                    fieldNumbers.set(key,found);return found;
                }
                fieldNumbers.set(key,undefined);return;
            };
            // Functions receive canonical values. Fail closed where an upstream
            // numeric comparison would otherwise observe a rounded JS number.
            const actions=rule.then.map((action,actionIndex)=>{
                const original=action.function;
                const deniedNumber=(location:ReturnType<typeof firstInexact>)=>{
                    if(!location)return;
                    complete=false;
                    const key=JSON.stringify([name,location.doc.id,location.pointer]);
                    if(!numericContextFindings.has(key)) {
                        numericContextFindings.add(key);
                        add({resource:location.doc.id,pointer:location.pointer},'policy.numeric.context.incomplete','warning',{rule:name});
                    }
                    throw new SourceError('policy.numeric.context.incomplete','A public rule-context read cannot preserve this source number exactly');
                };
                const publicContext=customFunctions.has(original)?policyFunctionContext(
                    ()=>deniedNumber(inexactDocument()),field=>deniedNumber(inexactRuleField(field)),detectedFormats):undefined;
                return {...action,function:(value:any,options:any,context:any)=>{
                    if(severityFor(rule,context.path)<0)return;
                    if(++invocations>400000)throw new SourceError('limit.policy.work','Governance execution exceeds its rule work bound');
                    const preset=ruleProvenance.filter(item=>item.action==='definition').at(-1)?.resource==='spectral:oas';
                    const origin=projection.origin(context.path),kind=origin.kind;
                    if(preset&&['operation-operationId-unique','path-params'].includes(name)) {
                        nativeAnalysis??=analyse(input,{docs,graph,family});
                        const findings=nativeAnalysis.findings.filter(finding=>name==='operation-operationId-unique'?finding.code==='operation.id.duplicate':finding.code.startsWith('parameter.path.'));
                        return findings.flatMap(finding=>(pathsByOrigin.get(JSON.stringify([finding.resource,finding.pointer]))??[]).map(path=>({path,message:'A canonical semantic relationship does not meet this rule.'})));
                    }
                    if(preset&&name==='operation-tag-defined') {
                        const names=new Set((docs.get(input.root)!.root.value.tags??[]).filter(tag=>tag&&typeof tag.name==='string').map(tag=>tag.name));
                        const missing:any[]=[];
                        for(const scope of graph.scopes.values())if(scope.kind==='operation') {
                            const tags=docs.get(scope.resource)!.dataNode(scope.pointer)?.value?.tags;
                            if(!Array.isArray(tags))continue;
                            for(let index=0;index<tags.length;index++)if(typeof tags[index]==='string'&&!names.has(tags[index]))
                                for(const path of pathsByOrigin.get(JSON.stringify([scope.resource,scope.pointer+'/tags/'+index]))??[])missing.push({path,message:'An operation tag has no root declaration.'});
                        }
                        return missing;
                    }
                    if(preset&&name==='oas3-operation-security-defined') {
                        const missing:any[]=[];
                        for(const ref of graph.references)if(ref.connection==='security'&&ref.resource===origin.resource&&ref.pointer===origin.pointer&&ref.resolution!=='resolved') {
                            for(const path of pathsByOrigin.get(JSON.stringify([ref.resource,ref.pointer+'/'+escape(ref.keyword)]))??[])missing.push({path,message:'A required scheme has no unambiguous graph target.'});
                        }
                        return missing;
                    }
                    if(preset&&['oas3-valid-media-example','oas3-valid-schema-example'].includes(name)) {
                        const media=name==='oas3-valid-media-example';
                        if(media?!['media','parameter','header'].includes(kind):kind!=='schema')return;
                        instanceEvaluation??=evaluateSchemas({...input,policyAnnotations:true},undefined,{docs,graph,family});
                        return instanceEvaluation.then(evaluated=>{
                            if(evaluated.complete!==true) {
                                const key=name+':incomplete';
                                if(!instanceFindings.has(key)){instanceFindings.add(key);complete=false;add(origin,'policy.schema.execution.incomplete','warning',{rule:name});}
                            }
                            const schemaPointer=origin.pointer+(media?'/schema':'');
                            for(const finding of evaluated.findings) {
                                if(finding.code!=='example.schema.incompatible'||finding.schema?.resource!==origin.resource||finding.schema.pointer!==schemaPointer)continue;
                                if(media?finding.interpretation!=='authored-data':!['schema-annotation','policy-annotation'].includes(finding.interpretation))continue;
                                const key=JSON.stringify([name,finding.resource,finding.pointer,finding.schema]);
                                if(instanceFindings.has(key))continue;instanceFindings.add(key);
                                const severity=severityFor(rule,context.path);
                                if(severity>=0)add(finding,'policy.rule.'+name,levels[severity],{rule:name,ruleProvenance,schema:finding.schema,
                                    explanation:'The explicitly selected policy requires compatibility with the associated authored schema. Exact source values and the selected dialect evaluation stack were used.'});
                            }
                            return [];
                        });
                    }
                    if(preset&&name==='duplicated-entry-in-enum') {
                        const parent=projection.origin(context.path.slice(0,-1));
                        if(parent.kind!=='schema'||!Array.isArray(value))return;
                        const seen=new Set<string>(),duplicates:any[]=[];let cost=0;
                        for(let index=0;index<value.length;index++) {
                            const source=projection.origin([...context.path,index]);
                            const key=exact.fingerprintSource(docs.get(source.resource)!,source.pointer);
                            if((cost+=key.length)>32*1024*1024)throw new SourceError('limit.policy.numeric','Exact enum equality exceeds its byte bound');
                            if(seen.has(key))duplicates.push({path:[...context.path,index],message:'Duplicate exact enum value.'});seen.add(key);
                        }
                        return duplicates;
                    }
                    if(preset&&name==='typed-enum') {
                        if(kind!=='schema'||!Array.isArray(value?.enum))return;
                        const types=Array.isArray(value.type)?value.type:[value.type],mismatches:any[]=[];
                        for(let index=0;index<value.enum.length;index++) {
                            const item=value.enum[index];let type=item===null?'null':Array.isArray(item)?'array':typeof item;
                            if(type==='number') {
                                const source=projection.origin([...context.path,'enum',index]),number=decimal(docs.get(source.resource)!.dataJson(source.pointer));
                                if(types.includes('integer')&&(number.coefficient===0n||number.exponent>=0n))type='integer';
                            }
                            if(!types.includes(type))mismatches.push({path:[...context.path,'enum',index],message:'Enum value does not have a declared schema type.'});
                        }
                        return mismatches;
                    }
                    if(original===functions.unreferencedReusableObject||preset&&name==='oas3-unused-component') {
                        const groups=preset&&name==='oas3-unused-component'
                            ?Object.keys(value?.components??{}).filter(group=>projection.kinds.get('/components/'+escape(group))!=='data').map(group=>[...context.path,'components',group])
                            :[context.path];
                        const unused:any[]=[];
                        for(const path of groups) {
                            const group=projection.origin(path),map=docs.get(group.resource)!.dataNode(group.pointer);
                            if(!group.pointer.startsWith('/components/')||group.pointer.split('/').length!==3||!group.kind.endsWith('-map')) {
                                complete=false;add(group,'policy.usage.context.incomplete','warning',{rule:name});continue;
                            }
                            if(original===functions.unreferencedReusableObject&&options?.reusableObjectsLocation!=='#'+group.pointer) {
                                complete=false;add(group,'policy.usage.context.incomplete','warning',{rule:name});continue;
                            }
                            for(const key of map?.children.keys()??[]) {
                                if(key.startsWith('x-'))continue;
                                const pointer=group.pointer+'/'+escape(key);
                                const used=graph.references.some(ref=>ref.resolution==='resolved'&&ref.targetResource===group.resource&&
                                    (ref.targetPointer===pointer||ref.targetPointer?.startsWith(pointer+'/'))||
                                    ref.dynamic?.candidates.some(candidate=>candidate.resource===group.resource&&(candidate.pointer===pointer||candidate.pointer.startsWith(pointer+'/'))));
                                if(!used)unused.push({path:[...path,key],message:'Potentially unused reusable definition.'});
                            }
                        }
                        return unused;
                    }
                    if(preset) {
                        if(['duplicated-entry-in-enum','typed-enum','oas3-valid-schema-example'].includes(name)&&kind!=='schema')return;
                        if(name==='oas3-valid-media-example'&&!['media','parameter','header'].includes(kind))return;
                        if(name==='oas3-parameter-description'&&kind!=='parameter')return;
                        if(['no-eval-in-markdown','no-script-tags-in-markdown'].includes(name)&&projection.origin(context.path.slice(0,-1)).kind==='data')return;
                        if(name==='oas3_2-no-deprecated-xml-attribute'&&projection.origin(context.path.slice(0,-1)).kind!=='schema')return;
                        if(name==='no-$ref-siblings') {
                            const parent=projection.origin(context.path.slice(0,-1));
                            if(parent.kind==='data'||parent.kind==='schema')return;
                            const object=docs.get(parent.resource)!.dataNode(parent.pointer)?.value;
                            const keys=Object.keys(object??{}).filter(key=>!['$ref','summary','description'].includes(key));
                            return keys.map(key=>({path:[...context.path.slice(0,-1),key],message:'Reference Object siblings must follow the selected specification.'}));
                        }
                    }
                    const numeric=customFunctions.has(original)||!preset&&([functions.schema,functions.enumeration,functions.alphabetical,functions.length].includes(original as any)||/^(?:oasSchema|oasExample|typedEnum)\d*$/.test(original.name));
                    if(numeric) {
                        let visited=0;
                        const exact=(path:(string|number)[],value:any):boolean=>{
                            if(++visited>400000)throw new SourceError('limit.policy.numeric','Governance numeric work exceeds its bound');
                            if(typeof value==='number') {
                                const origin=projection.origin(path),doc=docs.get(origin.resource)!;
                                try {return nativeNumberIsExact(doc.dataJson(origin.pointer),value);}catch{return false;}
                            }
                            return !value||typeof value!=='object'||Object.entries(value).every(([key,child])=>exact([...path,key],child));
                        };
                        if(!exact(context.path,value)) {complete=false;add(projection.origin(context.path),'policy.numeric.incomplete','warning',{rule:name});return [];}
                        if(publicContext&&options!==null&&options!==undefined)deniedNumber(inexactRuleField('then',actionIndex));
                        const source=options&&typeof options==='object'?optionOrigins.get(options):undefined;
                        if(source) {
                            const inspect=(value:any,pointer:string):boolean=>{
                                if(typeof value==='number')return nativeNumberIsExact(source.doc.dataJson(pointer),value);
                                return !value||typeof value!=='object'||Object.entries(value).every(([key,child])=>inspect(child,pointer+'/'+escape(key)));
                            };
                            if(!inspect(options,source.pointer)) {complete=false;add({resource:source.doc.id,pointer:source.pointer},'policy.numeric.incomplete','warning',{rule:name});return [];}
                        }
                    }
                    const bounded=(result:any)=>{
                        if(result!==undefined&&(!Array.isArray(result)||(produced+=result.length)>10000))throw new SourceError('limit.policy.findings','Governance findings exceed their bound');
                        return result;
                    };
                    // These two pinned bundled functions observe only input
                    // truthiness (and still validate their original options).
                    // A finite mathematical nonzero value may underflow to JS
                    // zero. Supply its exact truth value to that function only;
                    // neither source nor the immutable document is changed.
                    let functionValue=value;
                    if(value===0&&(original===functions.truthy||original===functions.falsy)) {
                        const source=projection.origin(context.path),doc=docs.get(source.resource)!;
                        if(decimal(doc.dataJson(source.pointer)).coefficient!==0n)functionValue=true;
                    }
                    const result=original(functionValue,options,publicContext?publicContext(context,rule):context);
                    return result&&typeof (result as any).then==='function'?(result as any).then(bounded):bounded(result);
                }};
            });
            rules[name]={...rule.definition,severity:pointerLayers.has(name)&&rule.severity<0?'hint':rule.severity,recommended:true,resolved:false,then:actions,message:'Governance rule finding.',description:'Governance rule finding.',given:rule.getGivenForFormats(detectedFormats)};
            delete rules[name].formats;
        }
        if(!Object.keys(rules).length)continue;
        const spectral=new Spectral({resolver:suppliedOnlyResolver() as any});
        try {
            spectral.setRuleset({rules,formats:[oas2,oas3,oas3_1,oas3_2]});
            const results=await spectral.run({source:input.root,parsed:{data:projection.value,diagnostics:[]},
                getLocationForJsonPath:()=>({range:{start:{line:0,character:0},end:{line:0,character:0}}})});
            for(const result of results) {
                const name=String(result.code),safe=safeFinding(name,'');
                const rule=safe.masked?'masked-'+hash(name).slice(0,16):name;
                const definition=ruleset.rules[name];
                const severity=definition?severityFor(definition,result.path):result.severity;
                if(severity<0)continue;
                add(projection.origin(result.path),'policy.rule.'+rule,levels[severity]??'warning',{rule,ruleProvenance:selectedProvenance(name),
                    ...(definition?.description?{explanation:safeFinding(definition.description,'').message}:{} )});
            }
        }catch(error) {
            observeFailure?.(error);
            complete=false;add({resource:input.root,pointer:''},error instanceof SourceError?error.code:'policy.execution.failed','error');
        }
    }
    for(const failure of failures) {complete=false;add(failure,failure.code,'error');}
    if(executed?.denials.size) {complete=false;add({resource:input.root,pointer:''},'policy.code.load.unreviewed','error');}
    exact.dispose();
    // A rule identifier or selector is project-authored too. Effective-rule
    // records are routine JSON/UI output, not permission to echo likely secrets.
    const displayRule=(name:string)=>safeFinding(name,'').masked?'masked-'+hash(name).slice(0,16):name;
    const displayProvenance=(entries:any[])=>entries.map(entry=>({...entry,pointer:safeFinding('',entry.pointer).pointer}));
    for(const finding of findings) {
        if(finding.ruleProvenance)finding.ruleProvenance=displayProvenance(finding.ruleProvenance);
        if(typeof finding.rule==='string')finding.rule=displayRule(finding.rule);
    }
    for(const rule of effective) {
        rule.name=displayRule(rule.name);
        rule.given=rule.given.map(expression=>safeFinding(expression,'').message);
        rule.provenance=displayProvenance(rule.provenance);
    }
    return {version:1,complete,status:complete?'complete':'incomplete',producer:policyProducer.name,producerVersion:policyProducer.version,snapshot:input.snapshot,configuration,
        coverage:'canonical-graph-oas-reference-objects;authored-schema-applicators;'+(executed?'reviewed-isolated-code-v1':'no-project-code'),effectiveRules:effective,findings};
}
