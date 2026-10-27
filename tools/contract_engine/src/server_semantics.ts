import {isIriReference} from '@hyperjump/uri';
import {escape,SourceError} from './document';
import {documentUriBase,resolveUri,type GraphIssue,type GraphTarget,type ReferenceGraph} from './reference_graph';

export const serverContextRevision='1';

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

/** API URLs use the canonical graph's URL representation, including Unicode
 * and URL path literals. URI-only metadata grammar must not reject those URL
 * spellings. Validation never fetches or changes the authored spelling. */
function fixedServerUrl(value:string,base:string):'valid'|'invalid'|'unsupported' {
 try{resolveUri(value,base);return 'valid';}
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
export function serverRelationships(graph:ReferenceGraph):GraphIssue[] {
 const issues=new Map<string,GraphIssue>();
 const key=(at:GraphTarget)=>JSON.stringify([at.resource,at.pointer]);
 const add=(at:GraphTarget,pointer:string,code:string,message:string,incomplete=false)=>{
  issues.set(JSON.stringify([at.resource,pointer,code]),{...at,pointer,code,message,...(incomplete?{incomplete:true,severity:'warning' as const}:{})});
 };
 for(const at of graph.scopes.values()){
  if(at.kind!=='server'&&at.kind!=='server-variable'&&at.kind!=='server-array')continue;
  const doc=graph.docs.get(at.resource)!,node=doc.dataNode(at.pointer),family=at.family;
  if(!node||!doc.dataSyntaxSafe(at.pointer))continue;
  if(at.kind==='server-variable'&&node.kind==='object') {
   const value=node.value;
   if(typeof value.default==='string'&&Array.isArray(value.enum)&&value.enum.every((v:any)=>typeof v==='string')&&!value.enum.includes(value.default))
    if(family==='3.0')issues.set(key(at)+':server.variable.default-enum',{...at,pointer:at.pointer+'/default',code:'server.variable.default-enum',message:'A Server variable default should be one of its authored enum values',severity:'warning'});
    else add(at,at.pointer+'/default','server.variable.default-enum','A Server variable default must be one of its authored enum values');
  }
  if(at.kind==='server'&&typeof node.value?.url==='string') {
   let template:ReturnType<typeof serverTemplateParts>;
   try{template=serverTemplateParts(node.value.url);}catch(error){
    if(!(error instanceof SourceError))throw error;
    add(at,at.pointer+'/url',error.code,'Server URL template inspection exceeds its bounded work budget',true);continue;
   }
   if(family==='3.2'&&!template.valid)add(at,at.pointer+'/url','server.url.template','The Server URL does not follow the selected version’s template syntax');
   if(['3.1','3.2'].includes(family)&&template.queryOrFragment)add(at,at.pointer+'/url','server.url.query-fragment',`An OpenAPI ${family} Server URL must not contain a query or fragment`);
   if(!/[{}]/u.test(node.value.url)&&(family!=='3.2'||template.valid)){
    const validity=fixedServerUrl(node.value.url,documentUriBase(graph,at));
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
