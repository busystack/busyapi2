import * as Instance from '@hyperjump/json-schema/instance/experimental';
import {Validation,getSchema,canonicalUri} from '@hyperjump/json-schema/experimental';
import {GraphScope,ReferenceGraph,schemaAddress} from './reference_graph';
import {SourceError,escape} from './document';

export const swaggerDiscriminatorKeyword='urn:busyapi:keyword:swagger-2.0-discriminator';
type Owner={graph:ReferenceGraph;resource:string;pointer:string};

/** OAS 2.0 §6.4.18.2.1: friendly model names and allOf inheritance select the
 * validating schema. Reentry through that child's base must not recursively
 * select the same child forever. Each actual instance and base owns its guard. */
export function swaggerDiscriminator(owner:(schema:any)=>Owner|undefined) {
    const active=new WeakMap<object,Set<string>>();
    return {id:swaggerDiscriminatorKeyword,
        compile:async(_keyword:any,ast:any,parent:any)=>{
            const source=owner(parent);
            if(!source)throw new SourceError('schema.discriminator.owner','The Swagger discriminator has no captured source owner');
            const {graph}=source,value=graph.docs.get(source.resource)!.dataNode(source.pointer)?.value;
            const base=graph.scope(source.resource,source.pointer),baseKey=base.resource+'#'+base.pointer;
            const resolve=(scope:GraphScope):GraphScope|undefined=>{
                const seen=new Set<string>();
                while(true){
                    const key=scope.resource+'#'+scope.pointer;
                    if(seen.has(key)||seen.size>=128)return;
                    seen.add(key);
                    const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
                    if(typeof value?.$ref!=='string')return scope;
                    const ref=graph.resolveReference(value.$ref,scope);
                    if(ref.resolution!=='resolved')return;
                    scope=graph.scope(ref.targetResource!,ref.targetPointer!);
                }
            };
            const inherits=(scope:GraphScope,seen=new Set<string>()):boolean=>{
                const target=resolve(scope);if(!target)return false;
                const key=target.resource+'#'+target.pointer;
                if(key===baseKey)return true;
                if(seen.has(key)||seen.size>=128)return false;
                const next=new Set(seen);next.add(key);
                const branches=graph.docs.get(target.resource)!.dataNode(target.pointer+'/allOf');
                return branches?.kind==='array'&&[...branches.children.keys()].some(index=>inherits(graph.scope(target.resource,target.pointer+'/allOf/'+index),next));
            };
            const definitions=graph.docs.get(graph.root)!.dataNode('/definitions'),models:Record<string,string>={};
            if((definitions?.children.size??0)>20000)throw new SourceError('limit.schema.discriminator','Swagger model selection exceeds its bounded definition count');
            for(const name of definitions?.children.keys()??[]) {
                const scope=graph.scopes.get(graph.root+'#/definitions/'+escape(name));
                if(!scope||!inherits(scope))continue;
                const model=await getSchema(schemaAddress(scope));
                const uri=await Validation.compile(model,ast,model);
                Object.defineProperty(models,name,{value:uri,enumerable:true});
            }
            if(!Object.keys(models).length)throw new SourceError('schema.discriminator.context','Swagger polymorphism requires a named model in the captured definitions namespace');
            return {property:value.discriminator,models,base:canonicalUri(parent)};
        },
        interpret:(selection:any,instance:any,context:any)=>{
            if(Instance.typeOf(instance)!=='object')return true;
            const property=Instance.step(selection.property,instance);
            const value=property?Instance.value(property):undefined;
            if(typeof value!=='string'||!Object.hasOwn(selection.models,value))return false;
            const entries=active.get(instance)??new Set<string>();
            if(entries.has(selection.base))return true;
            entries.add(selection.base);active.set(instance,entries);
            try{return Validation.interpret(selection.models[value],instance,context);}
            finally{entries.delete(selection.base);if(!entries.size)active.delete(instance);}
        },
    };
}
