import * as Instance from '@hyperjump/json-schema/instance/experimental';
import {Validation,getSchema,canonicalUri} from '@hyperjump/json-schema/experimental';
import {ReferenceGraph,schemaAddress} from './reference_graph';
import {SourceError} from './document';
import {SwaggerDiscriminatorModels} from './swagger_discriminator_models';

export const swaggerDiscriminatorKeyword='urn:busyapi:keyword:swagger-2.0-discriminator';
type Owner={graph:ReferenceGraph;resource:string;pointer:string};

/** OAS 2.0 §6.4.18.2.1: friendly model names and allOf inheritance select the
 * validating schema. Reentry through that child's base must not recursively
 * select the same child forever. Each actual instance and base owns its guard. */
export function swaggerDiscriminator(owner:(schema:any)=>Owner|undefined) {
    const active=new WeakMap<object,Set<string>>();
    const selections=new WeakMap<ReferenceGraph,SwaggerDiscriminatorModels>();
    return {id:swaggerDiscriminatorKeyword,
        compile:async(_keyword:any,ast:any,parent:any)=>{
            const source=owner(parent);
            if(!source)throw new SourceError('schema.discriminator.owner','The Swagger discriminator has no captured source owner');
            const {graph}=source,value=graph.docs.get(source.resource)!.dataNode(source.pointer)?.value;
            const models:Record<string,string>={};
            let selection=selections.get(graph);
            if(!selection){selection=new SwaggerDiscriminatorModels(graph);selections.set(graph,selection);}
            for(const [name,scope]of selection.models(source)){
                const model=await getSchema(schemaAddress(scope));
                const uri=await Validation.compile(model,ast,model);
                Object.defineProperty(models,name,{value:uri,enumerable:true});
            }
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
