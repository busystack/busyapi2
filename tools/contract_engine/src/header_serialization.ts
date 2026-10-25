import {escape} from './document';
import {GraphTarget, ReferenceGraph, supportedSchemaDialect} from './reference_graph';

export interface HeaderShape {
  type:string;
  items?:HeaderShape;
  properties?:Record<string,HeaderShape|undefined>;
  additionalProperties?:HeaderShape;
}

/** Bounded representation inspection of canonical schemas. This does not
 * resolve URIs, evaluate constraints, or infer a type from a received value.
 * Unknown/union representations remain unknown; the canonical evaluator owns
 * validity after the wire representation has been reconstructed. */
export function headerShapes(graph:ReferenceGraph) {
  const edges=new Map(graph.references.filter(edge=>edge.kind==='schema'&&edge.keyword==='$ref').map(edge=>[JSON.stringify([edge.resource,edge.pointer]),edge]));
  const cache=new Map<string,HeaderShape|undefined>(), active=new Set<string>();
  let visited=0;
  const shape=(target:GraphTarget,depth=0):HeaderShape|undefined=>{
    const key=JSON.stringify([target.resource,target.pointer]);
    if(cache.has(key))return cache.get(key);
    if(active.has(key)||depth>=128||++visited>2048)return;
    const scope=graph.scopes.get(target.resource+'#'+target.pointer);
    if(!scope||!supportedSchemaDialect(scope))return;
    const value=graph.docs.get(target.resource)?.dataNode(target.pointer)?.value;
    if(!value||typeof value!=='object'||Array.isArray(value)||value.$dynamicRef!==undefined)return;
    active.add(key);
    try {
      const constraints:HeaderShape[]=[];
      if(typeof value.$ref==='string') {
        const edge=edges.get(key);
        if(edge?.resolution!=='resolved')return;
        const followed=shape({resource:edge.targetResource!,pointer:edge.targetPointer!,kind:'schema'},depth+1);
        if(followed)constraints.push(followed);
      }
      for(const [i]of (Array.isArray(value.allOf)?value.allOf:[]).entries()) {
        const child=shape({...target,pointer:target.pointer+'/allOf/'+i},depth+1);
        if(child)constraints.push(child);
      }
      let type=typeof value.type==='string'?value.type:undefined;
      if(Array.isArray(value.type)&&value.type.length===1)type=value.type[0];
      const constrainedTypes=new Set([...(type?[type]:[]),...constraints.map(item=>item.type)]);
      if(constrainedTypes.has('integer')&&constrainedTypes.has('number'))constrainedTypes.delete('number');
      if(constrainedTypes.size!==1)return;
      type=[...constrainedTypes][0];
      if(!['string','number','integer','boolean','array','object'].includes(type!))return;
      const result:HeaderShape={type:type!};
      if(type==='array') {
        if(value.prefixItems!==undefined)return;
        result.items=value.items!==undefined?shape({...target,pointer:target.pointer+'/items'},depth+1):constraints.find(item=>item.items)?.items;
      }
      if(type==='object') {
        result.properties=Object.assign(Object.create(null),...constraints.map(item=>item.properties??{}));
        for(const name of Object.keys(value.properties??{}))result.properties![name]=shape({...target,pointer:target.pointer+'/properties/'+escape(name)},depth+1)??result.properties![name];
        result.additionalProperties=value.additionalProperties!==undefined?shape({...target,pointer:target.pointer+'/additionalProperties'},depth+1):constraints.find(item=>item.additionalProperties)?.additionalProperties;
      }
      cache.set(key,result);return result;
    }finally{active.delete(key);}
  };
  return shape;
}
