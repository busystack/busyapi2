const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {tmpdir}=require('node:os');
const {fileURLToPath,pathToFileURL}=require('node:url');
const {spawnSync}=require('node:child_process');
const {resolvePolicyCode}=require('./dist/policy_code_resolution.cjs');
const from='file:///project/rules.mjs';
const contents={
 [from]:'export default {};',
 'file:///project/package.json':JSON.stringify({name:'fixture',type:'module',imports:{'#helper':'./helpers/local.mjs'}}),
 'file:///project/helpers/local.mjs':'export const marker=1;',
 'file:///project/helpers/local.cjs':'module.exports=1;',
 'file:///project/node_modules/conditional/package.json':JSON.stringify({name:'conditional',type:'module',exports:{'.':{import:'./esm.mjs',require:'./common.cjs'},'./*':'./features/*.mjs'}}),
 'file:///project/node_modules/conditional/esm.mjs':'export const value=1;',
 'file:///project/node_modules/conditional/common.cjs':'module.exports=1;',
 'file:///project/node_modules/conditional/features/part.mjs':'export default 1;',
 'file:///project/node_modules/@scope/legacy/package.json':JSON.stringify({name:'@scope/legacy',main:'./index.cjs'}),
 'file:///project/node_modules/@scope/legacy/index.cjs':'module.exports=1;',
};
function collect(requests,{catalog=contents,denied=[]}={}){
 const resources=new Map([[from,{id:from,kind:'file',text:contents[from]}]]),directories=new Set();
 for(const id of Object.keys(catalog))for(let parent=path.posix.dirname(new URL(id).pathname);;parent=path.posix.dirname(parent)){
  directories.add('file://'+parent);if(parent==='/')break;
 }
 const observations=[];
 for(let round=0;round<16;round++){
  const result=resolvePolicyCode({resources:[...resources.values()],requests,snapshot:'captured-code'});
  if(!result.requests.length)return {...result,observations,resources:[...resources.values()]};
  for(const request of result.requests){
   observations.push(request);
   const id=request.id;
   resources.set(id,denied.includes(id)?{id,kind:'denied'}:Object.hasOwn(catalog,id)?{id,kind:'file',text:catalog[id]}:
    directories.has(id)?{id,kind:'directory'}:{id,kind:'absent'});
  }
 }
 assert.fail('Controlled snapshot collection did not reach a fixed point');
}
test('the public maintained resolver uses captured package conditions, imports, exports and exact source identities',()=>{
 const requests=[['import','#helper','file:///project/helpers/local.mjs'],
  ['import','conditional','file:///project/node_modules/conditional/esm.mjs'],
  ['require','conditional','file:///project/node_modules/conditional/common.cjs'],
  ['import','conditional/part','file:///project/node_modules/conditional/features/part.mjs'],
  ['require','@scope/legacy','file:///project/node_modules/@scope/legacy/index.cjs']];
 const result=collect(requests.map(([mode,specifier])=>({from,mode,specifier})));
 assert.equal(result.complete,true,JSON.stringify(result));
 assert.deepEqual(result.resolutions.map(value=>value.target),requests.map(value=>value[2]));
 assert(result.observations.length>0);assert.equal(result.snapshot,'captured-code');
 assert.equal(result.resolver.version,'5.26.0');
});
test('unknown candidates request core approval/observation instead of disappearing as absent',()=>{
 const result=resolvePolicyCode({resources:[{id:from,kind:'file',text:contents[from]}],requests:[{from,specifier:'./missing.mjs',mode:'import'}]});
 assert.equal(result.complete,false);assert(result.requests.some(value=>value.id==='file:///project/missing.mjs'));
 assert(result.issues.some(value=>value.code==='policy.code.resolution.incomplete'));
});
test('a denied higher-priority candidate stays incomplete beside a resolvable package',()=>{
 const denied='file:///project/node_modules/conditional.js';
 const result=collect([{from,specifier:'conditional',mode:'require'}],{denied:[denied]});
 assert.equal(result.complete,false);assert(result.issues.some(value=>value.code==='policy.code.resource.denied'&&value.resource===denied));
});
test('known missing modules remain incomplete while file-module suffixes retain their separate identities',()=>{
 const missing=collect([{from,specifier:'./missing.mjs',mode:'import'}]);assert.equal(missing.complete,false);assert.equal(missing.requests.length,0);
 for(const specifier of ['./helpers/local.mjs?mode=one','./helpers/local.mjs#instance']){
  const result=collect([{from,specifier,mode:'import'}]);assert.equal(result.complete,true,JSON.stringify(result));
  assert.equal(result.resolutions[0].target,new URL(specifier,from).href);
  assert.equal(result.resolutions[0].resource,'file:///project/helpers/local.mjs');
  assert(!result.observations.some(value=>value.id.includes('?')||value.id.includes('#')));
 }
});
test('URI aliases retain original module bases without consulting physical or worker paths',()=>{
 const root='https://policy.invalid/rules/main.mjs',target='https://policy.invalid/rules/part.mjs',
  resources=[{id:from,aliases:[root],kind:'file',text:'export default {};'},
   {id:'file:///mapped/part.mjs',aliases:[target],kind:'file',text:'export default 1;'}];
 // Capture the only description metadata this fully specified lookup observes.
 let current=resources,result;
 for(let round=0;round<8;round++){
  result=resolvePolicyCode({resources:current,requests:[{from:root,specifier:'./part.mjs',mode:'import'}]});
  if(!result.requests.length)break;
  current=[...current,...result.requests.map(value=>({id:value.id,kind:'absent'}))];
 }
 assert.equal(result.complete,true,JSON.stringify(result));
 assert.equal(result.resolutions[0].target,target);assert.equal(result.resolutions[0].resource,'file:///mapped/part.mjs');
});
test('direct ESM URI imports decode Unicode/spaces once while scoped package names retain legal pchar',()=>{
 const target='file:///project/helpers/%E9%9B%AA%20file.mjs';
 const catalog={...contents,[target]:'export default 1;'};
 for(const specifier of ['./helpers/雪 file.mjs','./helpers/%E9%9B%AA%20file.mjs']){
  const result=collect([{from,specifier,mode:'import'}],{catalog});
  assert.equal(result.complete,true,JSON.stringify(result));assert.equal(result.resolutions[0].target,target);
  assert(!result.observations.some(value=>value.id.includes('%25E9')));
 }
 const scoped=collect([{from,specifier:'@scope/legacy',mode:'require'}]);
 assert.equal(scoped.complete,true);assert(!scoped.observations.some(value=>value.id.includes('%40scope')));
});
test('proven package URL targets decode once and never choose an adversarial literal-percent filename',()=>{
 const catalog={...contents,
  'file:///project/node_modules/conditional/package.json':JSON.stringify({name:'conditional',exports:'./file%20name.mjs'}),
  'file:///project/node_modules/conditional/file%2520name.mjs':'export default "wrong literal percent target";',
 };
 const missing=collect([{from,specifier:'conditional',mode:'import'}],{catalog});
 assert.equal(missing.complete,false);assert(!missing.resolutions[0].target);
 assert(missing.observations.some(value=>value.id==='file:///project/node_modules/conditional/file%20name.mjs'));
 for(const mode of ['import','require']){
  const result=collect([{from,specifier:'conditional',mode}],{catalog:{...catalog,
   'file:///project/node_modules/conditional/file%20name.mjs':'export default "correct decoded URI target";'}});
  assert.equal(result.complete,true,JSON.stringify(result));
  assert.equal(result.resolutions[0].target,'file:///project/node_modules/conditional/file%20name.mjs');
  assert(!result.observations.some(value=>value.id.includes('file%2520')));
 }
});
test('Node 24 independently confirms selected URL targets, cache suffixes, exact exports and legacy main paths',()=>{
 assert.equal(process.versions.node,'24.15.0');
 const cases=[
  {specifier:'conditional',declaration:{exports:'./file%20name.mjs'},files:{'file name.mjs':'export default "decoded space";','file%20name.mjs':'export default "wrong literal percent";'}},
  {specifier:'conditional',declaration:{exports:'./file%2520name.mjs'},files:{'file%20name.mjs':'export default "one decode";','file name.mjs':'export default "wrong double decode";'}},
  {specifier:'conditional',declaration:{exports:'./exact'},files:{'exact.js':'export default "must not guess an extension";'},invalid:true},
  {specifier:'conditional',declaration:{main:'./literal%20name.cjs'},files:{'literal%20name.cjs':'module.exports="literal legacy path";'}},
  {specifier:'conditional',declaration:{main:'./legacy'},files:{'legacy.js':'module.exports="Node main extension resolution";'}},
  {specifier:'#helper',declaration:{},imports:{'#helper':'./helpers/file%20name.mjs'},files:{},rootFiles:{'helpers/file name.mjs':'export default "imports URI";','helpers/file%20name.mjs':'export default "wrong imports literal";'}},
  {specifier:'./helpers/local.mjs?instance=one#anchor',declaration:{},files:{},modes:['import']},
 ];
 for(const item of cases)for(const mode of item.modes??['import','require']){
  const folder=fs.mkdtempSync(path.join(tmpdir(),'busyapi-node-oracle ü '));
  try{
   const catalog={...contents,
    'file:///project/package.json':JSON.stringify({name:'fixture',type:'module',imports:item.imports??{'#helper':'./helpers/local.mjs'}}),
    'file:///project/node_modules/conditional/package.json':JSON.stringify({name:'conditional',...item.declaration}),
   };
   for(const [name,text]of Object.entries(item.files))catalog[pathToFileURL('/project/node_modules/conditional/'+name).href]=text;
   for(const [name,text]of Object.entries(item.rootFiles??{}))catalog[pathToFileURL('/project/'+name).href]=text;
   for(const [id,text]of Object.entries(catalog)){
    const target=folder+fileURLToPath(id).slice('/project'.length);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,text);
   }
   const script=`import {createRequire} from 'node:module';import {pathToFileURL} from 'node:url';const require=createRequire(import.meta.url);
    const mode=${JSON.stringify(mode)},specifier=${JSON.stringify(item.specifier)};
    try{const resolved=mode==='import'?import.meta.resolve(specifier):pathToFileURL(require.resolve(specifier)).href;
     const value=mode==='import'?await import(specifier):require(specifier);process.stdout.write(JSON.stringify({resolved,value:value.default??value}));
    }catch(error){process.stdout.write(JSON.stringify({error:error.code}));}`;
   const actual=spawnSync(process.execPath,['--input-type=module','--eval',script],{cwd:folder,env:{},encoding:'utf8',timeout:10000,maxBuffer:65536});
   assert.ifError(actual.error);assert.equal(actual.status,0,actual.stderr);
   const oracle=JSON.parse(actual.stdout),result=collect([{from,specifier:item.specifier,mode}],{catalog});
   if(item.invalid){assert(oracle.error,JSON.stringify(oracle));assert.equal(result.complete,false,JSON.stringify(result));}
   else{
    assert(!oracle.error,JSON.stringify(oracle));assert.equal(result.complete,true,JSON.stringify(result));
    const expected=oracle.resolved.replace(pathToFileURL(folder).href,'file:///project');
    assert.equal(result.resolutions[0].target,expected,JSON.stringify({mode,specifier:item.specifier,oracle,result}));
    assert.equal(result.resolutions[0].resource,new URL(expected).href.split('?')[0].split('#')[0]);
   }
  }finally{fs.rmSync(folder,{recursive:true,force:true});}
 }
});
test('resolver execution has no ambient filesystem or network acquisition path',()=>{
 const methods=['readFileSync','statSync','lstatSync','readlinkSync','readdirSync'],before=Object.fromEntries(methods.map(name=>[name,fs[name]]));
 try{for(const name of methods)fs[name]=()=>assert.fail('Unexpected host filesystem '+name);
  const result=collect([{from,specifier:'conditional',mode:'import'}]);assert.equal(result.complete,true);
 }finally{for(const name of methods)fs[name]=before[name];}
});
test('missing importers, ambiguous aliases and contradictory snapshots cannot be accepted',()=>{
 assert.throws(()=>resolvePolicyCode({resources:[],requests:[{from,specifier:'node:fs',mode:'import'}]}),error=>error.code==='policy.code.importer');
 const resource={id:from,kind:'file',text:contents[from]};
 assert.throws(()=>resolvePolicyCode({resources:[resource,{...resource,id:'file:///other.mjs',aliases:[from]}],requests:[]}),error=>error.code==='policy.code.identity');
 assert.throws(()=>resolvePolicyCode({resources:[resource,{id:'file:///project',kind:'absent'}],requests:[]}),error=>error.code==='policy.code.snapshot');
});
