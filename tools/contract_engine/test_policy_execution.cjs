const {test}=require('node:test');
const assert=require('node:assert/strict');
const {once}=require('node:events');
const fs=require('node:fs');
const path=require('node:path');
const {tmpdir}=require('node:os');
const {PolicyProcessWorker}=require(process.env.BUSYAPI_TEST_POLICY_TRANSPORT);
const {reviewPolicyCode}=require(process.env.BUSYAPI_TEST_POLICY_REVIEW);
const root='file:///approved/root.json',rules='file:///approved/policy.yaml',code='file:///approved/functions/custom.js';
function capture(policy,catalog) {
 const resources=new Map(),directories=new Set();
 for(const id of Object.keys(catalog))for(let dir=new URL('.',id);;dir=new URL('../',dir)){
  directories.add(dir.href.slice(0,-1));if(new URL('../',dir).href===dir.href)break;
 }
 for(let round=0;round<64;round++) {
  const review=reviewPolicyCode({policy,resources:[...resources.values()],scopes:['file:///approved/']});
  if(!review.requests.length){assert.equal(review.complete,true,JSON.stringify(review));return {identity:review.identity,scopes:review.scopes,resources:[...resources.values()]};}
  for(const request of review.requests)resources.set(request.id,Object.hasOwn(catalog,request.id)?{id:request.id,kind:'file',text:catalog[request.id]}:
   directories.has(request.id)?{id:request.id,kind:'directory'}:{id:request.id,kind:'absent'});
 }
 assert.fail('Test closure did not reach a fixed point');
}
function input(version,source,extras={},jsRuleset=false) {
 const declaration=jsRuleset?'file:///approved/rules.cjs':rules;
 const text=jsRuleset?source:'functions: [custom]\nrules:\n  reviewed:\n    given: $.info.title\n    then: {function: custom}\n';
 const policy={source:declaration,entries:[declaration],resources:[{id:declaration,text},...(!jsRuleset?[{id:code,text:source}]:[])]};
 const catalog={[declaration]:text,...(!jsRuleset?{[code]:source}:{}),...extras};
 return {root,snapshot:'isolated-executable-'+version,resources:[{id:root,generation:1,
  text:JSON.stringify({openapi:version,info:{title:'Needs review',version:'1'},paths:{}})}],policy:{...policy,execution:capture(policy,catalog)}};
}
async function run(params) {
 const worker=new PolicyProcessWorker({launcher:process.env.BUSYAPI_TEST_POLICY_LAUNCHER,node:process.execPath,helper:process.env.BUSYAPI_TEST_POLICY_ENTRY},15000);
 const result=once(worker,'message');worker.postMessage({id:'reviewed-execution',method:'govern',params});
 try{const [bytes]=await result;return JSON.parse(new TextDecoder().decode(bytes));}finally{await worker.terminate();}
}
test('repeated real bootstrap preserves and consumes the pinned proc inspection identity',{timeout:60000},async()=>{
 const params=input('3.2.1','module.exports=()=>[{message:"reviewed result"}];');
 for(let index=0;index<32;index++){
  const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify({index,error:answer.error}));
  assert.equal(answer.result.complete,true,JSON.stringify({index,result:answer.result}));
  assert.equal(answer.result.findings[0].code,'policy.rule.reviewed');
 }
});
for(const version of ['3.1.2','3.2.1'])test(`real restricted CommonJS executes and awaits a reviewed transitive function ${version}`,async()=>{
 const params=input(version,`const helper=require('./helper.cjs');module.exports=async value=>{await new Promise(resolve=>setTimeout(resolve,5));return helper(value);};`,{
  'file:///approved/functions/helper.cjs':`const setting=require('./data.json');module.exports=value=>value===setting.allowed?[]:[{message:'local reviewed policy'}];`,
  'file:///approved/functions/data.json':'{"allowed":"Approved title"}',
 });
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
 assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
 assert.equal(answer.result.findings.length,1);assert.equal(answer.result.findings[0].code,'policy.rule.reviewed');
 assert.equal(answer.result.findings[0].resource,root);assert.equal(answer.result.findings[0].pointer,'/info/title');
 assert(answer.result.coverage.includes('reviewed-isolated-code'));
 assert.equal(answer.result.effectiveRules[0].provenance[0].resource,rules);
});
test('real restricted ESM uses pinned bundled public API and original relative module identity',async()=>{
 for(const extension of ['mjs','cjs']){
 const params=input('3.2.1',`import {createRulesetFunction} from '@stoplight/spectral-core';import helper from './helper.${extension}';
 export default createRulesetFunction({input:null,options:null},async value=>helper(value));`,{
  ['file:///approved/functions/helper.'+extension]:extension==='mjs'?`export default value=>[{message:'reviewed ESM'}];`:`module.exports=value=>[{message:'native CJS interop'}];`,
 });
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
 assert.equal(answer.result.complete,true,JSON.stringify(answer.result));assert.equal(answer.result.findings[0].code,'policy.rule.reviewed');
 }
});
test('real restricted executable rulesets retain whole-code provenance without invented JSON locations',async()=>{
 const params=input('3.1.2',`const {createRulesetFunction}=require('@stoplight/spectral-core');
 const fn=createRulesetFunction({input:null,options:null},()=>[{message:'reviewed ruleset'}]);
 module.exports={rules:{reviewed:{given:'$.info.title',then:{function:fn},severity:'error'}}};`,{},true);
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
 assert.equal(answer.result.complete,true,JSON.stringify(answer.result));assert.equal(answer.result.findings[0].code,'policy.rule.reviewed');
 const declaration=answer.result.effectiveRules[0].provenance[0];
 assert.equal(declaration.resource,'file:///approved/rules.cjs');assert.equal(declaration.pointer,'');
 assert.deepEqual(declaration.range,[0,params.policy.resources[0].text.length]);
});
test('kernel restrictions still deny filesystem/network/process capabilities inside actual approved code',async()=>{
 const directory=fs.mkdtempSync(path.join(tmpdir(),'busyapi-denied-code-')),marker=path.join(directory,'must-not-write');
 try {
  const source=`const fs=require('node:fs');const cp=require('node:child_process');const net=require('node:net');
   module.exports=async ()=>{let escaped=Object.keys(process.env).length!==0;
    try{fs.writeFileSync(${JSON.stringify(marker)},'denied');escaped=true;}catch{}
    try{fs.readFileSync(${JSON.stringify(__filename)});escaped=true;}catch{}
    try{const result=cp.spawnSync('/bin/true');if(!result.error&&result.status===0)escaped=true;}catch{}
    const socket=new net.Socket();await new Promise(resolve=>{socket.once('error',resolve);socket.connect({host:'127.0.0.1',port:9},()=>{escaped=true;socket.destroy();resolve();});});
    return escaped?[{message:'capability escaped'}]:[];};`;
  const params=input('3.2.1',source),answer=await run(params);
  assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
  assert.deepEqual(answer.result.findings,[]);assert.equal(fs.existsSync(marker),false);
 } finally{fs.rmSync(directory,{recursive:true,force:true});}
});
test('caught unreviewed runtime loads stay incomplete rather than empty policy success',async()=>{
 const params=input('3.2.1',`const {createRequire}=require('node:module');const foreign=createRequire('file:///approved/unknown.cjs');
 module.exports=()=>{try{foreign('not-reviewed');}catch{}return [];};`),answer=await run(params);
 assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,false);
 assert(answer.result.findings.some(value=>value.code==='policy.code.load.unreviewed'));
});
test('changed code identity and load errors never become clean results or echo code',async()=>{
 for(const source of [`throw new Error('DO NOT ECHO PRIVATE CODE');`, `module.exports=1;`]) {
  const params=input('3.2.1',source),answer=await run(params);
  assert.equal(answer.ok,false);assert.match(answer.error.code,/^policy\.code\./);assert(!JSON.stringify(answer).includes('DO NOT ECHO'));
 }
 const stale=input('3.2.1','module.exports=()=>[];');stale.policy.execution.identity='0'.repeat(64);
 const answer=await run(stale);assert.equal(answer.ok,false);assert.equal(answer.error.code,'policy.code.stale');
});
test('custom rules cannot inspect a rounded canonical numeric example as if it were exact',async()=>{
 const params=input('3.2.1','module.exports=()=>[];');
 params.resources[0].text='{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"x-number":9007199254740993}';
 const policy=params.policy.resources.find(value=>value.id===rules);policy.text=policy.text.replace('$.info.title','$');
 params.policy.execution=capture(params.policy,Object.fromEntries(params.policy.resources.map(value=>[value.id,value.text])));
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,false);
 assert(answer.result.findings.some(value=>value.code==='policy.numeric.incomplete'));
});
test('a narrow custom input cannot bypass exactness through the full public document context',async()=>{
 const params=input('3.2.1',`module.exports=(_value,_options,context)=>{
  const data=context.document.data??context.document.parsed.data;
  return data['x-number']===Number('9007199254740993')?[]:[{message:'not rounded'}];
 };`);
 params.resources[0].text='{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"x-number":9007199254740993}';
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
 assert.equal(answer.result.complete,false,JSON.stringify(answer.result));
 assert(answer.result.findings.some(value=>value.code.startsWith('policy.numeric.')));
});
test('public inventory routes retain a caught exactness denial rather than an empty clean result',async()=>{
 for(const expression of ['context.document.data','context.documentInventory.document.data',
  'context.documentInventory.resolved','context.documentInventory.unresolved',
  "context.documentInventory.findAssociatedItemForPath(['info'],false).document.data"]){
  const params=input('3.2.1',`module.exports=(_value,_options,context)=>{try{const data=${expression};void data['x-number'];}catch{}return [];};`);
  params.resources[0].text='{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"x-number":9007199254740993}';
  const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,false,expression);
  const finding=answer.result.findings.find(value=>value.code==='policy.numeric.context.incomplete');assert(finding,expression);
  assert.equal(finding.resource,root);assert.equal(finding.pointer,'/x-number');
 }
});
test('safe narrow functions remain useful beside large examples without reading an inexact full context',async()=>{
 const params=input('3.2.1',`module.exports=value=>value==='Review'?[]:[{message:'scoped finding'}];`);
 params.resources[0].text='{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"x-number":9007199254740993}';
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
 assert.deepEqual(answer.result.findings,[]);
});
test('primitive policy options cannot lose their source numeric identity before a custom function',async()=>{
 const params=input('3.1.2',`module.exports=(_value,expected)=>expected===Number('9007199254740993')?[]:[{message:'unexpected'}];`);
 params.policy.resources.find(value=>value.id===rules).text+=`    # retained option\n    severity: error\n`;
 const declaration=params.policy.resources.find(value=>value.id===rules);
 declaration.text=declaration.text.replace('then: {function: custom}','then: {function: custom, functionOptions: 9007199254740993}');
 params.policy.execution=capture(params.policy,Object.fromEntries(params.policy.resources.map(value=>[value.id,value.text])));
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,false,JSON.stringify(answer.result));
 assert(answer.result.findings.some(value=>value.code==='policy.numeric.context.incomplete'&&value.resource===rules));
});
test('exact public metadata/data interfaces and asynchronous path ownership retain their supported behavior',async()=>{
 const params=input('3.2.1',`module.exports=async(value,_options,context)=>{
  const doc=context.document,inventory=context.documentInventory;
  if(inventory.document!==doc||inventory.resolved!==doc.data||inventory.unresolved!==doc.data)throw Error('public identity changed');
  if(inventory.findAssociatedItemForPath(context.path,false).document!==doc)throw Error('source identity changed');
  if(doc.trapAccess({value}).value!==value||!doc.getRangeForJsonPath(context.path))throw Error('public methods changed');
  if(context.rule.resolved!==true)throw Error('captured resolution view was hidden');
  void context.rule.then;void context.rule.extensions;
  await new Promise(resolve=>setTimeout(resolve,5));return [{message:'source path',path:context.path}];
 };`);
 params.resources[0].text='{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"tags":[{"name":"one"},{"name":"two"}]}';
 const declaration=params.policy.resources.find(value=>value.id===rules);
 declaration.text=declaration.text.replace('$.info.title','$.tags[*].name');
 params.policy.execution=capture(params.policy,Object.fromEntries(params.policy.resources.map(value=>[value.id,value.text])));
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
 assert.deepEqual(answer.result.findings.map(value=>value.pointer).sort(),['/tags/0/name','/tags/1/name']);
});
test('inactive numeric options do not poison another rule or its safe authored options',async()=>{
 const params=input('3.2.1',`module.exports=(value,options)=>value===options.expected?[]:[{message:'wrong value'}];`);
 const declaration=params.policy.resources.find(value=>value.id===rules);
 declaration.text=declaration.text.replace('then: {function: custom}','then: {function: custom, functionOptions: {expected: "Needs review"}}')+
  '  inactive:\n    severity: off\n    given: $.info.title\n    then: {function: custom, functionOptions: 9007199254740993}\n';
 params.policy.execution=capture(params.policy,Object.fromEntries(params.policy.resources.map(value=>[value.id,value.text])));
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
 assert.deepEqual(answer.result.findings,[]);
});
test('inactive JS overrides do not become effective provenance merely because their whole-source location is shared',async()=>{
 const params=input('3.2.1',`module.exports={rules:{reviewed:{given:'$.info.title',then:{function:()=>[]}}},
  overrides:[{files:['file:///not-the-captured-root/**'],rules:{reviewed:{given:'$.info.version',then:{function:()=>[{message:'inactive'}]}}}}]};`,{},true);
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
 assert.deepEqual(answer.result.findings,[]);
 assert.equal(answer.result.effectiveRules[0].provenance.length,1);
 assert.equal(answer.result.effectiveRules[0].provenance[0].pointer,'');
});
test('executable rulesets extend the pinned public OAS preset without compiling it as project-owned declarations',async()=>{
 const params=input('3.2.1',`const {oas}=require('@stoplight/spectral-rulesets');module.exports={extends:[oas]};`,{},true);
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
 assert(answer.result.effectiveRules.some(value=>value.provenance.some(origin=>origin.resource==='spectral:oas')));
});
test('declarative filters execute only after an explicit source-only review inside the restricted process',async()=>{
 const policy={source:rules,entries:[rules],resources:[{id:rules,text:
  'rules:\n  reviewed:\n    given: $.tags[?(@.name === "one")]\n    then: {field: description, function: truthy}\n'}]};
 const params={root,snapshot:'isolated-selector',resources:[{id:root,generation:1,text:JSON.stringify({
  openapi:'3.2.1',info:{title:'Selectors',version:'1'},paths:{},tags:[{name:'one'},{name:'two'}]})}],
  policy:{...policy,execution:capture(policy,{[rules]:policy.resources[0].text})}};
 assert.equal(params.policy.execution.resources.length,0);
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
 assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
 assert.deepEqual(answer.result.findings.map(value=>value.pointer),['/tags/0']);
});
test('nested and format-scoped project filters cannot select on rounded contract numbers',async()=>{
 for(const given of ['$.tags[?(@.n === 9007199254740992)]','#Nested']) {
  for(const scoped of [false,true]) {
   const policy={source:rules,entries:[rules],resources:[{id:rules,text:JSON.stringify({
    aliases:{Selected:scoped?{targets:[{formats:['oas3_2'],given:['$.tags[?(@.n === 9007199254740992)]']}]}:
     ['$.tags[?(@.n === 9007199254740992)]'],Nested:['#Selected']},
    rules:{reviewed:{given,then:{field:'description',function:'truthy'}}}})}]};
   const params={root,snapshot:'isolated-numeric-selector',resources:[{id:root,generation:1,
    text:'{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"tags":[{"name":"one","n":9007199254740993}]}'}],
    policy:{...policy,execution:capture(policy,{[rules]:policy.resources[0].text})}};
   const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
   assert.equal(answer.result.complete,false,JSON.stringify(answer.result));
   assert(answer.result.findings.some(value=>value.code==='policy.numeric.selector.incomplete'&&value.pointer==='/tags/0/n'));
  }
 }
});
test('reviewed custom formats are awaited, honor true/false, and retain their public context identity',async()=>{
 for(const applies of [false,true]) {
  const params=input('3.2.1',`const format=async(value,source)=>{await new Promise(resolve=>setTimeout(resolve,5));
    if(source!==${JSON.stringify(root)}||value.info.title!=='Needs review')throw Error('wrong format input');return ${applies};};
   const fn=(_v,_o,context)=>{if(!context.document.formats.has(format))throw Error('missing format');return [{message:'custom format'}];};
   module.exports={formats:[format],rules:{reviewed:{given:'$.info.title',then:{function:fn}}}};`,{},true);
  const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
  assert.equal(answer.result.complete,true,JSON.stringify(answer.result));
  assert.equal(answer.result.effectiveRules[0].applicable,applies);
  assert.equal(answer.result.findings.length,applies?1:0);
 }
});
test('custom format failure, invalid return and numeric data are incomplete, never not-applicable success',async()=>{
 for(const body of ['throw Error("do not echo format code");','return "yes";','return value["x-number"]===9007199254740992;']) {
  const params=input('3.2.1',`const format=value=>{${body}};
   module.exports={formats:[format],rules:{reviewed:{given:'$.info.title',then:{function:()=>[]}}}};`,{},true);
  if(body.includes('x-number'))params.resources[0].text='{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"x-number":9007199254740993}';
  const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
  assert.equal(answer.result.complete,false,JSON.stringify(answer.result));
  assert(answer.result.findings.some(value=>/^policy\.(numeric\.format|format\.)/.test(value.code)));
  assert(!JSON.stringify(answer).includes('do not echo'));
 }
});
test('approved JS rulesets retain exact bundled truthiness instead of treating a pinned public function as arbitrary code',async()=>{
 const params=input('3.2.1',`const {truthy}=require('@stoplight/spectral-functions');
  module.exports={rules:{reviewed:{given:'$.x-number',then:{function:truthy}}}};`,{},true);
 params.resources[0].text='{"openapi":"3.2.1","info":{"title":"Review","version":"1"},"paths":{},"x-number":1e-9999}';
 const answer=await run(params);assert.equal(answer.ok,true,JSON.stringify(answer.error));
 assert.equal(answer.result.complete,true,JSON.stringify(answer.result));assert.deepEqual(answer.result.findings,[]);
});
