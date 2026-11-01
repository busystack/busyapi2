// Candidate adapter only. Hyperjump 1.18.0's exported experimental instance
// and keyword APIs are deliberately pinned. No vendor code or document values
// are changed; exact numeric values come from BusyAPI's canonical CST nodes.
import * as Browser from '@hyperjump/browser';
import {Reference} from '@hyperjump/browser/jref';
import * as Instance from '@hyperjump/json-schema/instance/experimental';
import {addKeyword,getKeyword,canonicalUri} from '@hyperjump/json-schema/experimental';

export function decimal(raw) {
 const match=/^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(raw);
 if(!match)throw Error('Expected an exact JSON numeric lexeme');
 if(raw.length>8192||match[2].length+(match[3]?.length??0)>4096||(match[4]?.length??0)>64)throw Error('Exact numeric work limit');
 let digits=(match[2]+(match[3]??'')).replace(/^0+/,''),exponent=BigInt(match[4]??0)-BigInt(match[3]?.length??0);
 if(!digits)return {coefficient:0n,exponent:0n};
 const tail=digits.length-digits.replace(/0+$/,'').length;
 digits=digits.slice(0,digits.length-tail);exponent+=BigInt(tail);
 return {coefficient:BigInt((match[1]??'')+digits),exponent};
}
export function compare(a,b) {
 const sign=n=>n.coefficient<0n?-1:n.coefficient>0n?1:0;
 const as=sign(a),bs=sign(b);if(as!==bs)return as<bs?-1:1;if(!as)return 0;
 const ac=(a.coefficient<0n?-a.coefficient:a.coefficient).toString(),bc=(b.coefficient<0n?-b.coefficient:b.coefficient).toString();
 const am=BigInt(ac.length)+a.exponent,bm=BigInt(bc.length)+b.exponent;
 if(am!==bm)return (am<bm?-1:1)*as;
 const width=Math.max(ac.length,bc.length),left=ac.padEnd(width,'0'),right=bc.padEnd(width,'0');
 return left===right?0:(left<right?-1:1)*as;
}
export function multiple(a,b) {
 if(b.coefficient<=0n)throw Error('multipleOf requires a strictly positive schema value');
 if(!a.coefficient)return true;
 const power=a.exponent-b.exponent;
 if(power<0n)return false; // normalized coefficient has no factor of ten
 let base=10n%b.coefficient,result=1n%b.coefficient,e=power;
 while(e){if(e&1n)result=result*base%b.coefficient;base=base*base%b.coefficient;e>>=1n;}
 return ((a.coefficient<0n?-a.coefficient:a.coefficient)%b.coefficient)*result%b.coefficient===0n;
}
const exactInstanceNumbers=new WeakMap(), sourceLocations=new Map();
const fallback=value=>{
 if(!Number.isFinite(value))throw Error('A non-finite JavaScript projection has no exact source provenance');
 return decimal(String(value));
};
const number=node=>exactInstanceNumbers.get(node)??fallback(Instance.value(node));
const encodedNumber=n=>'n:'+n.coefficient+'e'+n.exponent;

export function addExactSource(doc,graph) {
 for(const node of doc.nodes.values()) {
  const scope=graph.scope(doc.id,node.pointer);
  const uri=scope.base+'#'+encodeURI(node.pointer.slice(scope.resourcePointer.length));
  const previous=sourceLocations.get(uri);
  if(previous&&(previous.doc.id!==doc.id||previous.node.pointer!==node.pointer))throw Error('Ambiguous exact-number provenance');
  sourceLocations.set(uri,{doc,node});
 }
}
export function exactInstance(doc,pointer='') {
 const root=Instance.fromJs(doc.node(pointer).value,doc.id,pointer);
 for(const node of Instance.allNodes(root)) {
  if(Instance.typeOf(node)==='number')exactInstanceNumbers.set(node,decimal(doc.dataJson(node.pointer)));
 }
 return root;
}
function fingerprint(value,source,instance) {
 let cost=0,nodes=0;
 const render=(value,node,actual,depth)=>{
  if(++nodes>400000||depth>128)throw Error('Exact equality work limit');
  if(value instanceof Reference)value=value.toJSON();
  const type=actual?Instance.typeOf(actual):value===null?'null':Array.isArray(value)?'array':typeof value;
  let result;
  if(type==='number')result=encodedNumber(actual?number(actual):node?decimal(source.doc.dataJson(node.pointer)):fallback(value));
  else if(type==='object')result='{'+Object.keys(value).sort().map(key=>JSON.stringify(key)+':'+render(value[key],node?.children.get(key),actual?Instance.step(key,actual):undefined,depth+1)).join(',')+'}';
  else if(type==='array')result='['+value.map((child,i)=>render(child,node?.children.get(String(i)),actual?Instance.step(String(i),actual):undefined,depth+1)).join(',')+']';
  else result=JSON.stringify(value);
  cost+=result.length;if(cost>32*1024*1024)throw Error('Exact equality byte limit');
  return result;
 };
 return render(value,source?.node,instance,0);
}
const schemaNumber=schema=>{
 const source=sourceLocations.get(canonicalUri(schema));
 return source?decimal(source.doc.dataJson(source.node.pointer)):fallback(Browser.value(schema));
};
const schemaFingerprint=schema=>fingerprint(Browser.value(schema),sourceLocations.get(canonicalUri(schema)));
const instanceFingerprint=instance=>fingerprint(Instance.value(instance),undefined,instance);

export function installExactNumericKeywords() {
 const id=name=>'https://json-schema.org/keyword/'+name;
 for(const name of ['minimum','maximum','exclusiveMinimum','exclusiveMaximum','multipleOf']) {
  const original=getKeyword(id(name));
  addKeyword({...original,compile:schemaNumber,interpret:(bound,instance)=>{
   if(Instance.typeOf(instance)!=='number')return true;
   const value=number(instance),order=compare(value,bound);
   return name==='minimum'?order>=0:name==='maximum'?order<=0:name==='exclusiveMinimum'?order>0:name==='exclusiveMaximum'?order<0:multiple(value,bound);
  }});
 }
 const type=getKeyword(id('type'));
 addKeyword({...type,interpret:(types,instance,context)=>{
  if(Instance.typeOf(instance)!=='number')return type.interpret(types,instance,context);
  return (typeof types==='string'?[types]:types).some(t=>t==='number'||t==='integer'&&(number(instance).coefficient===0n||number(instance).exponent>=0n));
 }});
 addKeyword({...getKeyword(id('const')),compile:schemaFingerprint,interpret:(expected,instance)=>expected===instanceFingerprint(instance)});
 addKeyword({...getKeyword(id('enum')),compile:schema=>{
  const source=sourceLocations.get(canonicalUri(schema));
  // Enum members are literal data. Traversing them with Browser.step/values
  // can resolve a JRef wrapper; reading their value must never do so.
  return Browser.value(schema).map((value,i)=>fingerprint(value,source?{doc:source.doc,node:source.node.children.get(String(i))}:undefined));
 },interpret:(options,instance)=>options.includes(instanceFingerprint(instance))});
 addKeyword({...getKeyword(id('uniqueItems')),interpret:(enabled,instance)=>{
  if(!enabled||Instance.typeOf(instance)!=='array')return true;
  const seen=new Set();let cost=0;
  for(const item of Instance.iter(instance)){
   const key=instanceFingerprint(item);cost+=key.length;if(cost>32*1024*1024)throw Error('Exact uniqueItems byte limit');
   if(seen.has(key))return false;seen.add(key);
  }return true;
 }});
}
