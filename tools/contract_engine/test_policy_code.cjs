const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {inspectPolicyCode}=require('./dist/policy_code.cjs');
const inspect=(text,format='module')=>inspectPolicyCode({resource:'file:///reviewed/functions/rule.js',text,format});
test('Acorn discovers real module dependencies with exact UTF-16 source ranges, never execution',()=>{
 const text=`// 😀 import 'not-a-dependency';\nconst string="require('not-code')";\nconst expression=/import 'not-code'/;\nimport helper from './helper.mjs';\nexport {other} from './other.mjs';\nexport * from 'example-package';\nawait import('node:crypto');\nthrow new Error('MUST NOT EXECUTE');`;
 const result=inspect(text);
 assert.equal(result.complete,true);assert.equal(result.identity,createHash('sha256').update(text).digest('hex'));
 assert.deepEqual(result.dependencies.map(value=>[value.specifier,value.kind,value.builtin]),[
  ['./helper.mjs','import',false],['./other.mjs','export',false],['example-package','export',false],['node:crypto','import',true]]);
 for(const dependency of result.dependencies)assert.equal(text.slice(...dependency.range).slice(1,-1),dependency.specifier);
 assert.equal(result.parser.version,'8.19.0');
});
test('CommonJS literals and require.resolve are captured without calling a module loader',()=>{
 const result=inspect(`const helper=require('./helper.cjs');const id=require.resolve('package-name');\nmodule.exports = async value => helper(value);`,'commonjs');
 assert.equal(result.complete,true);assert.deepEqual(result.dependencies.map(value=>[value.specifier,value.kind]),[['./helper.cjs','require'],['package-name','require.resolve']]);
});
test('computed loads have located incomplete review, not a green empty dependency list',()=>{
 for(const text of [`const p='./part.js';import(p);`,`import('./'+name);`,`require(name);`,`require.resolve(...names);`,`import(\`./part.js\`);`]){
  const result=inspect(text);assert.equal(result.complete,false,text);assert.equal(result.issues[0].code,'policy.code.dependency.computed');
  assert.equal(result.issues[0].range[1],text.length-1);assert.equal(result.dependencies.length,0);
 }
});
test('nested imports and requires remain visible inside callbacks, object values and branches',()=>{
 const result=inspect(`export default async value=>({a:await import('./first.mjs'),b:()=>require('./second.cjs')});\nif (false) { require('./conditional.cjs'); }`);
 assert.deepEqual(result.dependencies.map(value=>value.specifier),['./first.mjs','./second.cjs','./conditional.cjs']);
});
test('syntax errors do not echo suspicious source strings across IPC',()=>{
 const secret='ghp_'+'a9B'.repeat(16),result=inspect(`export const ${secret} = ;`);
 assert.equal(result.complete,false);assert.equal(result.issues[0].code,'policy.code.syntax');
 assert(!JSON.stringify(result).includes(secret));assert.equal(result.dependencies.length,0);
});
test('invalid formats, excessive source and excessive dependency work fail explicitly',()=>{
 for(const value of [{text:'x'.repeat(262145),format:'module'},{text:'',format:'guess'}])
  assert.throws(()=>inspectPolicyCode({resource:'file:///p/code.js',...value}),error=>error.code==='policy.code.input');
 assert.throws(()=>inspect(Array.from({length:1025},(_,index)=>`import './d${index}.js';`).join('\n')),error=>error.code==='limit.policy.code.dependencies');
 assert.throws(()=>inspect('('.repeat(10000)+'0'+')'.repeat(10000)),error=>error.code==='limit.policy.code.nesting');
});
