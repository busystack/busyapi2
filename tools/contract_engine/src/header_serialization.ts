import {schemaContext} from './schema_context';
import {escape} from './document';
import {GraphTarget, ReferenceGraph, supportedSchemaDialect} from './reference_graph';
import {annotationOnlySchema} from './schema_boundaries';

export interface HeaderShape {
  type:string;
  variants?:HeaderShape[];
  items?:HeaderShape;
  prefixItems?:HeaderShape[];
  properties?:Record<string,HeaderShape|undefined>;
  additionalProperties?:HeaderShape;
}

/** Representation hints over the canonical graph, not constraint evaluation.
 * Composition can admit several wire interpretations; each generated instance
 * must still pass the whole original schema. OAS 3.2 §4.24.4.2 permits this
 * explicit conversion policy when findable types do not disambiguate data. */
export function headerShapes(graph:ReferenceGraph) {
  const edges=new Map(graph.references.filter(edge=>edge.kind==='schema'&&edge.keyword==='$ref').map(edge=>[JSON.stringify([edge.resource,edge.pointer]),edge]));
  const cache=new Map<string,HeaderShape|undefined>(), active=new Set<string>();
  let visited=0;
  const variants=(values:(HeaderShape|undefined)[]):HeaderShape=>{
    const options=values.flatMap(value=>value?.type==='union'?value.variants!:value?[value]:[{type:'any'}]);
    const unique=[...new Map(options.map(value=>[JSON.stringify(value),value])).values()];
    return unique.length===1?unique[0]:{type:'union',variants:unique};
  };
  const flatten=(value:HeaderShape):HeaderShape[]=>value.type==='union'?value.variants!.flatMap(flatten):[value];
  const shape=(target:GraphTarget,depth=0):HeaderShape|undefined=>{
    const key=JSON.stringify([target.resource,target.pointer]);
    if(cache.has(key))return cache.get(key);
    if(active.has(key)||depth>=128||++visited>2048)return;
    const scope=schemaContext(graph,target.resource,target.pointer);
    if(!scope||!supportedSchemaDialect(scope))return;
    const value=graph.docs.get(target.resource)?.dataNode(target.pointer)?.value;
    if(value===false||value===true){const result={type:value?'any':'never'};cache.set(key,result);return result;}
    if(!value||typeof value!=='object'||Array.isArray(value))return;
    active.add(key);
    try {
      const constraints:HeaderShape[]=[];
      if(typeof value.$ref==='string') {
        const edge=edges.get(key);
        if(edge?.resolution!=='resolved')return;
        const followed=shape({resource:edge.targetResource!,pointer:edge.targetPointer!,kind:'schema'},depth+1);
        // 3.0 Schema references are Reference Objects. Their siblings never
        // provide representation hints (OAS 3.0 §4.7.23.1).
        if(graph.referenceObject(value,scope)){cache.set(key,followed);return followed;}
        constraints.push(followed??{type:'any'});
      }
      if(Object.hasOwn(value,'not')&&annotationOnlySchema(value.not)){const result={type:'never'};cache.set(key,result);return result;}
      for(const [i]of (Array.isArray(value.allOf)?value.allOf:[]).entries()) {
        const child=shape({...target,pointer:target.pointer+'/allOf/'+i},depth+1);
        constraints.push(child??{type:'any'});
      }
      if(constraints.some(item=>item.type==='never'))return {type:'never'};
      const hints=[...constraints];
      for(const keyword of ['anyOf','oneOf'])if(Array.isArray(value[keyword]))for(const [i]of value[keyword].entries())
        hints.push(shape({...target,pointer:target.pointer+'/'+keyword+'/'+i},depth+1)??{type:'any'});
      if(value.$dynamicRef!==undefined)hints.push({type:'any'});
      const flat=hints.flatMap(flatten),declared=typeof value.type==='string'?[value.type]:Array.isArray(value.type)?value.type:[];
      const types=new Set<string>([...declared,...flat.map(item=>item.type)]);
      if(!types.size||types.has('any'))for(const type of ['string','number','boolean','null','array','object'])types.add(type);
      types.delete('any');
      if(scope.family==='3.0'&&typeof value.type==='string'&&value.nullable===true)types.add('null');
      const results:HeaderShape[]=[];
      for(const type of types){
        const result:HeaderShape={type};
        if(type==='array'){
          const arrays=flat.filter(item=>item.type==='array');
          const items=[...arrays.map(item=>item.items),...(value.items!==undefined?[shape({...target,pointer:target.pointer+'/items'},depth+1)]:[])];
          result.items=items.length?variants(items):{type:'any'};
          const prefix=Array.isArray(value.prefixItems)?value.prefixItems:[],length=Math.max(prefix.length,...arrays.map(item=>item.prefixItems?.length??0));
          if(length)result.prefixItems=Array.from({length},(_,i)=>variants([
            ...arrays.map(item=>item.prefixItems?.[i]??item.items),
            ...(i<prefix.length?[shape({...target,pointer:target.pointer+'/prefixItems/'+i},depth+1)]:value.items!==undefined?[shape({...target,pointer:target.pointer+'/items'},depth+1)]:[]),
          ]));
        }
        if(type==='object'){
          result.properties=Object.create(null);
          const names=new Set([...flat.flatMap(item=>Object.keys(item.properties??{})),...Object.keys(value.properties??{})]);
          for(const name of names){
            const properties=[...flat.filter(item=>item.properties&&Object.hasOwn(item.properties,name)).map(item=>item.properties![name]),
              ...(Object.hasOwn(value.properties??{},name)?[shape({...target,pointer:target.pointer+'/properties/'+escape(name)},depth+1)]:[])];
            result.properties![name]=variants(properties);
          }
          const additional=[...flat.filter(item=>item.additionalProperties!==undefined).map(item=>item.additionalProperties),
            ...(value.additionalProperties!==undefined?[shape({...target,pointer:target.pointer+'/additionalProperties'},depth+1)]:[])];
          result.additionalProperties=additional.length?variants(additional):{type:'any'};
        }
        results.push(result);
      }
      const result=variants(results);cache.set(key,result);return result;
    }finally{active.delete(key);}
  };
  return shape;
}
