// Development bridge to Hyperjump's documented media-type Document API.
// Literal annotations/extensions stay literal. Only the canonical graph's
// schema positions undergo schema preprocessing; nothing changes source files.
import {buildSchemaDocument} from '@hyperjump/json-schema/experimental';

const escape = key => key.replaceAll('~','~0').replaceAll('/','~1');
const tokens = pointer => pointer === '' ? [] : pointer.slice(1).split('/').map(s=>s.replaceAll('~1','/').replaceAll('~0','~'));

export function typedSchemaDocument(value, id, graph, dialect) {
  const schemaPointers = new Set([...graph.scopes.values()].filter(s=>s.resource===id&&s.kind==='schema').map(s=>s.pointer));
  const ancestors = new Set(['']);
  for (let pointer of schemaPointers) while(pointer) {ancestors.add(pointer);pointer=pointer.slice(0,pointer.lastIndexOf('/'));}
  const literals=[];
  const prepare=(value,pointer)=>{
    if(value===null||typeof value!=='object') return value;
    const output=Array.isArray(value)?[]:{};
    for(const [name,child]of Object.entries(value)) {
      const at=pointer+'/'+escape(name);
      const literalContainer=child!==null&&typeof child==='object'&&!ancestors.has(at);
      const nonSchemaKeyword=!schemaPointers.has(pointer)&&['$schema','$id','$ref','$dynamicRef','$anchor','$dynamicAnchor'].includes(name);
      if(literalContainer||nonSchemaKeyword) {
        const scope=graph.scope(id,pointer);
        literals.push({pointer:at,scope,value:child});
      }else Object.defineProperty(output,name,{value:prepare(child,at),enumerable:true,writable:true,configurable:true});
    }
    return output;
  };
  const prepared=prepare(value,'');
  const document=buildSchemaDocument(prepared,graph.scope(id,'').base,dialect);
  for(const literal of literals) {
    const target=document.embedded[literal.scope.base];
    if(!target) throw Error('Typed literal resource boundary is absent');
    const path=tokens(literal.pointer.slice(literal.scope.resourcePointer.length));
    const name=path.pop();let container=target.root;
    for(const token of path) container=container[token];
    Object.defineProperty(container,name,{value:literal.value,enumerable:true,writable:true,configurable:true});
  }
  return document;
}
