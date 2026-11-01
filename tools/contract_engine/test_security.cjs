const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const github='ghp_'+Array.from({length:36},(_,i)=>'aB3cD5eF7gH9kL2mN4pQ6rS8tU0vW1xY'[i%32]).join('');
const run=(value,json=true,extras=[])=>{
 const id='file:///p/root.'+(json?'json':'yaml');
 return {id,text:json?JSON.stringify(value):YAML.stringify(value),result:analyse({root:id,snapshot:'snapshot',resources:[{id,text:json?JSON.stringify(value):YAML.stringify(value),generation:1,identity:'root'},...extras]})};
};
for(const openapi of ['3.1.2','3.2.1'])for(const json of [false,true]) {
 test(`static security ${openapi} ${json?'JSON':'YAML'} masks uncertain findings at original values`,()=>{
  const value={openapi,info:{title:'Security',version:'1'},paths:{'/p':{get:{responses:{200:{description:'OK',content:{'application/json':{example:{password:'aB3cD5eF7gH9kL2mN4pQ6rS8tU0vW1xY',key:github,$ref:'literal data'}}}}}}}},'x-url':'https://user:private@host.invalid/path?access_token='+github};
  const {id,text,result}=run(value,json);
  const findings=result.findings.filter(f=>f.category==='security');
  assert.equal(result.status,'complete');assert.equal(result.categories.security.complete,true);
  assert.equal(result.categories.policy.status,'not-run');assert.equal(result.categories.runtime.status,'not-implemented');
  assert(findings.some(f=>f.code==='security.credential-like.github'));assert(findings.some(f=>f.code==='security.credential-like.opaque'));
  assert(findings.some(f=>f.code==='security.uri.credentials'));assert(findings.some(f=>f.code==='security.uri.credential-like-query'));
  for(const finding of findings) {
   assert.equal(finding.resource,id);assert.equal(finding.snapshot,'snapshot');assert.equal(finding.producer,'busyapi-security-design');
   assert.equal(finding.confidence,'advisory');assert(!JSON.stringify(finding).includes(github));assert(!JSON.stringify(finding).includes('user:private'));
   assert(finding.range[1]>finding.range[0]);assert(text.slice(...finding.range).includes(finding.code.includes('opaque')?'aB3c':finding.code.startsWith('security.uri.')?'https':github));
  }
  assert.equal(result.references.length,0);assert(text.includes(github));
 });
 test(`intentional public declarations, Basic and illustrative local values remain valid ${openapi} ${json}`,()=>{
  const value={openapi,info:{title:'Public',version:'1'},servers:[{url:'http://localhost:8080'}],security:[],components:{securitySchemes:{Basic:{type:'http',scheme:'basic'}}},paths:{'/public':{get:{security:[{}],responses:{204:{description:'No body'}}},post:{security:[],responses:{200:{description:'OK',content:{'application/json':{example:{password:'example-not-a-real-password-123',apiKey:'<YOUR_TOKEN>'}}}}}}}}};
  const {result}=run(value,json);assert.equal(result.status,'complete');assert.deepEqual(result.findings,[]);
 });
}
test('mixed implicit public access is advice, not invalidity; explicit anonymous overrides are deliberate',()=>{
 const value={openapi:'3.2.1',info:{title:'Mixed',version:'1'},components:{securitySchemes:{Key:{type:'apiKey',name:'X-Key',in:'header'}}},paths:{'/p':{
  get:{security:[{Key:[]}],responses:{204:{description:'OK'}}},
  post:{responses:{204:{description:'Public'}}},
  put:{security:[],responses:{204:{description:'Public'}}},
  delete:{security:[{}],responses:{204:{description:'Public'}}},
 }}};
 const {result}=run(value);const advice=result.findings.filter(f=>f.code==='security.declaration.implicit-public');
 assert.equal(result.status,'complete');assert.equal(advice.length,1);assert.equal(advice[0].pointer,'/paths/~1p/post');assert.equal(advice[0].severity,'information');
});
test('secret-like keys and duplicate-key messages are masked without hiding source ranges',()=>{
 const id='file:///p/root.json';const text='{"openapi":"3.2.1","info":{"title":"Keys","version":"1"},"paths":{},"x-data":{"'+github+'":"first","'+github+'":"second"}}';
 const result=analyse({root:id,snapshot:'keys',resources:[{id,text,generation:1,identity:'keys'}]});
 assert.equal(result.status,'invalid');const duplicate=result.findings.find(f=>f.code==='duplicate.key');
 assert(duplicate.masked);assert(!JSON.stringify(result.findings).includes(github));assert(text.slice(...duplicate.range).includes(github));
 const keyFinding=result.findings.find(f=>f.category==='security');assert(keyFinding.pointerRedacted);assert.equal(keyFinding.pointer,'/x-data');assert(text.slice(...keyFinding.range).includes(github));
});
test('unavailable dependencies and bounded work cannot return complete security inspection',()=>{
 const {result}=run({openapi:'3.2.1',info:{title:'Unapproved',version:'1'},paths:{},components:{schemas:{Model:{$ref:'https://not-approved.invalid/model'}}}});
 assert.equal(result.categories.security.complete,false);assert.equal(result.status,'incomplete');
 const many=Object.fromEntries(Array.from({length:230},(_,i)=>['key'+i,github]));
 const limited=run({openapi:'3.2.1',info:{title:'Bounded',version:'1'},paths:{},'x-data':many}).result;
 assert.equal(limited.status,'incomplete');assert.equal(limited.categories.security.complete,false);
 assert(limited.findings.some(f=>f.code==='security.limit'));assert(limited.findings.length<=201);
});
test('current token families and key identifiers remain uncertain and masked without validation calls',()=>{
 const jwt='eyJ'+('aB3cD5eF7gH9kL2m'.repeat(2))+'.'+('aB3cD5eF7gH9kL2m'.repeat(2))+'.'+('aB3cD5eF7gH9kL2m'.repeat(2));
 const values={fine:'github_pat_'+('aB3cD5eF7gH9kL2m'.repeat(4)),installation:'ghs_12345_'+jwt,jwt:'Bearer '+jwt,accessKeyId:'ASIA'+'AB2CDE3FG4HI5JKL',secretAccessKey:'aB3cD5eF7gH9kL2mN4pQ6rS8tU0vW1xY',placeholder:'AKIAIOSFODNN7EXAMPLE'};
 const {result}=run({openapi:'3.2.1',info:{title:'Token shapes',version:'1'},paths:{},'x-values':values});
 const findings=result.findings.filter(f=>f.category==='security');assert.equal(result.status,'complete');
 assert.equal(findings.filter(f=>f.code==='security.credential-like.github').length,2);assert(findings.some(f=>f.code==='security.credential-like.jwt'));
 const aws=findings.find(f=>f.code==='security.credential-like.aws');assert.equal(aws.severity,'information');assert(aws.message.includes('identifier alone'));
 assert(!findings.some(f=>f.pointer.endsWith('/placeholder')));
 for(const finding of findings)assert.equal(finding.masked,true);
 const report=JSON.stringify(findings);for(const value of Object.values(values))assert(!report.includes(value));
});
test('long adversarial token-like text reaches a bounded limit instead of unsafe pattern execution',()=>{
 const value='https://host.invalid/?'+('-eyJ'.repeat(20000));
 const {result}=run({openapi:'3.2.1',info:{title:'Bounded URIs',version:'1'},paths:{},'x-value':value});
 assert.equal(result.status,'incomplete');assert.equal(result.categories.security.complete,false);assert(result.findings.some(f=>f.code==='security.limit'));
});
test('routine parser messages mask URI/token data and escape controls without masking ordinary words',()=>{
 const id='file:///p/root.json';
 const diagnostic=key=>{
  const encoded=JSON.stringify(key);
  const text='{"openapi":"3.2.1","info":{"title":"Messages","version":"1"},"paths":{},"x-data":{'+encoded+':"one",'+encoded+':"two"}}';
  return analyse({root:id,snapshot:'messages',resources:[{id,text,generation:1,identity:'s'}]}).findings.find(f=>f.code==='duplicate.key');
 };
 const jwt='eyJ'+'aB3cD5eF7gH9kL2m'.repeat(2)+'.'+'aB3cD5eF7gH9kL2m'.repeat(2)+'.'+'aB3cD5eF7gH9kL2m'.repeat(2);
 const uri='https://host.invalid/?access_token='+jwt;
 assert(!JSON.stringify(diagnostic(uri)).includes(jwt));assert(diagnostic(uri).masked);
 assert(diagnostic('monkeyJoke').message.includes('monkeyJoke'));
 const controls=diagnostic('unsafe\u001bcontrol\u202edirection');
 assert(!controls.message.includes('\u001b'));assert(!controls.message.includes('\u202e'));
 assert(controls.message.includes('\\u001b'));assert(controls.message.includes('\\u202e'));
});
