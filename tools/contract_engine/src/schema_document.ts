// Typed projection through Hyperjump 1.18.0's exported media-type Document API.
// Literal annotations/extensions stay literal. Only the canonical graph's
// schema positions undergo schema preprocessing; nothing changes source files.
import {buildSchemaDocument} from '@hyperjump/json-schema/experimental';
import {knownDialects,resolveUri,schemaAddress} from './reference_graph';

const escape = key => key.replaceAll('~','~0').replaceAll('/','~1');
const tokens = pointer => pointer === '' ? [] : pointer.slice(1).split('/').map(s=>s.replaceAll('~1','/').replaceAll('~0','~'));
const embeddedIndexes=new WeakMap<object,Map<string,any>>();
/** The vendor API uses IRIs internally; the graph uses normalized URIs. Only
 * adapt that representation at its supported Document boundary, not by adding
 * another resolver or mutating its embedded-resource registry. */
export function embeddedSchemaDocument(document:any,uri:string) {
 let index=embeddedIndexes.get(document);
 if(!index){index=new Map();for(const [id,value]of Object.entries(document.embedded)){
  const normalized=resolveUri(id,id).href;
  if(index.has(normalized)&&index.get(normalized)!==value)throw Error('Embedded schema URI representations conflict');
  index.set(normalized,value);
 }embeddedIndexes.set(document,index);}
 return index.get(resolveUri(uri,uri).href);
}

export function typedSchemaDocument(value: any, id: string, graph: any, dialect: string): any {
  const scopes=[...graph.scopes.values()].filter((s:any)=>s.resource===id&&s.kind==='schema') as any[];
  const schemaPointers = new Set(scopes.filter(s=>knownDialects.has(s.dialect)).map(s=>s.pointer));
  const applicators=new Map<string,string>();
  for(const reference of graph.references)if(reference.resource===id&&reference.kind==='schema'&&!reference.connection&&reference.resolution==='resolved'){
    const target=graph.scopes.get(reference.targetResource+'#'+reference.targetPointer);
    if(target?.kind!=='schema')continue;
    // The vendor Document represents an embedded $id as a resource Reference,
    // not an ordinary map. A physical pointer traversing that boundary cannot
    // be handed to its generic object walker. Adapt only graph-proven schema
    // applicators to the same canonical resource-relative location. Dynamic
    // references retain a named anchor; actual evaluation still owns the
    // dynamic call stack, never navigation's possible candidates.
    const address=reference.keyword==='$dynamicRef'&&reference.dynamic
      ?target.base+'#'+encodeURIComponent(reference.dynamic.anchor):schemaAddress(target);
    applicators.set(reference.pointer+'/'+escape(reference.keyword),address);
  }
  const opaque = new Set(scopes.filter(s=>!knownDialects.has(s.dialect)).map(s=>s.pointer));
  const ancestors = new Set(['']);
  for (let pointer of schemaPointers) while(pointer) {ancestors.add(pointer);pointer=pointer.slice(0,pointer.lastIndexOf('/'));}
  const literals:any[]=[];
  const prepare=(value,pointer)=>{
    if(value===null||typeof value!=='object') return value;
    const output:any=Array.isArray(value)?[]:{};
    for(const [name,child]of Object.entries(value)) {
      const at=pointer+'/'+escape(name);
      if(schemaPointers.has(pointer)&&applicators.has(at)){
        Object.defineProperty(output,name,{value:applicators.get(at),enumerable:true,writable:true,configurable:true});continue;
      }
      if(opaque.has(at)) {
        // The category is already incomplete and graph dependency guards
        // forbid evaluating a scope which can apply this schema. A neutral
        // compile-only placeholder lets unrelated supported definitions in
        // this physical document remain useful; it is never a result for the
        // unfamiliar schema and never enters canonical source/projections.
        Object.defineProperty(output,name,{value:true,enumerable:true,writable:true,configurable:true});continue;
      }
      // Keyword validity is checked against the original CST. Hyperjump's
      // executable Document must not activate/compile an ordinary schema's
      // meta-schema vocabulary declaration. Literal data retains the key.
      if(name==='$vocabulary'&&schemaPointers.has(pointer))continue;
      // Schema-root dialect selection/meta-validation belongs to GraphScope.
      // Without an $id this is not an embedded Hyperjump Document, whose
      // compiler must not receive the non-executable $schema declaration.
      if(name==='$schema'&&schemaPointers.has(pointer)&&!Object.hasOwn(value,'$id'))continue;
      const literalContainer=child!==null&&typeof child==='object'&&!ancestors.has(at);
      // In a property/definition map, a key such as "$ref" can name a real
      // child schema. It is not the containing object's reference keyword.
      const nonSchemaKeyword=!schemaPointers.has(pointer)&&!schemaPointers.has(at)&&['$schema','$id','$ref','$dynamicRef','$anchor','$dynamicAnchor'].includes(name);
      // Core 8.1.2: $vocabulary is ignored when this resource is not being
      // processed as a meta-schema. Project-defined dialects are separately
      // unsupported/incomplete; never activate their vocabulary merely by
      // constructing an ordinary instance-validation document.
      if(literalContainer||nonSchemaKeyword) {
        const scope=graph.scope(id,pointer);
        literals.push({pointer:at,scope,value:child});
      }else Object.defineProperty(output,name,{value:prepare(child,at),enumerable:true,writable:true,configurable:true});
    }
    return output;
  };
  const prepared=prepare(value,'');
  const host=graph.scope(id,'');
  const hostDialect=!knownDialects.has(dialect)&&host.kind==='root'?`https://spec.openapis.org/oas/${host.family}/dialect/base`:dialect;
  const document=buildSchemaDocument(prepared,host.base,hostDialect);
  for(const resource of Object.values(document.embedded) as any[]){
    const original=resource.anchorLocation;
    // RFC 6901 section 6 decodes the complete URI fragment before pointer
    // evaluation. decodeURI deliberately leaves reserved characters encoded;
    // a property containing literal '#' or '?' would otherwise be mistaken
    // for a different key (and '%' could subsequently be encoded twice).
    // This is our supplied media-type Document callback, not vendor code or
    // a separate reference resolver. Named anchors retain its existing path.
    resource.anchorLocation=(fragment:string|undefined)=>{
      if(typeof fragment==='string'){
        const pointer=decodeURIComponent(fragment);
        if(pointer.startsWith('/'))return pointer;
      }
      return original(fragment);
    };
  }
  for(const literal of literals) {
    const target=embeddedSchemaDocument(document,literal.scope.base);
    if(!target) throw Error('Typed literal resource boundary is absent');
    const path=tokens(literal.pointer.slice(literal.scope.resourcePointer.length));
    const name=path.pop();let container=target.root;
    for(const token of path) container=container[token];
    Object.defineProperty(container,name,{value:literal.value,enumerable:true,writable:true,configurable:true});
  }
  return document;
}
