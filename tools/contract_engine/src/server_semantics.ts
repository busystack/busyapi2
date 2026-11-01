import {isIriReference} from '@hyperjump/uri';
import {escape,SourceError,type Range} from './document';
import {structuralEvaluator,structuralSchema} from './structural_schema';
import {documentUriBase,resolveUri,type GraphIssue,type GraphScope,type GraphTarget,type ReferenceGraph} from './reference_graph';

export const serverContextRevision='4';
export type ServerContextProblem={resource:string;pointer:string;code:string;message:string;range:Range;unsupported:boolean};
type ServerVariableValue={default:string;enum?:readonly string[];description?:string;defaultOutsideEnumAllowed?:true};
const serverVariableEnumIsRequired=(family:string)=>family!=='3.0';
const serverUrlAllowsQueryFragment=(family:string):boolean=>family==='3.0';
// RFC 9110 §7.1 excludes fragments from HTTP targets after URI substitution.
// The selected declaration must separately satisfy its family's URL rules.
export const serverHttpFragmentPolicy='omit';
export function serverContextError(problem:ServerContextProblem):SourceError {
 return new SourceError(problem.code,problem.message,problem.range,problem.unsupported?'unsupported':'specification',
  {resource:problem.resource,pointer:problem.pointer,range:problem.range});
}

// OAS 3.2 §4.6 ABNF. These are template literals, not an RFC 6570 expression
// evaluator. Names are not restricted to ASCII or decoded from percent escapes.
const literal=(c:number)=>c===0x21||c>=0x23&&c<=0x24||c>=0x26&&c<=0x3b||c===0x3d||c>=0x3f&&c<=0x5b||c===0x5d||c===0x5f||c>=0x61&&c<=0x7a||c===0x7e||
 c>=0xa0&&c<=0xd7ff||c>=0xe000&&c<=0xfdcf||c>=0xfdf0&&c<=0xffef||
 c>=0x10000&&c<=0xdfffd&&(c&0xffff)<=0xfffd||c>=0xe1000&&c<=0x10fffd&&(c&0xffff)<=0xfffd;

/** Source-only classification, never URL substitution, retrieval or execution. */
export function serverTemplateParts(url:string) {
 if(url.length>65536)throw new SourceError('limit.authoring.template','Server URL template inspection exceeds 65536 UTF-16 code units');
 const names:string[]=[];let valid=url.length>0,queryOrFragment=false,delimitersValid=true,literalsValid=true;
 for(let i=0;i<url.length;) {
  const c=url.codePointAt(i)!;
  if(c===0x7b) {
   const end=url.indexOf('}',i+1);
   if(end<0){valid=false;delimitersValid=false;break;}
   const name=url.slice(i+1,end);
   if(name.includes('{'))delimitersValid=false;
   if(!name||name.includes('{'))valid=false;
   else names.push(name);
   i=end+1;continue;
  }
  if(c===0x25) {
   if(/^[A-Fa-f0-9]{2}$/.test(url.slice(i+1,i+3))){i+=3;continue;}
   // OAS 3.0/3.1 substitute before URL interpretation. A variable may
   // complete a percent triplet (%{hex} or %A{digit}); fixed nonhex
   // characters and an exhausted suffix cannot (RFC 3986 §2.1).
   for(let next=i+1;next<=i+2;next++){
    if(url[next]==='{')break;
    if(!/^[A-Fa-f0-9]$/u.test(url[next]??'')){literalsValid=false;break;}
   }
   valid=false;i++;continue;
  }
  if(c<=0x20||c===0x7f||c===0x5c)literalsValid=false;
  if(c===0x3f||c===0x23)queryOrFragment=true;
  if(c===0x7d)delimitersValid=false;
  if(!literal(c))valid=false;
  i+=c>0xffff?2:1;
 }
 return {names,valid,queryOrFragment,delimitersValid,literalsValid};
}

/** OAS 3.2 §4.6 permits Unicode URL literals, including non-ASCII spaces.
 * Resolve their UTF-8 URL spelling without relaxing resource URI checks or
 * rewriting source. ASCII whitespace remains invalid. */
export function resolveServerUrl(value:string,base:string):URL {
 const reference=value.replace(/\s/gu,character=>character.charCodeAt(0)>0x7f?encodeURIComponent(character):character);
 return resolveUri(reference,base);
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

/** API URLs use the canonical graph's URL representation, including Unicode
 * and URL path literals. URI-only metadata grammar must not reject those URL
 * spellings. Validation never fetches or changes the authored spelling. */
export function serverUrlValidity(value:string,base:string):'valid'|'invalid'|'unsupported' {
 try{resolveServerUrl(value,base);return 'valid';}
 catch(error){
  if(!(error instanceof Error))throw error;
  if(error.message==='Invalid URI reference'||/^Invalid (IRI-reference|absolute-IRI): /u.test(error.message))return 'invalid';
  if(error instanceof TypeError&&'code' in error&&error.code==='ERR_INVALID_URL'){
   // The pinned URI grammar can recognize future IP host syntax which the
   // canonical URL representation cannot use. Keep that limitation separate.
   try{isIriReference(value);}
   catch(syntaxError){
    if(!(syntaxError instanceof Error)||!syntaxError.message.startsWith('Unsupported IP version in host: '))throw syntaxError;
    return 'unsupported';
   }
   return 'invalid';
  }
  throw error;
 }
}

/** Server policies belong to their declared family, independently of schema
 * dialect. OAS 3.0 §4.7.5 permits query/fragment; 3.1 §4.8.5 prohibits them.
 * 3.2 §§4.5–4.6 additionally defines nonempty ABNF and unique expressions. */
export function serverRelationships(graph:ReferenceGraph,scopes:Iterable<GraphScope>=graph.scopes.values()):GraphIssue[] {
 const issues=new Map<string,GraphIssue>();
 const key=(at:GraphTarget)=>JSON.stringify([at.resource,at.pointer]);
 const add=(at:GraphTarget,pointer:string,code:string,message:string,incomplete=false)=>{
  issues.set(JSON.stringify([at.resource,pointer,code]),{...at,pointer,code,message,...(incomplete?{incomplete:true,severity:'warning' as const}:{})});
 };
 for(const at of scopes){
  if(at.kind!=='server'&&at.kind!=='server-variable'&&at.kind!=='server-array')continue;
  const doc=graph.docs.get(at.resource)!,node=doc.dataNode(at.pointer),family=at.family;
  if(!node||!doc.dataSyntaxSafe(at.pointer))continue;
  if(at.kind==='server-variable'&&node.kind==='object') {
   const value=node.value;
   if(typeof value.default==='string'&&Array.isArray(value.enum)&&value.enum.every((v:any)=>typeof v==='string')&&!value.enum.includes(value.default))
    if(!serverVariableEnumIsRequired(family))issues.set(key(at)+':server.variable.default-enum',{...at,pointer:at.pointer+'/default',code:'server.variable.default-enum',message:'A Server variable default should be one of its authored enum values',severity:'warning'});
    else add(at,at.pointer+'/default','server.variable.default-enum','A Server variable default must be one of its authored enum values');
  }
  if(at.kind==='server'&&typeof node.value?.url==='string') {
   let template:ReturnType<typeof serverTemplateParts>;
   try{template=serverTemplateParts(node.value.url);}catch(error){
    if(!(error instanceof SourceError))throw error;
    add(at,at.pointer+'/url',error.code,'Server URL template inspection exceeds its bounded work budget',true);continue;
   }
   if(family==='3.2'&&!template.valid)add(at,at.pointer+'/url','server.url.template','The Server URL does not follow the selected version’s template syntax');
   if(family!=='3.2'&&!template.delimitersValid)add(at,at.pointer+'/url','server.url.template-delimiters','Server URL variables require matched, non-nested braces');
   if(family!=='3.2'&&/[{}]/u.test(node.value.url)&&!template.literalsValid)add(at,at.pointer+'/url','server.url.template-literal','The Server URL contains invalid literal characters or a malformed percent escape');
   if(!serverUrlAllowsQueryFragment(family)&&template.queryOrFragment)add(at,at.pointer+'/url','server.url.query-fragment',`An OpenAPI ${family} Server URL must not contain a query or fragment`);
   if(!/[{}]/u.test(node.value.url)&&(family!=='3.2'||template.valid)){
    const validity=serverUrlValidity(node.value.url,documentUriBase(graph,at));
    if(validity==='invalid')add(at,at.pointer+'/url','server.url.uri','The fixed Server URL must be a valid URL reference');
    if(validity==='unsupported')add(at,at.pointer+'/url','server.url.unsupported','The URL validator cannot evaluate this Server host notation',true);
   }
   if(family==='3.2'&&new Set(template.names).size!==template.names.length)add(at,at.pointer+'/url','server.variable.repeated','An OpenAPI 3.2 Server variable must not appear more than once in its URL template');
  }
  if(at.kind==='server-array'&&family==='3.2'&&node.kind==='array') {
   const seen=new Map<string,string>();
   for(const [i,server]of node.children)if(typeof server.value?.name==='string') {
    const pointer=at.pointer+'/'+escape(i)+'/name',name=server.value.name,previous=seen.get(name);
    if(previous!==undefined){add(at,previous,'server.name.duplicate','Server names in one declaration list must be unique');add(at,pointer,'server.name.duplicate','Server names in one declaration list must be unique');}
    else seen.set(name,pointer);
   }
  }
 }
 return [...issues.values()];
}

/** Validate only the selected declaration. An unrelated invalid operation does
 * not change this operation's effective server owner. The trusted structural
 * validator and normative relationship rules remain the semantic authorities. */
export function serverContextProblem(graph:ReferenceGraph,resource:string,pointer:string):ServerContextProblem|undefined {
 const doc=graph.docs.get(resource)!,node=doc.dataNode(pointer)!,scope=graph.scope(resource,pointer);
 const problem=(at:string,code:string,message:string,unsupported=false):ServerContextProblem=>{
  while(!doc.dataNode(at))at=at.slice(0,at.lastIndexOf('/'));
  return {resource,pointer:at,code,message,range:doc.dataNode(at)!.range,unsupported};
 };
 if(!doc.dataSyntaxSafe(pointer))return problem(pointer,'server.source','The selected Server declaration is syntactically ambiguous');
 if(node.kind!=='array')return problem(pointer,'server.array.type','The selected Server declaration must be an array');
 const schema=structuralSchema(scope.family),validate=structuralEvaluator.getSchema(schema.$id+'#/$defs/server');
 if(!validate)throw new Error('The pinned Server validator is unavailable');
 const scopes:GraphScope[]=[];
 const retain=(at:string,kind:string)=>{
  const scope=graph.scopeAs(resource,at,kind);
  if(scope)scopes.push(scope);
  return scope!==undefined;
 };
 if(!retain(pointer,'server-array'))return problem(pointer,'server.context.unsupported','The captured Server array has no canonical context',true);
 for(const [index,server]of node.children){
  const at=pointer+'/'+escape(index);
  if(!validate(server.value))return problem(at+(validate.errors?.[0]?.instancePath??''),'server.structure','The captured Server declaration is invalid for OpenAPI '+scope.family);
  if(!retain(at,'server'))return problem(at,'server.context.unsupported','The captured Server has no canonical context',true);
  const variables=doc.dataNode(at+'/variables');
  if(variables)for(const name of variables.children.keys())
   if(!retain(at+'/variables/'+escape(name),'server-variable'))return problem(at+'/variables/'+escape(name),'server.context.unsupported','The captured Server variable has no canonical context',true);
 }
 const issue=serverRelationships(graph,scopes).find(issue=>issue.incomplete||issue.severity!=='warning');
 if(issue)return problem(issue.pointer,issue.code,issue.message,issue.incomplete===true);
}

/** A finite enum does not exclude a 3.0 declared default (§4.7.6). URI
 * relocation proofs must cover both; a default alone never bounds an absent
 * enum. Strict-family defaults already belong to their validated enum. */
export function finiteServerVariableValues(variable:unknown):readonly string[]|undefined {
 if(variable===null||typeof variable!=='object'||Array.isArray(variable)||!('enum' in variable)||!('default' in variable)||typeof variable.default!=='string')return;
 const values:unknown=variable.enum;
 if(!Array.isArray(values)||!values.every(value=>typeof value==='string'))return;
 return [...new Set([...values.filter((value):value is string=>typeof value==='string'),variable.default])];
}

/** A 3.0 declared default SHALL be used without an alternate substitution,
 * even when it violates the enum recommendation (§4.7.6). Keep that exception
 * in the captured semantics; consumers do not reinterpret version strings. */
export function serverVariableValues(graph:ReferenceGraph,resource:string,pointer:string):Record<string,ServerVariableValue> {
 const doc=graph.docs.get(resource)!,variables=doc.dataNode(pointer+'/variables');
 if(!variables)return {};
 const required=serverVariableEnumIsRequired(graph.scope(resource,pointer).family);
 return Object.fromEntries([...variables.children.keys()].map(name=>{
  const value=doc.dataNode(pointer+'/variables/'+escape(name))!.value;
  if(typeof value?.default!=='string')throw new Error('Expected the captured validated Server variable');
  const options:unknown=value.enum;
  let values:string[]|undefined;
  if(options!==undefined){
   if(!Array.isArray(options)||!options.every(value=>typeof value==='string'))throw new Error('Expected the captured validated Server variable enum');
   values=options.filter((value):value is string=>typeof value==='string');
  }
  const declaration:ServerVariableValue={default:value.default,enum:values,description:typeof value.description==='string'?value.description:undefined,
   ...(!required&&values&&!values.includes(value.default)?{defaultOutsideEnumAllowed:true as const}:{})};
  return [name,declaration];
 }));
}
