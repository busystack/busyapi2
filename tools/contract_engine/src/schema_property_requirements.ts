import {supportedSchemaDialect,type GraphTarget,type ReferenceGraph} from './reference_graph';
import {projectSchemaReference} from './schema_reference_projection';

/** Positive property-presence proof over captured Schema Objects. Core 10.2
 * composition and fixed applicators can establish required properties. A cycle,
 * unknown dialect or exhausted budget cannot establish a positive result. */
export class SchemaPropertyRequirements {
 private readonly edges=new Map<string,GraphTarget[]>();
 private work=0;
 constructor(private readonly graph:ReferenceGraph){
  for(const reference of graph.references){
   const projection=projectSchemaReference(reference);
   if(projection.state!=='fixed')continue;
   const key=this.key(reference),targets=this.edges.get(key)??[];
   targets.push(projection.target);this.edges.set(key,targets);
  }
 }
 private key=(target:GraphTarget)=>JSON.stringify([target.resource,target.pointer]);
 get exhausted():boolean{return this.work>20000;}
 consume():boolean{return ++this.work<=20000;}
 requires(target:GraphTarget,name:string,seen:ReadonlySet<string>=new Set()):boolean {
  const key=this.key(target);
  if(seen.has(key)||seen.size>=128||!this.consume())return false;
  const scope=this.graph.scopes.get(target.resource+'#'+target.pointer);
  if(!scope||!supportedSchemaDialect(scope))return false;
  const value=this.graph.docs.get(target.resource)?.dataNode(target.pointer)?.value;
  if(!value||typeof value!=='object'||Array.isArray(value))return false;
  if(Array.isArray(value.required)&&value.required.includes(name))return true;
  const nested=new Set(seen).add(key);
  if(this.edges.get(key)?.some(reference=>this.requires(reference,name,nested)))return true;
  const child=(keyword:string,index:number)=>({...target,pointer:target.pointer+'/'+keyword+'/'+index});
  if(Array.isArray(value.allOf)&&value.allOf.some((_:unknown,index:number)=>this.requires(child('allOf',index),name,nested)))return true;
  for(const keyword of ['anyOf','oneOf'])if(Array.isArray(value[keyword])&&value[keyword].length&&value[keyword].every((_:unknown,index:number)=>this.requires(child(keyword,index),name,nested)))return true;
  return false;
 }
}

