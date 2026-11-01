const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {SourceDocument}=require('./dist/document.cjs');

const fixtures=[
 '&root\n# literal &decoy stays a comment\nvalue: 9007199254740993.00\n',
 'value: &same {type: string}\ncopy: *same\n',
 'value: &same\n  type: string\ncopy: *same\n',
 'items: [ &same {type: string}, *same ]\n',
 'items:\n  - &same\n    type: string\n  - *same\n',
 'mapping: {&key literal: &value 0}\nkey-copy: *key\nvalue-copy: *value\n',
 'value: &same |- # retained block comment\n  café 雪\n  &literal\ncopy: *same\n',
 'value: &same\ncopy: *same\n',
 'first: &same "first"\nfirst-copy: *same\nsecond: &same "second"\nsecond-copy: *same\n',
 'value: !!str &same 12\ncopy: *same\n',
];
for(const [index,text]of fixtures.entries())test(`captured YAML property tokens retain pinned parser behavior ${index}`,()=>{
 const doc=new SourceDocument(text,'file:///source-tokens/model.yaml');
 const expected=YAML.parseDocument(text,{version:'1.2',schema:'core',keepSourceTokens:true,uniqueKeys:true,stringKeys:true,strict:true,prettyErrors:false});
 assert.deepEqual(doc.root.value,expected.toJS({maxAliasCount:64}));
 assert(doc.sourceAnchors().length>0);
 for(const anchor of doc.sourceAnchors()){
  assert(anchor.range,'Every fixture anchor needs an actual property token');
  assert.equal(text.slice(...anchor.range),'&'+anchor.name);
 }
 if(index===8){assert.equal(doc.dataNode('/first-copy').value,'first');assert.equal(doc.dataNode('/second-copy').value,'second');}
 if(index===0)assert.equal(doc.dataJson('/value'),'9007199254740993.00');
 const shared=[...doc.nodes.values()].find(node=>node.shared&&node.pointer!=='');
 assert.throws(()=>doc.set(shared?.pointer??'',null),error=>error.code==='edit.shared');
 assert.equal(doc.text,text);
});
for(const [text,code]of [
 ['value: &same 1\n---\nother: 2\n','yaml.MULTIPLE_DOCS'],
 ['value: 1\nvalue: 2\n','yaml.DUPLICATE_KEY'],
 ['value: *missing\n','yaml.alias'],
 ['value: &cycle {next: *cycle}\n','yaml.alias.cycle'],
])test(`captured YAML still rejects ${code}`,()=>{
 assert.throws(()=>new SourceDocument(text,'file:///source-tokens/invalid.yaml'),error=>
  error.code===code||code==='yaml.alias.cycle'&&['yaml.alias','yaml.value'].includes(error.code));
});
