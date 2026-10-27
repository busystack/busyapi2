const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{referencePage,referenceDocument}=require('./dist/reference_projection.cjs');
const patches=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
for(const version of patches)for(const format of ['yaml','json'])test(`${version} ${format} Reference captures logical Markdown context without changing source`,()=>{
 const root='file:///private/api.'+format,logical='https://docs.example.invalid/original/api.'+format;
 const value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'雪',version:'1',description:'[Guide](../guide?zero=0&empty=)'},paths:{},'x-data':{description:'[Literal](../data)',n:'EXACT'}};
 const text=(format==='json'?JSON.stringify(value):'# Keep 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
 const input={root,snapshot:'markdown-'+version,resources:[{id:root,text,generation:3,aliases:[logical]}]};
 const analysis=analyse(input),page=referencePage({...input,resource:root,pointer:'/info'}),leaf=referencePage({...input,resource:root,pointer:'/info/description'}),section=referenceDocument(input).sections.find(s=>s.kind==='info');
 for(const source of [analysis.info,page,page.entries.find(e=>e.name==='description'),leaf,section.source,section.entries.find(e=>e.name==='description').source]){
  assert.equal(source.resource,root);assert.equal(source.markdownBase,logical);
  assert.equal(new URL('../guide?zero=0&empty=',source.markdownBase).href,'https://docs.example.invalid/guide?zero=0&empty=');
 }
 assert.equal(input.resources[0].text,text);
 const next={...input,snapshot:'changed',resources:[{...input.resources[0],aliases:['https://other.example.invalid/deep/api.'+format]}]};
 assert.equal(referencePage({...next,resource:root,pointer:'/info'}).markdownBase,next.resources[0].aliases[0]);
 assert.equal(referencePage({...input,resource:root,pointer:'/info'}).markdownBase,logical);
});
for(const version of patches.filter(v=>/^3\.[12]/.test(v)))for(const format of ['yaml','json'])test(`${version} ${format} schema identity and document identity retain distinct Markdown bases`,()=>{
 const root='file:///private/identity.'+format,retrieval='https://retrieval.example.invalid/api.'+format,self='https://identity.example.invalid/root/api.'+format,schema='https://schema.example.invalid/models/';
 const value={openapi:version,...(version.startsWith('3.2')?{$self:self}:{}),info:{title:'Identity',version:'1',description:'[Info](guide)'},paths:{},servers:[{url:'https://api.example.invalid',description:'[Server](guide)'}],components:{schemas:{Model:{$id:schema,type:'string',description:'[Schema](guide)'}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),input={root,snapshot:'identities',resources:[{id:root,text,generation:1,aliases:[retrieval]}]};
 const document=referenceDocument(input),base=version.startsWith('3.2')?self:retrieval;
 for(const [pointer,expected]of [['/info',base],['/servers/0',retrieval],['/components/schemas/Model',schema]]){
  const page=referencePage({...input,resource:root,pointer}),section=document.sections.find(s=>s.source.pointer===pointer);
  for(const source of [page,page.entries.find(e=>e.name==='description'),section.source,section.entries.find(e=>e.name==='description').source])assert.equal(source.markdownBase,expected,pointer);
 }
 assert.equal(input.resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])test(`${version} aliased descriptions retain each logical schema owner`,()=>{
 const root='file:///private/alias.yaml',text=`openapi: ${version}\ninfo: {title: Aliases, version: '1'}\npaths: {}\nx-text: &text '[Guide](guide)'\ncomponents:\n  schemas:\n    A:\n      $id: https://a.example.invalid/models/\n      type: string\n      description: *text\n    B:\n      $id: https://b.example.invalid/models/\n      type: string\n      description: *text\n`;
 const input={root,snapshot:'aliases',resources:[{id:root,text,generation:1}]},document=referenceDocument(input);
 for(const name of ['A','B']){
  const pointer='/components/schemas/'+name,page=referencePage({...input,resource:root,pointer}),section=document.sections.find(s=>s.source.pointer===pointer),field=section.entries.find(e=>e.name==='description');
  assert.equal(field.source.physicalPointer,'/x-text');assert.equal(field.source.markdownBase,`https://${name.toLowerCase()}.example.invalid/models/`);
  assert.equal(page.entries.find(e=>e.name==='description').markdownBase,field.source.markdownBase);
 }
 assert.equal(input.resources[0].text,text);
});

for(const version of patches)for(const format of ['yaml','json'])test(`${version} ${format} renderer coordinates keep an isolated display context`,()=>{
 const {referenceDisplay}=require('./dist/reference_display.cjs'),root='file:///private/original.'+format,outputId='https://busyapi-display.invalid/context/reference.json';
 const value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Isolated display',version:'1',description:'[Guide](guide)'},paths:{}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),result=referenceDisplay({root,snapshot:'display-context',resources:[{id:root,text,generation:1,aliases:['https://docs.example.invalid/original/api.'+format]}],outputId});
 const original=result.original.sections.find(s=>s.kind==='info'),display=result.projection.sections.find(s=>s.kind==='info');
 assert.equal(original.source.markdownBase,'https://docs.example.invalid/original/api.'+format);
 for(const source of [display.source,...display.entries.map(e=>e.source)])assert.equal(source.markdownBase,outputId);
 assert(!JSON.stringify(result.projection).includes('/private/'));
});
