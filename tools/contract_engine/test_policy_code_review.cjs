const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {reviewPolicyCode}=require('./dist/policy_code_review.cjs');
const root='file:///project/',entry=root+'policy.yaml',main=root+'functions/custom.js';
const defaults={
 [entry]:'functions: [custom]\nrules: {custom-rule: {given: "$.info", then: {function: custom}}}\n',
 [main]:`const helper=require('./helper.cjs');module.exports=value=>helper(value);`,
 [root+'functions/helper.cjs']:`const data=require('./data.json');module.exports=value=>data.allowed.includes(value)?[]:[{message:'review'}];`,
 [root+'functions/data.json']:'{"allowed":["example"]}',
};
function collect({catalog=defaults,denied=[],metadataOnly=[],reverse=false}={}) {
 const records=new Map(),observed=[],dirs=new Set();
 const policy={entries:[entry],resources:Object.entries(catalog).filter(([id])=>id===entry).map(([id,text])=>({id,text}))};
 for(const id of Object.keys(catalog))for(let dir=new URL('.',id);;dir=new URL('../',dir)){
  dirs.add(dir.href.slice(0,-1));const parent=new URL('../',dir);if(parent.href===dir.href)break;
 }
 for(let round=0;round<32;round++){
  const resources=[...records.values()];if(reverse)resources.reverse();
  const result=reviewPolicyCode({policy,resources,scopes:[root]});
  if(!result.requests.length)return {...result,observed,records:[...records.values()]};
  for(const request of result.requests){
   observed.push(request);const id=request.id;
   assert(id.startsWith(root),'An ambient parent/global path was requested: '+id);
   records.set(id,denied.includes(id)?{id,kind:'denied'}:Object.hasOwn(catalog,id)?
    {id,kind:'file',...(!metadataOnly.includes(id)||request.capability==='content'?{text:catalog[id]}:{})}:
    dirs.has(id)?{id,kind:'directory'}:{id,kind:'absent'});
  }
 }
 assert.fail('Source-only closure review did not reach a bounded fixed point');
}
test('declarative functions capture exact transitive code, JSON and located bindings without executing code',()=>{
 const result=collect();assert.equal(result.complete,true,JSON.stringify(result));
 assert.deepEqual(result.modules.map(value=>value.uri).sort(),[main,root+'functions/helper.cjs',root+'functions/data.json'].sort());
 assert.equal(result.declarations[0].uri,main);assert.equal(result.declarations[0].name,'custom');
 assert.equal(result.bindings.length,2);
 for(const binding of result.bindings){assert.equal(binding.resource,binding.target);assert.equal(typeof binding.origin.resource,'string');assert.equal(binding.origin.range.length,2);}
 assert(!result.observed.some(value=>value.id==='file:///package.json'));
 assert.match(result.identity,/^[a-f0-9]{64}$/);
});
test('trust identity is deterministic and invalidated by transitive source, package scope and bindings',()=>{
 const first=collect();assert.equal(collect({reverse:true}).identity,first.identity);
 for(const [id,text]of [[root+'functions/helper.cjs','module.exports=()=>[];'],[root+'functions/data.json','{"allowed":[]}'],
  [root+'package.json','{"type":"commonjs"}'],[main,defaults[main]+'\n// changed code identity']]){
  const next=collect({catalog:{...defaults,[id]:text}});assert.notEqual(next.identity,first.identity,id);
 }
 const {records,observed,...publicReview}=first;
 assert(!JSON.stringify(publicReview).includes('module.exports=value'));
});
test('both explicit and Node-detected ESM functions retain recursive and built-in dependency identities',()=>{
 for(const declaration of [undefined,'{"type":"module"}']){
  const catalog={...defaults,[main]:`import './helper.mjs';import {createHash} from 'node:crypto';export default ()=>[];`,
   [root+'functions/helper.mjs']:`import './custom.js';export const marker=1;`};
  if(declaration)catalog[root+'package.json']=declaration;
  const result=collect({catalog});assert.equal(result.complete,true,JSON.stringify(result));
  assert.equal(result.modules.find(value=>value.uri===main).format,'module');
  assert.equal(result.bindings.find(value=>value.specifier==='node:crypto').builtin,true);
  assert.equal(result.bindings.find(value=>value.from.endsWith('/helper.mjs')).target,main);
 }
});
test('source-only review never executes a ruleset and computed or unavailable dependencies are not green',()=>{
 const code=root+'rules.cjs',text=`globalThis.__busyapi_code_must_not_execute=true;module.exports={rules:{}};`;
 const result=reviewPolicyCode({policy:{entries:[code],resources:[{id:code,text}]},
  scopes:[root],resources:[{id:code,kind:'file',text}]});
 assert.equal(result.complete,true);assert.equal(globalThis.__busyapi_code_must_not_execute,undefined);
 for(const catalog of [{...defaults,[main]:`module.exports=()=>import(process.env.MODULE);`},
  {...defaults,[main]:`module.exports=require('./missing.cjs');`},
  {...defaults,[main]:`module.exports=require('./addon.node');`,[root+'functions/addon.node']:'not a permitted native addon'}]){
  const invalid=collect({catalog});assert.equal(invalid.complete,false);assert(invalid.issues.length>0);
 }
 const denied=collect({denied:[root+'functions/helper.cjs']});assert.equal(denied.complete,false);
 assert(denied.issues.some(value=>value.code==='policy.code.resource.denied'));
});
test('captured package exports and module types use the selected upstream resolver, not source-string replacement',()=>{
 const catalog={...defaults,[main]:`import helper from 'qualified';export default value=>helper(value);`,
  [root+'node_modules/qualified/package.json']:'{"type":"module","exports":"./file%20name.js"}',
  [root+'node_modules/qualified/file%20name.js']:'export default ()=>[];',
  [root+'node_modules/qualified/file%2520name.js']:'THIS MUST NOT BE SELECTED'};
 const result=collect({catalog});assert.equal(result.complete,true,JSON.stringify(result));
 const binding=result.bindings.find(value=>value.specifier==='qualified');assert.equal(binding.target,root+'node_modules/qualified/file%20name.js');
 assert.equal(result.modules.find(value=>value.uri===binding.target).format,'module');
 assert(!result.modules.some(value=>value.uri.endsWith('file%2520name.js')));
});
test('denied or malformed package scope cannot silently change the chosen JavaScript module format',()=>{
 for(const options of [{denied:[root+'functions/package.json']},
  {catalog:{...defaults,[root+'functions/package.json']:'{"type":'}}]){
  const result=collect(options);assert.equal(result.complete,false);
  assert(result.issues.some(value=>value.code.startsWith('policy.code.package.')));
 }
});
test('source-only syntax detection uses V8 wrapper legality and does not run a successfully compiled function',()=>{
 const {inspectPolicyCode}=require('./dist/policy_code.cjs');
 for(const [text,format]of [[`#!/usr/bin/node\nmodule.exports=()=>[];`,'commonjs'],
  [`const module=1;export default module;`,'module'],[`const require=1;`,'module'],
  [`await Promise.resolve();`,'module'],[`const f=()=>import('node:crypto');`,'commonjs'],
  [`globalThis.__busyapi_compiled_must_not_execute=true;return;`,'commonjs']]){
  const result=inspectPolicyCode({resource:main,text,format:'detect'});
  assert.equal(result.format,format,text);assert.equal(result.complete,true,JSON.stringify(result));
 }
 assert.equal(globalThis.__busyapi_compiled_must_not_execute,undefined);
});
test('JSON dependency data uses the canonical strict CST and cannot round large, fractional or underflowed source numbers',()=>{
 for(const [text,complete]of [['{"allowed":9007199254740993}',false],['{"allowed":0.1}',false],
  ['{"allowed":1e-9999}',false],['{"allowed":9007199254740992,"half":1.5}',true],['',false],['{"x":1,"x":2}',false],['{ /* not JSON */ "x":1}',false]]){
  const result=collect({catalog:{...defaults,[root+'functions/data.json']:text}});
  assert.equal(result.complete,complete,JSON.stringify(result));
  if(!complete)assert(result.issues.some(value=>value.resource===root+'functions/data.json'&&value.code.startsWith('policy.code.json.')));
 }
});
