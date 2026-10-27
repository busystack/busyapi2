const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true]) {
 const root='file:///approved/root.'+(json?'json':'yaml');
 const run=value=>{const text=json?JSON.stringify(value):YAML.stringify(value);const input={root,snapshot:'relationships',resources:[{id:root,text,generation:1}]};const result=analyse(input);assert.equal(input.resources[0].text,text);return {result,text};};
 const api=()=>({openapi:version,info:{title:'Relationships',version:'1'},paths:{}});
 const label=version+' '+(json?'JSON':'YAML');
 test(`Server variable enum/default relationships are located and do not invent defaults ${label}`,()=>{
  const value=api();value.servers=[{url:'https://{region}.example.test',variables:{region:{default:'east',enum:['east','west']}}}];
  assert.equal(run(value).result.status,'complete');
  value.servers[0].variables.region.default='wrong';
  const {result,text}=run(value),finding=result.findings.find(f=>f.code==='server.variable.default-enum');
  assert.equal(result.status,'invalid');assert.equal(result.complete,true);assert.equal(finding.resource,root);assert.equal(finding.pointer,'/servers/0/variables/region/default');assert(text.slice(...finding.range).includes('wrong'));
  value.servers=[];assert.equal(run(value).result.status,'complete');delete value.servers;assert.equal(run(value).result.status,'complete');
 });
 test(`Server template syntax, names and query/fragment relationships follow the selected family ${label}`,()=>{
  const value=api();value.servers=[{...(version.startsWith('3.2')?{name:'prod'}:{}),url:'https://{猫}.example.test/{a?}',variables:{猫:{default:'demo'},'a?':{default:'v1'}}}];
  assert.equal(run(value).result.status,'complete');
  value.servers.push({...(version.startsWith('3.2')?{name:'prod'}:{}),url:'https://example.test/{region}/{region}?q=x#fragment',variables:{region:{default:'east'}}});
  const codes=new Set(run(value).result.findings.map(f=>f.code));
  for(const code of ['server.name.duplicate','server.variable.repeated'])assert.equal(codes.has(code),version.startsWith('3.2'),code);
  assert(codes.has('server.url.query-fragment'));
  value.servers=[{url:'https://example.test/{unfinished'}];
  assert.equal(run(value).result.findings.some(f=>f.code==='server.url.template'),version.startsWith('3.2'));
 });
 test(`Tag names retain exact case/Unicode and parent ambiguity/cycles never select a first target ${label}`,()=>{
  const value=api();value.tags=[{name:'é'},{name:'e\u0301'},{name:'Pets'},{name:'pets'}];
  assert.equal(run(value).result.status,'complete');
  value.tags=[{name:'same'},{name:'same'},...(version.startsWith('3.2')?[{name:'child',parent:'same'}]:[])];
  const duplicate=run(value).result;
  assert.equal(duplicate.findings.filter(f=>f.code==='tag.name.duplicate').length,2);
  if(version.startsWith('3.2')) {
   assert(duplicate.findings.some(f=>f.code==='tag.parent.ambiguous'));assert.equal(duplicate.complete,false);
   value.tags=[{name:'A',parent:'B'},{name:'B',parent:'A'},{name:'self',parent:'self'},{name:'missing',parent:'unknown'},{name:'root'},{name:'leaf',parent:'root'}];
   const result=run(value).result;
   assert.equal(result.findings.filter(f=>f.code==='tag.parent.cycle').length,3);assert(result.findings.some(f=>f.code==='tag.parent.missing'&&f.pointer==='/tags/3/parent'));assert.equal(result.status,'invalid');assert.equal(result.complete,true);
  }
 });
 test(`Root, Path Item, operation and payload contexts stay distinct ${label}`,()=>{
  const value=api();value.paths['/p']={servers:[{url:'../{version}',variables:{version:{default:'v1',enum:['v2']}}}],get:{summary:'Read',servers:[{url:'https://example.test/{variant}',variables:{variant:{default:'ok',enum:['ok']}}}],responses:{204:{description:'None'}}}};
  value['x-data']={servers:[{url:'invalid {',variables:{x:{default:'no',enum:['yes']}}}],tags:[{name:'same'},{name:'same'}]};
  const {result}=run(value);assert.equal(result.findings.filter(f=>f.code==='server.variable.default-enum').length,1);assert.equal(result.findings.find(f=>f.code==='server.variable.default-enum').pointer,'/paths/~1p/servers/0/variables/version/default');assert(!result.findings.some(f=>f.pointer.startsWith('/x-data')));
 });
}
test('3.2 URL-template literals follow actual ABNF code-point boundaries, not an ASCII-only URL guess',()=>{
 const root='file:///approved/template.json';
 for(const [character,valid]of [['a',true],['_',true],['~',true],['%20',true],['猫',true],['😀',true],['\ue000',true],['\u{e1000}',true],['\u{10fffd}',true],[' ',false],['"',false],['\\',false],['^',false],['`',false],['|',false],['%',false],['%xx',false],['}',false],['{}',false],['{a{b}',false],['\u007f',false],['\u009f',false],['\ud800',false],['\ufdd0',false],['\u{1fffe}',false],['\u{e0000}',false]]) {
  const value={openapi:'3.2.1',info:{title:'ABNF',version:'1'},paths:{},servers:[{url:'https://example.test/'+character}]};
  const result=analyse({root,snapshot:'abnf',resources:[{id:root,text:JSON.stringify(value),generation:1}]});
  assert.equal(!result.findings.some(f=>f.code==='server.url.template'),valid,JSON.stringify(character));
 }
});
test('an oversized Server template returns incomplete analysis, not a truncated clean result',()=>{
 const root='file:///approved/large-template.json',value={openapi:'3.2.1',info:{title:'Bounded',version:'1'},paths:{},servers:[{url:'https://example.test/'+ 'a'.repeat(65536)}]};
 const result=analyse({root,snapshot:'bounded-template',resources:[{id:root,text:JSON.stringify(value),generation:1}]});
 assert.equal(result.complete,false);assert.equal(result.status,'incomplete');assert(result.findings.some(f=>f.code==='limit.authoring.template'&&f.pointer==='/servers/0/url'));
});
for(const entryVersion of ['3.1.2','3.2.1'])test(`resource-owned Server versions and entry-owned Tag names stay distinct in a multi-file API ${entryVersion}`,()=>{
 const root='file:///approved/root.json',other='file:///approved/other.json',otherVersion=entryVersion.startsWith('3.1')?'3.2.1':'3.1.2';
 const entry={openapi:entryVersion,info:{title:'Entry',version:'1'},paths:{},tags:[{name:'EntryParent'}],components:{schemas:{Use:{$ref:'other.json#/components/schemas/Model'}}}};
 const external={openapi:otherVersion,info:{title:'Other',version:'1'},paths:{},servers:[{url:'https://example.test/plain'}],tags:otherVersion.startsWith('3.2')?[{name:'child',parent:'EntryParent'}]:[{name:'entry-independent'}],components:{schemas:{Model:{type:'string'}}}};
 const run=()=>analyse({root,snapshot:'multi-context',resources:[{id:root,text:JSON.stringify(entry),generation:1},{id:other,text:JSON.stringify(external),generation:2}]});
 assert.equal(run().status,'complete',JSON.stringify(run().findings));
 external.servers[0].url+='?forbidden=1';
 const invalid=run(),urlFinding=invalid.findings.find(f=>f.code==='server.url.query-fragment');
 assert.equal(invalid.status,'invalid');assert.equal(urlFinding.resource,other);assert.equal(urlFinding.pointer,'/servers/0/url');
 external.servers[0].url='https://example.test/plain';
 if(otherVersion.startsWith('3.2')) {
  external.tags.push({name:'own-only'});external.tags[0].parent='own-only';
  const result=run(),finding=result.findings.find(f=>f.code==='tag.parent.missing');
  assert.equal(finding.resource,other);assert.equal(finding.pointer,'/tags/0/parent');assert.equal(finding.root,root);
  entry.tags.push({name:'own-only'});assert.equal(run().status,'complete');
 }
});
