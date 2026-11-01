import {SourceDocument,SourceError,RawJsonValue,Node,segments,escape} from './document';

const canonical=(doc:SourceDocument,pointer:string)=>{
 let work=0;
 const render=(pointer:string):string=>doc.dataJson(pointer,(node,occurrence)=>{
  if(++work>400000)throw new SourceError('limit.data.edit','The edited data exceeds the bounded node count');
  if(node.kind==='object')return '{'+[...node.children.keys()].sort().map(name=>JSON.stringify(name)+':'+render(occurrence+'/'+escape(name))).join(',')+'}';
  if(node.kind==='array')return node.children.size?undefined:'[]';
  return typeof node.value==='number'?doc.dataJson(occurrence):JSON.stringify(node.value);
 });
 return render(pointer);
};

/** Patch explicitly edited JSON-compatible data through the existing CST.
 * Unchanged values/keys keep comments, quoting, scalar styles and ordering;
 * numeric replacements use input lexemes, never JS number serialization.
 * This has no schema traversal, reference interpretation or resource loader. */
export function setDataSource(doc:SourceDocument,pointer:string,raw:string):string {
 const incoming=new SourceDocument(raw,'form-value.json'),original=doc.nodes.get(pointer);
 if(!original)return doc.set(pointer,new RawJsonValue(raw));
 const leaves:{start:number;end:number;text:string}[]=[],structure:{kind:string;pointer:string;value?:RawJsonValue}[]=[];
 let nodes=0;
 const visit=(before:Node,after:Node)=>{
  if(++nodes>400000)throw new SourceError('limit.data.edit','The edited data exceeds the bounded node count');
  if(before.shared) {
   if(doc.dataJson(before.pointer)===incoming.dataJson(after.pointer))return;
   throw new SourceError('edit.shared','A changed data value uses YAML anchors/aliases; choose its explicit source definition');
  }
  if(before.kind==='object'&&after.kind==='object'||before.kind==='array'&&after.kind==='array') {
   for(const [name,child]of before.children) {
    const next=after.children.get(name);
    if(next)visit(child,next);
   }
   // Remove array tails in reverse order; earlier locations remain stable.
   for(const [name,child]of [...before.children].reverse())if(!after.children.has(name))
    structure.push({kind:'remove',pointer:child.pointer});
   for(const [name,child]of after.children)if(!before.children.has(name))
    structure.push({kind:'set',pointer:before.pointer+'/'+escape(name),value:new RawJsonValue(incoming.dataJson(child.pointer))});
   return;
  }
  const next=incoming.dataJson(after.pointer);
  if(doc.dataJson(before.pointer)===next)return;
  doc.assertUnshared(before.pointer);
  // A container-kind change is explicit replacement of that selected value.
  const value=after.kind==='object'||after.kind==='array'||typeof after.value==='number'
   ?new RawJsonValue(next):after.value;
  leaves.push({start:before.range[0],end:before.range[1],text:doc.emit(value,before,before.flow)});
 };
 visit(original,incoming.root);
 if(structure.length>256||structure.length*doc.text.length>128*1024*1024)
  throw new SourceError('limit.data.edit','The structural data edit exceeds its bounded source-edit budget; no source was changed');
 leaves.sort((a,b)=>a.start-b.start);
 const pieces:string[]=[];let cursor=0;
 for(const edit of leaves){pieces.push(doc.text.slice(cursor,edit.start),edit.text);cursor=edit.end;}
 pieces.push(doc.text.slice(cursor));let text=pieces.join('');
 // Children are repaired before a containing array can shift their indices.
 structure.sort((a,b)=>segments(b.pointer).length-segments(a.pointer).length);
 for(const action of structure) {
  const current=new SourceDocument(text,doc.id,true);
  text=action.kind==='remove'?current.remove(action.pointer):current.set(action.pointer,action.value);
 }
 // Tags, scalar styles and structural edits must round-trip the exact supplied
 // JSON data. Comparing canonical CST projections also retains numeric lexemes.
 const result=new SourceDocument(text,doc.id,true);
 result.assertSafe(pointer);
 if(canonical(result,pointer)!==canonical(incoming,''))
  throw new SourceError('edit.data.value','The source representation would change the requested JSON value; review explicit YAML tags in Source',original.range);
 return text;
}
