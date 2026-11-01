const {test}=require('node:test');
const assert=require('node:assert/strict');
const {govern}=require('./dist/governance.cjs');

function input(version,json,fn,value,options){
 const root='file:///p/root.'+(json?'json':'yaml'),rules='file:///p/rules.'+(json?'json':'yaml');
 return {root,snapshot:'builtin-exact-numbers',resources:[{id:root,generation:1,text:json?
  '{"openapi":"'+version+'","info":{"title":"X","version":"1"},"paths":{},"x-number":'+value+'}':
  'openapi: '+version+'\ninfo: {title: X, version: "1"}\npaths: {}\nx-number: '+value+'\n'}],
  policy:{source:rules,entries:[rules],resources:[{id:rules,text:json?
   '{"rules":{"exact":{"given":"$.x-number","then":{"function":"'+fn+'"'+(options?',"functionOptions":'+options:'')+'}}}}':
   'rules:\n  exact:\n    given: $.x-number\n    then:\n      function: '+fn+'\n'+(options?'      functionOptions: '+options+'\n':'')}]}};
}
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true]){
 test(`builtin truthiness preserves mathematical nonzero values and original source ${version} ${json}`,async()=>{
  for(const raw of ['1e-9999','-1e-9999','0','-0','0.000'])for(const fn of ['truthy','falsy']){
   const params=input(version,json,fn,raw),before=JSON.stringify(params),result=await govern(params);
   assert.equal(result.complete,true,JSON.stringify(result));
   const nonzero=raw.includes('e-9999');
   assert.equal(result.findings.length,(fn==='truthy')!==nonzero?1:0,fn+' '+raw);
   for(const finding of result.findings){assert.equal(finding.code,'policy.rule.exact');assert.equal(finding.pointer,'/x-number');}
   assert.equal(JSON.stringify(params),before);
  }
 });
 test(`builtin length cannot silently compare rounded source inputs or options ${version} ${json}`,async()=>{
  for(const [raw,options]of [['9007199254740993','{"max":9007199254740992}'],['1','{"min":1.0000000000000001}']]){
   const params=input(version,json,'length',raw,options),before=JSON.stringify(params),result=await govern(params);
   assert.equal(result.complete,false,JSON.stringify(result));
   assert(result.findings.some(value=>value.code==='policy.numeric.incomplete'));
   assert.equal(JSON.stringify(params),before);
  }
 });
}
