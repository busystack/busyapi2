const {test}=require('node:test');
const assert=require('node:assert/strict');
const {discoverPolicy,policyDependencyUri}=require('./dist/governance_configuration.cjs');

const root='file:///project/rules.yaml',other='file:///project/base.yaml';
const source=(id,text,aliases=[])=>({id,text,aliases,generation:3});
const inspect=(resources,entries=[root])=>discoverPolicy({resources,entries});

test('dependency discovery preserves approved URI bases and waits for the supplied closure',()=>{
 const alias='https://rules.example/nested/policy.yaml',target='https://rules.example/nested/base.yaml';
 const first=source(root,'extends: [./base.yaml]\nrules: {}\n',[alias]);
 const pending=inspect([first],[alias]);
 assert.deepEqual(pending.requests,[target]);assert.equal(pending.complete,false);assert.deepEqual(pending.issues,[]);
 const base=source(other,'extends: [busyapi:recommended]\nrules: {}\n',[target]);
 const resources=[first,base],before=JSON.stringify(resources),complete=inspect(resources,[alias]);
 assert.equal(complete.version,1);assert.equal(complete.complete,true);assert.deepEqual(complete.requests,[]);assert.deepEqual(complete.issues,[]);
 assert.equal(JSON.stringify(resources),before);assert.deepEqual(inspect([base,first],[alias]),complete);
});

test('trusted presets need no resources and payload-like dependency keys remain data',()=>{
 assert.deepEqual(inspect([],['busyapi:recommended','spectral:oas']),{version:1,requests:[],complete:true,issues:[]});
 const text='rules: {}\nx-data: {extends: "https://must-not-load.invalid", "$ref": "payload"}\n';
 const result=inspect([source(root,text)]);
 assert.equal(result.complete,true);assert.deepEqual(result.requests,[]);assert.deepEqual(result.issues,[]);
});

test('policy path spaces and escaped unreserved URI tokens share one identity without modifying source',()=>{
 const alias='https://rules.example/nested/policy.yaml',target='https://rules.example/nested/base%20rules.yaml';
 const text='extends: ["./%62ase rules.yaml"]\nrules: {}\n';
 const resources=[source(root,text,[alias]),source(other,'rules: {}\n',[target])];
 const before=JSON.stringify(resources);
 assert.equal(policyDependencyUri('./%62ase rules.yaml',alias),target);
 assert.equal(inspect(resources,[alias]).complete,true);
 assert.deepEqual(inspect(resources,[alias]).requests,[]);
 assert.equal(JSON.stringify(resources),before);
 for(const value of ['\\outside.yaml','\n./base.yaml',' ./base.yaml','./bad%xy.yaml'])
  assert.throws(()=>policyDependencyUri(value,alias),error=>error.code==='policy.uri');
});

for(const [name,text]of[
 ['yaml-syntax','rules: [\n'],
 ['yaml-duplicate','rules: {}\nrules: {}\n'],
 ['json-syntax','{"rules":'],
 ['json-duplicate','{"rules":{},"rules":{}}'],
 ['scalar','not a ruleset'],
 ['invalid-extends','extends: [42]\nrules: {}\n'],
 ['invalid-overrides','overrides: {files: "**"}\n'],
 ['invalid-override-entry','overrides: [null]\n'],
])test(`incomplete ${name} cannot prove dependency discovery complete`,()=>{
 const id=name.startsWith('json')?root.replace('.yaml','.json'):root;
 const result=inspect([source(id,text)],[id]);
 assert.equal(result.complete,false);assert(result.issues.length>0);
 assert(result.issues.every(issue=>issue.resource===id&&typeof issue.pointer==='string'&&issue.code.startsWith('policy.dependencies.')));
 assert.deepEqual(result.requests,[]);
});

for(const text of[
 'functions: [custom]\nrules: {}\n',
 'functionsDir: ./functions\nrules: {}\n',
 'overrides:\n  - files: ["**"]\n    functions: [custom]\n    rules: {}\n',
])test('custom function dependencies remain explicitly unknown and no function is loaded',()=>{
 const result=inspect([source(root,text)]);
 assert.equal(result.complete,false);assert.deepEqual(result.requests,text.includes('functions:')?['file:///project/functions/custom.js']:[]);
 assert(result.issues.some(issue=>issue.code==='policy.dependencies.executable'));
 if(text.includes('functions:')){
  assert.equal(result.code[0].role,'function');assert.equal(result.code[0].name,'custom');
  assert.equal(result.code[0].resource,root);assert.equal(text.slice(...result.code[0].range),'custom');
 }
});

test('function declarations preserve the original approved URI base and occurrence without loading their code',()=>{
 const alias='https://rules.example/controlled/policy.yaml',uri='https://rules.example/controlled/own%20functions/custom.js';
 const definition=source(root,'functionsDir: ./own functions\nfunctions: [custom]\nrules: {}\n',[alias]);
 const body='throw Error("source-only discovery must never execute this");';
 const code=source('file:///mapped/custom.js',body,[uri]);
 const result=inspect([definition,code],[alias]);
 assert.equal(result.complete,false);assert.deepEqual(result.requests,[]);
 assert.deepEqual(result.code.map(value=>[value.uri,value.role,value.resource,value.pointer]),[[uri,'function',root,'/functions/0']]);
 assert.equal(code.text,body);assert(result.issues.every(issue=>issue.code==='policy.dependencies.executable'));
});
test('function declarations follow the pinned public string-list API without silently ignoring tuple options',()=>{
 const result=inspect([source(root,'functions: [[custom, {type: object}]]\nrules: {}\n')]);
 assert.equal(result.complete,false);
 assert(result.issues.some(issue=>issue.code==='policy.dependencies.configuration'&&issue.pointer==='/functions/0'));
 assert.deepEqual(result.requests,[]);assert.equal(result.code,undefined);
});

test('executable rulesets are never imported to discover transitive dependencies',()=>{
 const id='file:///project/custom.cjs';
 const text='throw new Error("discovery must not execute code");';
 const result=inspect([source(id,text)],[id]);
 assert.equal(result.complete,false);assert.deepEqual(result.requests,[]);
 assert.deepEqual(result.issues,[{resource:id,pointer:'',code:'policy.dependencies.executable'}]);
});

test('ruleset cycles are incomplete and cyclic data aliases retain the canonical parser refusal',()=>{
 const resources=[source(root,'extends: [./base.yaml]\n'),source(other,'extends: [./rules.yaml]\n')];
 const result=inspect(resources);assert.equal(result.complete,false);assert.deepEqual(result.requests,[]);
 assert(result.issues.some(issue=>issue.code==='policy.dependencies.cycle'));
 assert.throws(()=>inspect([source(root,'&self\noverrides: [*self]\nrules: {}\n')]),error=>error.code==='yaml.value');
});

test('declaration work is bounded, not truncated into a complete result',()=>{
 let value={rules:{}};for(let i=0;i<70;i++)value={overrides:[value]};
 assert.throws(()=>inspect([source(root,JSON.stringify(value))]),error=>error.code==='limit.depth');
 const broad={overrides:Array.from({length:256},()=>({overrides:Array.from({length:40},()=>({rules:{}}))}))};
 assert.throws(()=>inspect([source(root,JSON.stringify(broad))]),error=>error.code==='limit.policy.declarations');
 assert.throws(()=>inspect([source(root,JSON.stringify({overrides:Array.from({length:257},()=>({rules:{}}))}))]),error=>error.code==='limit.policy.overrides');
});

test('ambiguous executable/declarative aliases cannot pick the first resource',()=>{
 const alias='https://rules.example/policy';
 for(const resources of[
  [source(root,'rules: {}\n',[alias]),source(other.replace('.yaml','.cjs'),'module.exports={}',[alias])],
  [source(other.replace('.yaml','.cjs'),'module.exports={}',[alias]),source(root,'rules: {}\n',[alias])],
 ])assert.throws(()=>inspect(resources,[alias]),error=>error.code==='policy.identity');
});
