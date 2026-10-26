import type {GraphTarget,ReferenceGraph} from './reference_graph';
import {supportedSchemaDialect} from './reference_graph';
import {escape} from './document';

export type MultipartFileShape='single'|'array';
export type MultipartShapeStep={property:string}|{item:number|undefined};
type Possibility={possible:boolean;array:boolean};
const unknown:Possibility={possible:true,array:false};

/** Representation hints over one captured graph. These proofs exclude a type
 * only from explicit Schema Object assertions; instance validation still uses
 * the complete original schema. Unknown branches remain possible. */
export class MultipartFileShapes {
 private edges;
 private cache=new Map<string,Possibility>();
 private work=0;
 constructor(private graph:ReferenceGraph){
  this.edges=new Map(graph.references.filter(edge=>edge.kind==='schema'&&edge.keyword==='$ref').map(edge=>[edge.resource+'#'+edge.pointer,edge]));
 }

 choices(schema:GraphTarget,name:string):MultipartFileShape[]{
  const path=[{property:name}],array=this.inspect(schema,path,'array');
  if(!array.possible||!array.array)return [];
  // File shape selection does not choose between object/number/boolean media
  // data models. Those require their existing captured media interpretation.
  if(['object','number','boolean'].some(kind=>this.inspect(schema,path,kind).possible))return [];
  return [...(this.inspect(schema,path,'string').possible?['single' as const]:[]),'array'];
 }

 allows(target:GraphTarget,path:MultipartShapeStep[],kind:string):boolean {
  return this.inspect(target,path,kind).possible;
 }

 private inspect(target:GraphTarget,path:MultipartShapeStep[],kind:string,active:ReadonlySet<string>=new Set(),depth=0):Possibility {
  const key=JSON.stringify([target.resource,target.pointer,path,kind]);
  const cached=this.cache.get(key);if(cached)return cached;
  if(depth>=128||active.has(key)||++this.work>100000)return unknown;
  const scope=this.graph.scopes.get(target.resource+'#'+target.pointer);
  if(!scope||!supportedSchemaDialect(scope))return unknown;
  const value=this.graph.docs.get(target.resource)?.dataNode(target.pointer)?.value;
  if(value===false)return {possible:false,array:false};
  if(!value||typeof value!=='object'||Array.isArray(value))return unknown;
  active=new Set(active).add(key);
  const visit=(at:GraphTarget,steps=path)=>this.inspect(at,steps,kind,active,depth+1);
  let reference:Possibility|undefined;
  if(typeof value.$ref==='string'){
   const edge=this.edges.get(target.resource+'#'+target.pointer);
   reference=edge?.resolution==='resolved'?visit({resource:edge.targetResource!,pointer:edge.targetPointer!,kind:'schema'}):unknown;
   if(scope.family==='3.0')return reference;
  }
  const expected=path.length?'property' in path[0]?'object':'array':kind;
  const types=typeof value.type==='string'?[value.type]:Array.isArray(value.type)?value.type:undefined;
  if(types&&!types.includes(expected)&&!(expected==='number'&&types.includes('integer'))){
   const result={possible:false,array:false};this.cache.set(key,result);return result;
  }
  const constraints:Possibility[]=[...(reference?[reference]:[])];
  for(const [index]of (Array.isArray(value.allOf)?value.allOf:[]).entries())constraints.push(visit({...target,pointer:target.pointer+'/allOf/'+index}));
  for(const keyword of ['anyOf','oneOf'])if(Array.isArray(value[keyword])){
   const alternatives=value[keyword].map((_:unknown,index:number)=>visit({...target,pointer:target.pointer+'/'+keyword+'/'+index}));
   constraints.push({possible:alternatives.some((part:Possibility)=>part.possible),array:alternatives.some((part:Possibility)=>part.possible&&part.array)});
  }
  if(path.length){
   const [step,...rest]=path;
   const pointer='property' in step?Object.hasOwn(value.properties??{},step.property)?target.pointer+'/properties/'+escape(step.property):undefined:
    step.item!==undefined&&Array.isArray(value.prefixItems)&&step.item<value.prefixItems.length?target.pointer+'/prefixItems/'+step.item:
    value.items!==undefined&&!Array.isArray(value.items)?target.pointer+'/items':undefined;
   if(pointer!==undefined)constraints.push(visit({...target,pointer},rest));
  }
  const possible=constraints.every(part=>part.possible);
  const result={possible,array:possible&&(!path.length&&kind==='array'&&(types?.includes('array')===true||value.items!==undefined||value.prefixItems!==undefined)||constraints.some(part=>part.array))};
  this.cache.set(key,result);return result;
 }
}
