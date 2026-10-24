import {escape,SourceError} from './document';
import {GraphReference,GraphTarget,ReferenceGraph} from './reference_graph';

export type AuthoringIssue=GraphTarget&{code:string;message:string;incomplete?:boolean;severity?:string};

/** OAS 3.1/3.2 discriminator composition is a relationship constraint, never
 * an instance assertion. A parent may qualify through a child's allOf even
 * when the parent has no adjacent composition keyword. */
export function discriminatorRelationships(graph:ReferenceGraph):AuthoringIssue[] {
 const key=(at:GraphTarget)=>JSON.stringify([at.resource,at.pointer]);
 const edges=new Map<string,GraphReference[]>();
 for(const ref of graph.references) {
  // Without a dynamic-anchor starting point, $dynamicRef is the same static
  // applicator as $ref. Runtime-selected targets cannot prove this relationship.
  if(ref.kind!=='schema'||ref.connection||ref.resolution!=='resolved'||
   !(ref.keyword==='$ref'||ref.keyword==='$dynamicRef'&&!ref.dynamic))continue;
  const id=key(ref),values=edges.get(id)??[];
  values.push(ref);edges.set(id,values);
 }
 const parents=new Set<string>(),queue:GraphReference[]=[];
 // The schema owner establishes composition. A reference can type an isolated
 // literal-data descendant as a schema without typing its containing object.
 for(const scope of graph.scopes.values()) {
  if(scope.kind!=='schema')continue;
  const pointer=scope.pointer+'/allOf';
  if(graph.scopes.get(scope.resource+'#'+pointer)?.kind!=='schema-array')continue;
  const list=graph.docs.get(scope.resource)!.dataNode(pointer);
  if(list?.kind!=='array')continue;
  for(const index of list.children.keys())
   queue.push(...edges.get(key({resource:scope.resource,pointer:pointer+'/'+index,kind:'schema'}))??[]);
 }
 for(let i=0;i<queue.length;i++) {
  const ref=queue[i],target={resource:ref.targetResource!,pointer:ref.targetPointer!,kind:'schema'},id=key(target);
  if(parents.has(id))continue;
  parents.add(id);
  const next=edges.get(id);if(next)queue.push(...next);
 }
 const issues:AuthoringIssue[]=[];
 for(const scope of graph.scopes.values()) {
  if(scope.kind!=='schema')continue;
  const doc=graph.docs.get(scope.resource)!,value=doc.dataNode(scope.pointer)?.value;
  if(!value?.discriminator||!doc.dataSyntaxSafe(scope.pointer))continue;
  if(['oneOf','anyOf','allOf'].some(name=>Array.isArray(value[name])&&value[name].length>0)||parents.has(key(scope)))continue;
  issues.push({...scope,pointer:scope.pointer+'/discriminator',code:'discriminator.composition',message:'A discriminator requires adjacent composition or a parent schema referenced by a child through allOf'});
 }
 return issues;
}

// OAS 3.2 §4.6 ABNF. These are template literals, not an RFC 6570 expression
// evaluator. Names are not restricted to ASCII or decoded from percent escapes.
const literal=(c:number)=>c===0x21||c>=0x23&&c<=0x24||c>=0x26&&c<=0x3b||c===0x3d||c>=0x3f&&c<=0x5b||c===0x5d||c===0x5f||c>=0x61&&c<=0x7a||c===0x7e||
 c>=0xa0&&c<=0xd7ff||c>=0xe000&&c<=0xfdcf||c>=0xfdf0&&c<=0xffef||
 c>=0x10000&&c<=0xdfffd&&(c&0xffff)<=0xfffd||c>=0xe1000&&c<=0x10fffd&&(c&0xffff)<=0xfffd;

/** Source-only classification, never URL substitution, retrieval or execution. */
export function serverTemplateParts(url:string) {
 if(url.length>65536)throw new SourceError('limit.authoring.template','Server URL template inspection exceeds 65536 UTF-16 code units');
 const names:string[]=[];let valid=url.length>0,queryOrFragment=false;
 for(let i=0;i<url.length;) {
  const c=url.codePointAt(i)!;
  if(c===0x7b) {
   const end=url.indexOf('}',i+1);
   if(end<0){valid=false;break;}
   const name=url.slice(i+1,end);
   if(!name||name.includes('{'))valid=false;
   else names.push(name);
   i=end+1;continue;
  }
  if(c===0x25) {
   if(!/^[A-Fa-f0-9]{2}$/.test(url.slice(i+1,i+3)))valid=false;
   i+=3;continue;
  }
  if(c===0x3f||c===0x23)queryOrFragment=true;
  if(!literal(c))valid=false;
  i+=c>0xffff?2:1;
 }
 return {names,valid,queryOrFragment};
}

/** Advice is deliberately separate from normative validity. Unused variables
 * and missing substitution declarations are not automatically vulnerabilities
 * or implicit source changes. A configured bundled policy can report them. */
export function serverVariableAdvice(server:any):{path:string[];message:string}[] {
 if(!server||typeof server.url!=='string')return [];
 const names=new Set(serverTemplateParts(server.url).names),variables=server.variables;
 const declared=variables&&typeof variables==='object'&&!Array.isArray(variables)?Object.keys(variables):[],known=new Set(declared);
 return [
  ...[...names].filter(name=>!known.has(name)).map(()=>({path:['url'],message:'A Server URL variable has no declared substitution default.'})),
  ...declared.filter(name=>!names.has(name)).map(name=>({path:['variables',name],message:'This Server variable is not used by its URL template.'})),
 ];
}

/** Relationships which informational object schemas cannot express. Every
 * location is already a typed canonical-graph occurrence; example/extension
 * payload keys never enter this traversal. No effective defaults are authored. */
export function authoringRelationships(graph:ReferenceGraph):AuthoringIssue[] {
 const issues=new Map<string,AuthoringIssue>();
 const key=(at:GraphTarget)=>JSON.stringify([at.resource,at.pointer]);
 const namespace=new Map<string,GraphTarget[]>(),parents=new Map<string,{at:GraphTarget;name:string}>();
 // OAS 3.2 4.1.2.3 recommends the entry-description namespace for Tag names,
 // just as the graph uses it for implicit component names. URI bases do not
 // change. Index possible targets once; duplicate names never select a first.
 const tags=graph.docs.get(graph.root)?.dataNode('/tags');
 if(tags?.kind==='array')for(const [i,tag]of tags.children)if(typeof tag.value?.name==='string') {
  const values=namespace.get(tag.value.name)??[];
  values.push({resource:graph.root,pointer:'/tags/'+escape(i),kind:'tag'});namespace.set(tag.value.name,values);
 }
 const add=(at:GraphTarget,pointer:string,code:string,message:string,incomplete=false)=>{
  const value={...at,pointer,code,message,...(incomplete?{incomplete:true,severity:'warning'}:{})};
  issues.set(JSON.stringify([at.resource,pointer,code]),value);
 };
 for(const at of graph.scopes.values()) {
  const doc=graph.docs.get(at.resource)!,node=doc.dataNode(at.pointer);
  const family=at.family;
  if(!node||!doc.dataSyntaxSafe(at.pointer))continue;
  if(at.kind==='server-variable'&&node.kind==='object') {
   const value=node.value;
   if(typeof value.default==='string'&&Array.isArray(value.enum)&&value.enum.every((v:any)=>typeof v==='string')&&!value.enum.includes(value.default))
    add(at,at.pointer+'/default','server.variable.default-enum','A Server variable default must be one of its authored enum values');
  }
  if(at.kind==='server'&&family==='3.2'&&typeof node.value?.url==='string') {
   let template:ReturnType<typeof serverTemplateParts>;
   try{template=serverTemplateParts(node.value.url);}catch(error){
    if(!(error instanceof SourceError))throw error;
    add(at,at.pointer+'/url',error.code,'Server URL template inspection exceeds its bounded work budget',true);continue;
   }
   if(!template.valid)add(at,at.pointer+'/url','server.url.template','The Server URL does not follow the selected version’s template syntax');
   if(template.queryOrFragment)add(at,at.pointer+'/url','server.url.query-fragment','An OpenAPI 3.2 Server URL must not contain a query or fragment');
   if(new Set(template.names).size!==template.names.length)add(at,at.pointer+'/url','server.variable.repeated','An OpenAPI 3.2 Server variable must not appear more than once in its URL template');
  }
  if(at.kind==='server-array'&&family==='3.2'&&node.kind==='array') {
   const seen=new Map<string,string>();
   for(const [i,server]of node.children)if(typeof server.value?.name==='string') {
    const pointer=at.pointer+'/'+escape(i)+'/name',name=server.value.name,previous=seen.get(name);
    if(previous!==undefined){add(at,previous,'server.name.duplicate','Server names in one declaration list must be unique');add(at,pointer,'server.name.duplicate','Server names in one declaration list must be unique');}
    else seen.set(name,pointer);
   }
  }
  if(at.kind!=='tag-array'||node.kind!=='array')continue;
  const names=new Map<string,string[]>();
  for(const [i,tag]of node.children)if(typeof tag.value?.name==='string') {
   const pointer=at.pointer+'/'+escape(i),name=tag.value.name,existing=names.get(name)??[];
   existing.push(pointer);names.set(name,existing);
   if(family==='3.2'&&typeof tag.value.parent==='string') {
    const source={resource:at.resource,pointer,kind:'tag'};
    parents.set(key(source),{at:source,name:tag.value.parent});
   }
  }
  for(const pointers of names.values())if(pointers.length>1)for(const pointer of pointers)
   add(at,pointer+'/name','tag.name.duplicate','Tag names in one declaration list must be unique');
 }
 const edges=new Map<string,string>();
 for(const [source,{at,name}]of parents) {
  const targets=namespace.get(name)??[];
  if(targets.length===1)edges.set(source,key(targets[0]));
  else add(at,at.pointer+'/parent',targets.length?'tag.parent.ambiguous':'tag.parent.missing',targets.length?'The parent tag name has multiple entry declarations':'A parent tag must name an entry-description tag declaration',targets.length>1);
 }
 const finished=new Set<string>();
 for(const start of edges.keys()) {
   if(finished.has(start))continue;
   const route:string[]=[],positions=new Map<string,number>();let pointer:string|undefined=start;
   while(pointer!==undefined&&!finished.has(pointer)&&!positions.has(pointer)) {
    positions.set(pointer,route.length);route.push(pointer);pointer=edges.get(pointer);
   }
   if(pointer!==undefined&&positions.has(pointer))for(const member of route.slice(positions.get(pointer)!)) {
    const {at}=parents.get(member)!;
    add(at,at.pointer+'/parent','tag.parent.cycle','Tag parent relationships must not form a cycle');
   }
   for(const member of route)finished.add(member);
 }
 return [...issues.values(),...discriminatorRelationships(graph)];
}
