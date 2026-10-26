// Hyperjump 1.18.0's exported experimental keyword/instance APIs are deliberately
// pinned and tested. Exact numeric values come from canonical CST nodes, not a
// replacement parser or mutated JS values. One adapter belongs to one worker
// operation; no previous snapshot's numeric provenance survives disposal.
import * as Browser from '@hyperjump/browser';
import {Reference} from '@hyperjump/browser/jref';
import * as Instance from '@hyperjump/json-schema/instance/experimental';
import {addKeyword,getKeyword,getKeywordName,canonicalUri} from '@hyperjump/json-schema/experimental';
import {SourceDocument, SourceError} from './document';
import {schemaMetaView} from './schema_boundaries';
import {isReferenceObject} from './contexts';
import {swaggerDiscriminator} from './swagger_discriminator';
import type {BinaryLocations} from './runtime_binary';

export function decimal(raw: string) {
 const match=/^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(raw);
 if(!match)throw new SourceError('schema.numeric.provenance','Expected an exact JSON numeric lexeme');
 if(raw.length>8192||match[2].length+(match[3]?.length??0)>4096||(match[4]?.length??0)>64)throw new SourceError('limit.schema.numeric','Exact numeric work limit');
 let digits=(match[2]+(match[3]??'')).replace(/^0+/,''),exponent=BigInt(match[4]??0)-BigInt(match[3]?.length??0);
 if(!digits)return {coefficient:0n,exponent:0n};
 const tail=digits.length-digits.replace(/0+$/,'').length;
 digits=digits.slice(0,digits.length-tail);exponent+=BigInt(tail);
 return {coefficient:BigInt((match[1]??'')+digits),exponent};
}
type Decimal = ReturnType<typeof decimal>;
/** Whether the actual IEEE-754 value equals the authored decimal exactly.
 * Safe-integer checks reject exact fractions/powers unnecessarily, while a
 * shortest decimal round trip can hide binary rounding (notably 0.1). Use the
 * binary significand/exponent as an independent witness for the existing exact
 * decimal comparator; never replace a canonical value or its source lexeme.
 */
export function nativeNumberIsExact(raw:string,value:number):boolean {
 if(!Number.isFinite(value))return false;
 if(Number.isSafeInteger(value))return compare(decimal(raw),decimal(String(value)))===0;
 const view=new DataView(new ArrayBuffer(8));view.setFloat64(0,value,false);
 const bits=view.getBigUint64(0,false),biased=Number((bits>>52n)&0x7ffn),fraction=bits&((1n<<52n)-1n);
 let coefficient=biased===0?fraction:(1n<<52n)|fraction;
 const power=biased===0?-1074:biased-1023-52;
 let exponent=0n;
 if(power>=0)coefficient<<=BigInt(power);
 else {coefficient*=5n**BigInt(-power);exponent=BigInt(power);}
 if(bits>>63n)coefficient=-coefficient;
 return compare(decimal(raw),{coefficient,exponent})===0;
}
let standardType:any;
let standardOas30Type:any;
let standardRequired:any;
let standardReadOnly:any;
export function compare(a:Decimal,b:Decimal) {
 const sign=n=>n.coefficient<0n?-1:n.coefficient>0n?1:0;
 const as=sign(a),bs=sign(b);if(as!==bs)return as<bs?-1:1;if(!as)return 0;
 const ac=(a.coefficient<0n?-a.coefficient:a.coefficient).toString(),bc=(b.coefficient<0n?-b.coefficient:b.coefficient).toString();
 const am=BigInt(ac.length)+a.exponent,bm=BigInt(bc.length)+b.exponent;
 if(am!==bm)return (am<bm?-1:1)*as;
 const width=Math.max(ac.length,bc.length),left=ac.padEnd(width,'0'),right=bc.padEnd(width,'0');
 return left===right?0:(left<right?-1:1)*as;
}
export function multiple(a:Decimal,b:Decimal) {
 if(b.coefficient<=0n)throw new SourceError('schema.multipleOf','multipleOf requires a strictly positive schema value');
 if(!a.coefficient)return true;
 const power=a.exponent-b.exponent;
 if(power<0n)return false; // normalized coefficient has no factor of ten
 let base=10n%b.coefficient,result=1n%b.coefficient,e=power;
 while(e){if(e&1n)result=result*base%b.coefficient;base=base*base%b.coefficient;e>>=1n;}
 return ((a.coefficient<0n?-a.coefficient:a.coefficient)%b.coefficient)*result%b.coefficient===0n;
}
export function createExactNumericAdapter(trustedSchemaIdentities:ReadonlySet<string>=new Set()) {
let disposed=false;
const exactInstanceNumbers=new WeakMap<object,any>(), sourceLocations=new Map<string,{doc:SourceDocument,node:any}>();
const binaryInstances=new WeakMap<object,Buffer>();
let referenceGraph:any;
let direction: 'request' | 'response' | undefined;
const current=()=>{if(disposed)throw new SourceError('schema.owner','The schema evaluation owner was disposed');};
const fallback=value=>{
 if(!Number.isFinite(value))throw new SourceError('schema.numeric.provenance','A non-finite JavaScript projection has no exact source provenance');
 return decimal(String(value));
};
const number=node=>exactInstanceNumbers.get(node)??fallback(Instance.value(node));
const encodedNumber=n=>'n:'+n.coefficient+'e'+n.exponent;

function addExactSource(doc: SourceDocument,graph: any) {
 current();
 referenceGraph=graph;
 for(const node of doc.nodes.values()) {
  if(typeof node.value!=='number'&&!/\/(?:const|enum)$/.test(node.pointer))continue;
  const scope=graph.scope(doc.id,node.pointer);
  const uri=scope.base+'#'+encodeURI(node.pointer.slice(scope.resourcePointer.length));
  const previous=sourceLocations.get(uri);
  if(previous&&(previous.doc.id!==doc.id||previous.node.pointer!==node.pointer))throw new SourceError('schema.numeric.provenance','Ambiguous exact-number provenance');
  sourceLocations.set(uri,{doc,node});
 }
}
function exactInstance(doc: SourceDocument,pointer='',opaque?:ReadonlySet<string>,restrictedMeta=false,binary?:BinaryLocations) {
 current();
 // A compound document's resources have separate dialect/meta boundaries.
 // Only meta-evaluation uses this view; source and supplied instances remain
 // unchanged, and surviving numbers retain their original full CST pointers.
 const value=doc.dataNode(pointer)!.value;
 const referenceView=(value:any,at:string):any=>{
  if(!value||typeof value!=='object')return value;
  const scope=referenceGraph?.scopes.get(doc.id+'#'+at);
  if(scope?.kind==='schema'&&isReferenceObject(value,'schema',scope.family))return {$ref:value.$ref};
  return Array.isArray(value)?value.map((child,index)=>referenceView(child,at+'/'+index)):
   Object.fromEntries(Object.entries(value).map(([name,child])=>[name,referenceView(child,at+'/'+name.replaceAll('~','~0').replaceAll('/','~1'))]));
 };
 const meta=schemaMetaView(value,pointer,opaque);
 const root=Instance.fromJs(restrictedMeta?referenceView(meta,pointer):meta,doc.id);
 let binaryCount=0;
 for(const node of Instance.allNodes(root)) {
  if(Instance.typeOf(node)==='number')exactInstanceNumbers.set(node,decimal(doc.dataJson(pointer+node.pointer)));
  const bytes=binary?.get(node.pointer);
  if(bytes!==undefined&&Instance.typeOf(node)==='null'){binaryInstances.set(node,bytes);binaryCount++;}
 }
 if(binaryCount!==(binary?.size??0))throw new SourceError('runtime.binary.provenance','Binary leaf ownership does not match its captured instance');
 return root;
}
function fingerprint(value:any,source?:{doc:SourceDocument,node:any},instance?:any) {
 current();
 let cost=0,nodes=0;
 const render=(value,node,actual,depth)=>{
  if(++nodes>400000||depth>128)throw new SourceError('limit.schema.equality','Exact equality work limit');
  if(value instanceof Reference)value=value.toJSON();
  if(node&&source)node=source.doc.dataNode(node.pointer);
  const type=actual?Instance.typeOf(actual):value===null?'null':Array.isArray(value)?'array':typeof value;
  let result;
  if(actual&&binaryInstances.has(actual))result='b:'+binaryInstances.get(actual)!.toString('base64');
  else if(type==='number')result=encodedNumber(actual?number(actual):node?decimal(source.doc.dataJson(node.pointer)):fallback(value));
  else if(type==='object')result='{'+Object.keys(value).sort().map(key=>JSON.stringify(key)+':'+render(value[key],node?.children.get(key),actual?Instance.step(key,actual):undefined,depth+1)).join(',')+'}';
  else if(type==='array')result='['+value.map((child,i)=>render(child,node?.children.get(String(i)),actual?Instance.step(String(i),actual):undefined,depth+1)).join(',')+']';
  else result=JSON.stringify(value);
  cost+=result.length;if(cost>32*1024*1024)throw new SourceError('limit.schema.equality','Exact equality byte limit');
  return result;
 };
 return render(value,source?.node,instance,0);
}
const sourceAt=(uri:string)=>{
 const known=sourceLocations.get(uri);if(known)return known;
 const address=new URL(uri),fragment=decodeURIComponent(address.hash.slice(1));address.hash='';
 const targets=referenceGraph?.identities.get(address.href);
 if(targets?.length!==1||fragment&&!fragment.startsWith('/'))return;
 const doc=referenceGraph.docs.get(targets[0].resource) as SourceDocument;
 const node=doc.dataNode(targets[0].pointer+fragment);
 return node?{doc,node}:undefined;
};
const schemaNumber=schema=>{
 const uri=canonicalUri(schema),source=sourceAt(uri);
 if(source)return decimal(source.doc.dataJson(source.node.pointer));
 const identity=new URL(uri);identity.hash='';
 if(!trustedSchemaIdentities.has(identity.href))throw new SourceError('schema.numeric.provenance','An authored numeric schema value has no exact source provenance');
 return fallback(Browser.value(schema));
};
const schemaFingerprint=schema=>{
 const source=sourceAt(canonicalUri(schema));
 // A physical value may also be an explicitly referenced schema elsewhere.
 // Const/enum still compare the original literal value, never that second
 // occurrence's preprocessed schema ($id and anchor keywords included).
 return fingerprint(source?source.node.value:Browser.value(schema),source);
};
const instanceFingerprint=instance=>fingerprint(Instance.value(instance),undefined,instance);

function installExactNumericKeywords() {
 current();
 const id=name=>'https://json-schema.org/keyword/'+name;
 addKeyword(swaggerDiscriminator(schema=>{
  const source=sourceAt(canonicalUri(schema));
  return source&&referenceGraph?{graph:referenceGraph,resource:source.doc.id,pointer:source.node.pointer}:undefined;
 }));
 const readOnly=standardReadOnly??(standardReadOnly=getKeyword(id('readOnly')));
 addKeyword({...readOnly,compile:(schema,_ast,parent)=>{
  const source=sourceAt(canonicalUri(parent)),scope=source&&referenceGraph?.scope(source.doc.id,source.node.pointer);
  return {value:Browser.value(schema),requestAssertion:scope?.family==='2.0'&&/\/properties\/[^/]+$/.test(scope.pointer)};
 },interpret:(annotation,instance,context)=>!(annotation.requestAssertion&&annotation.value===true&&direction==='request')} as any);
 for(const name of ['minimum','maximum','exclusiveMinimum','exclusiveMaximum','multipleOf']) {
  const original=getKeyword(id(name)) as any;
  addKeyword({...original,compile:schemaNumber,interpret:(bound:Decimal,instance)=>{
   if(Instance.typeOf(instance)!=='number')return true;
   const value=number(instance),order=compare(value,bound);
   return name==='minimum'?order>=0:name==='maximum'?order<=0:name==='exclusiveMinimum'?order>0:name==='exclusiveMaximum'?order<0:multiple(value,bound);
  }});
 }
 // OAS 3.0's boolean exclusive bounds are Draft 4 assertions. Retain the
 // sibling flag while comparing the authored decimal bound exactly.
 for(const name of ['minimum','maximum']) {
  const keyword='https://json-schema.org/keyword/draft-04/'+name;
  const exclusive='https://json-schema.org/keyword/draft-04/'+(name==='minimum'?'exclusiveMinimum':'exclusiveMaximum');
  addKeyword({...getKeyword(keyword),compile:async(schema,_ast,parent)=>[
   schemaNumber(schema),Browser.value(await Browser.step(getKeywordName(schema.document.dialectId,exclusive),parent))===true,
  ],interpret:([bound,strict]:[Decimal,boolean],instance)=>{
   if(Instance.typeOf(instance)!=='number')return true;
   const order=compare(number(instance),bound);
   return name==='minimum'?(strict?order>0:order>=0):(strict?order<0:order<=0);
  }} as any);
 }
 // Do not wrap the previous job's handler: that would retain an unbounded
 // delegation chain (and its old owner) across worker reuse.
 const type=standardType??(standardType=getKeyword(id('type')) as any);
 addKeyword({...type,interpret:(types:any,instance,context)=>{
  if(binaryInstances.has(instance))return false;
  if(Instance.typeOf(instance)!=='number')return type.interpret(types,instance,context);
  return (typeof types==='string'?[types]:types).some(t=>t==='number'||t==='integer'&&(number(instance).coefficient===0n||number(instance).exponent>=0n));
 }});
 const oas30=standardOas30Type??(standardOas30Type=getKeyword('https://spec.openapis.org/oas/3.0/keyword/type'));
 addKeyword({...oas30,interpret:(types:any,instance,context)=>{
  if(Instance.typeOf(instance)!=='number')return oas30.interpret(types,instance,context);
  return (typeof types==='string'?[types]:types).some(t=>t==='number'||t==='integer'&&(number(instance).coefficient===0n||number(instance).exponent>=0n));
 }});
 const required=standardRequired??(standardRequired=getKeyword(id('required')));
 addKeyword({...required,compile:(schema,_ast,parent)=>{
  const source=sourceAt(canonicalUri(parent)),names=Browser.value(schema);
  if(!Array.isArray(names))throw new SourceError('schema.required','required must be an array of property names');
  const owner=source&&referenceGraph?.scope(source.doc.id,source.node.pointer);
  if(owner?.family!=='3.0')return {names};
  const flags=(name:string)=>{
   let target=referenceGraph.scopes.get(source.doc.id+'#'+source.node.pointer+'/properties/'+name.replaceAll('~','~0').replaceAll('/','~1'));
   const seen=new Set<string>();
   while(target){
    const identity=target.resource+'#'+target.pointer;
    if(seen.has(identity)||seen.size>=128)return {};
    seen.add(identity);
    const value=referenceGraph.docs.get(target.resource)?.dataNode(target.pointer)?.value;
    if(typeof value?.$ref!=='string')return {readOnly:value?.readOnly===true,writeOnly:value?.writeOnly===true};
    const resolved=referenceGraph.resolveReference(value.$ref,target);
    if(resolved.resolution!=='resolved')return {};
    target=referenceGraph.scopes.get(resolved.targetResource+'#'+resolved.targetPointer);
   }
   return {};
  };
  return {names,flags:Object.fromEntries(names.map((name:string)=>[name,flags(name)]))};
 },interpret:({names,flags},instance,context)=>required.interpret(
  flags&&direction?names.filter((name:string)=>!(direction==='request'?flags[name]?.readOnly:flags[name]?.writeOnly)):names,instance,context,
 )} as any);
 addKeyword({...getKeyword(id('const')),compile:schemaFingerprint,interpret:(expected,instance)=>expected===instanceFingerprint(instance)} as any);
 addKeyword({...getKeyword(id('enum')),compile:schema=>{
  const source=sourceAt(canonicalUri(schema));
  // An alias owns its source range but its sequence children belong to the
  // physical anchor. Fingerprint those children with their exact CST lexemes.
  const node=source?.doc.dataNode(source.node.pointer);
  // Enum members are literal data. Traversing them with Browser.step/values
  // can resolve a JRef wrapper; reading their value must never do so.
  return ((node?node.value:Browser.value(schema)) as any[]).map((value,i)=>fingerprint(value,source&&node?{doc:source.doc,node:node.children.get(String(i))}:undefined));
 },interpret:(options,instance)=>options.includes(instanceFingerprint(instance))} as any);
 addKeyword({...getKeyword(id('uniqueItems')),interpret:(enabled,instance)=>{
  if(!enabled||Instance.typeOf(instance)!=='array')return true;
  const seen=new Set();let cost=0;
  for(const item of Instance.iter(instance)){
   const key=instanceFingerprint(item);cost+=key.length;if(cost>32*1024*1024)throw new SourceError('limit.schema.equality','Exact uniqueItems byte limit');
   if(seen.has(key))return false;seen.add(key);
  }return true;
 }} as any);
}
return {addExactSource,exactInstance,install:installExactNumericKeywords,setDirection:(value:typeof direction)=>{current();direction=value;},
 fingerprintSource:(doc:SourceDocument,pointer:string)=>{const node=doc.dataNode(pointer);if(!node)throw new SourceError('schema.numeric.provenance','Exact equality source is absent');return fingerprint(node.value,{doc,node});},
 dispose:()=>{disposed=true;sourceLocations.clear();referenceGraph=undefined;}};
}
