const assert=require('node:assert/strict');
const {test}=require('node:test');
const path=require('node:path');
const YAML=require('yaml');
const dist=process.env.BUSYAPI_REVIEW_DIST||path.join(__dirname,'dist');
const {SourceDocument}=require(path.join(dist,'document.cjs'));
const {analyse,createGraph,propose}=require(path.join(dist,'model.cjs'));
const {evaluateSchemas}=require(path.join(dist,'schema_evaluation.cjs'));
const {planMoveDefinition,planInline}=require(path.join(dist,'refactoring_copy.cjs'));
const {planFileMove}=require(path.join(dist,'refactoring_file.cjs'));
const fixture=(version,json,extra={})=>{
 const root='file:///project/api/root.'+(json?'json':'yaml');
 const value={openapi:version,info:{title:'Integrity',version:'1'},paths:{},...extra};
 return {root,snapshot:'review',resources:[{id:root,generation:1,identity:'source',text:json?JSON.stringify(value):YAML.stringify(value)}]};
};
const apply=(text,plan)=>{
 for(const edit of [...plan.edits].sort((a,b)=>b.start-a.start)) {
  assert.equal(text.slice(edit.start,edit.end),edit.expected);
  text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
 }
 return text;
};

for(const version of ['3.1.2','3.2.1']) {
 for(const [before,raw] of [['!!str old','false'],['!!str old','123'],['!!int 1','2.5'],['!!str old','{"a":true}'],['!!seq [1]','false']])
  test(`tagged data preserves or rejects the requested JSON value ${version} ${before} -> ${raw}`,()=>{
   const input=fixture(version,false,{components:{schemas:{Model:{default:'TAGGED'}}}});
   const source=input.resources[0].text.replace('TAGGED',before);
   input.resources[0].text=source;
   const pointer='/components/schemas/Model/default';
   let result;
   try{result=propose({...input,target:{resource:input.root,pointer,generation:1},actions:[{kind:'setData',pointer,raw}]});}
   catch(error){assert.match(error.code,/^(edit\.|yaml\.)/);return;}
   const doc=new SourceDocument(apply(source,result),input.root);
   assert.deepEqual(JSON.parse(doc.dataJson(pointer)),JSON.parse(raw));
   assert.equal(doc.issues.length,0);
  });
 test(`invalid explicit YAML tag coercion is a located issue ${version}`,()=>{
  const doc=new SourceDocument('default: !!int 2.5\n','file:///project/value.yaml',true);
  assert(doc.issues.some(issue=>issue.code==='yaml.TAG_RESOLVE_FAILED'));
  assert.throws(()=>new SourceDocument(doc.text,doc.id),error=>error.code==='yaml.TAG_RESOLVE_FAILED');
  assert.throws(()=>new SourceDocument('default: !!str old\n',doc.id).set('/default',false),error=>error.code==='edit.tag');
 });
 for(const [before,raw]of [['!!str old','"new"'],['!!int 1','2'],['!!float 1.5','2.5'],['!!bool true','false']])
  test(`compatible explicit tags remain editable ${version} ${before}`,()=>{
   const input=fixture(version,false,{components:{schemas:{Model:{default:'TAGGED'}}}}),pointer='/components/schemas/Model/default';
   const text=input.resources[0].text.replace('TAGGED',before);input.resources[0].text=text;
   const plan=propose({...input,target:{resource:input.root,pointer,generation:1},actions:[{kind:'setData',pointer,raw}]});
   assert.deepEqual(JSON.parse(new SourceDocument(apply(text,plan),input.root).dataJson(pointer)),JSON.parse(raw));
  });
 test(`mapping key anchor rebinding preserves canonical data and source ${version}`,async()=>{
  const input=fixture(version,false),source=`openapi: ${version}\ninfo: {title: Anchors, version: "1"}\npaths: {}\nx-first: &name 42\nx-before: *name\ncomponents:\n  schemas:\n    &name Model:\n      type: string\n      examples: [*name]\nx-preserved: *name\n`;
  input.resources[0].text=source;
  const doc=new SourceDocument(source,input.root),key=source.indexOf('Model:');
  assert.equal(doc.dataJson('/x-before'),'42');
  assert.equal(doc.dataJson('/x-preserved'),'"Model"');
  assert.equal(doc.dataJson('/components/schemas/Model/examples/0'),'"Model"');
  assert.deepEqual(doc.dataLocation('/x-preserved').range,[key,key+5]);
  assert(doc.node('/components/schemas/Model').keyShared);
  const valueEdit=doc.set('/components/schemas/Model/description','Edited value');
  assert.equal(new SourceDocument(valueEdit,input.root).dataJson('/x-preserved'),'"Model"');
  const checked=await evaluateSchemas(input);
  assert.deepEqual(checked.evaluations.map(e=>e.valid),[true]);
  assert(!checked.findings.some(f=>f.code==='example.schema.incompatible'));
  assert.throws(()=>propose({...input,target:{resource:input.root,pointer:'/components/schemas/Model',generation:1},actions:[{kind:'rename',pointer:'/components/schemas/Model',name:'Renamed'}]}),error=>error.code==='edit.shared');
 });
 for(const json of [false,true]) {
  test(`an incompatible incoming reference preserves intrinsic schema validation ${version} ${json}`,async()=>{
   const input=fixture(version,json,{components:{schemas:{S:{type:'http',scheme:'bearer'}},securitySchemes:{Use:{$ref:'#/components/schemas/S'}}}});
   const graph=createGraph(input).graph;
   assert.equal(graph.scope(input.root,'/components/schemas/S').kind,'schema');
   assert(graph.issues.some(issue=>issue.code==='reference.target.context'));
   assert(analyse(input).findings.some(f=>f.code.startsWith('schema.')));
   const checked=await evaluateSchemas(input);
   assert(checked.schemas>0);
  });
  for(const location of ['component','media'])test(`null ${location} schema retains located analysis ${version} ${json}`,async()=>{
   const extra=location==='component'?{components:{schemas:{Model:null,Valid:{type:'string'}}}}:{paths:{'/':{get:{responses:{200:{description:'OK',content:{'application/json':{schema:null}}}}}}}};
   const input=fixture(version,json,extra),result=analyse(input);
   const pointer=location==='component'?'/components/schemas/Model':'/paths/~1/get/responses/200/content/application~1json/schema';
   assert(result.findings.some(f=>f.pointer===pointer&&f.severity==='error'));
   assert(result.findings.some(f=>f.code==='schema.type'&&f.pointer===pointer));
   assert((await evaluateSchemas(input)).findings.length>0);
  });
  for(const kind of ['responses','requestBodies'])test(`baseline rejects reference-only ${kind} cycles ${version} ${json}`,async()=>{
   const input=fixture(version,json,{components:{[kind]:{A:{$ref:`#/components/${kind}/B`},B:{$ref:`#/components/${kind}/A`}}}});
   const result=analyse(input),cycles=result.findings.filter(f=>f.code==='reference.cycle');
   assert.equal(cycles.length,2);
   assert(cycles.every(f=>f.pointer.endsWith('/$ref')&&f.range[1]>f.range[0]));
   assert((await evaluateSchemas(input)).findings.some(f=>f.code==='reference.cycle'));
   const valid=fixture(version,json,{components:{schemas:{Tree:{type:'object',properties:{child:{$ref:'#/components/schemas/Tree'}}}}}});
   assert(!analyse(valid).findings.some(f=>f.code==='reference.cycle'));
  });
  for(const ref of ['', '?revision=1'])test(`URN reference resolves by RFC 3986 ${version} ${json} ${JSON.stringify(ref)}`,async()=>{
   const input=fixture(version,json,{components:{schemas:{Tree:{$id:'urn:example:tree'+(ref?'?revision=1':''),type:'object',properties:{children:{type:'array',items:{$ref:ref}}},additionalProperties:false,examples:[{}, {children:[{}]}, {children:[42]}]}}}});
   assert(!analyse(input).findings.some(f=>f.code==='reference.uri'));
   const result=await evaluateSchemas(input);
   assert.equal(result.complete,true,JSON.stringify(result.findings));
   assert.deepEqual(result.evaluations.map(e=>e.valid),[true,true,false]);
  });
  test(`discriminator composition accepts adjacent and allOf child relationships ${version} ${json}`,async()=>{
   const model={type:'object',required:['kind'],properties:{kind:{type:'string'}},discriminator:{propertyName:'kind'},examples:[{kind:'x'}]};
   const standalone=fixture(version,json,{components:{schemas:{Model:model}}});
   assert(analyse(standalone).findings.some(f=>f.code==='discriminator.composition'&&f.pointer==='/components/schemas/Model/discriminator'));
   const evaluated=await evaluateSchemas(standalone);
   assert(evaluated.findings.some(f=>f.code==='discriminator.composition'));
   assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true]);
   for(const keyword of ['oneOf','anyOf','allOf']) {
    const input=fixture(version,json,{components:{schemas:{Model:{...model,[keyword]:[true]}}}});
    assert(!analyse(input).findings.some(f=>f.code==='discriminator.composition'));
   }
   const input=fixture(version,json,{components:{schemas:{Model:model,Child:{allOf:[{$ref:'#/components/schemas/Model'}],properties:{extra:{type:'string'}}}}}});
   assert(!analyse(input).findings.some(f=>f.code==='discriminator.composition'));
   assert(!(await evaluateSchemas(input)).findings.some(f=>f.code==='discriminator.composition'));
   const unrelated=fixture(version,json,{components:{schemas:{Model:model,Unrelated:{allOf:[true]}}}});
   assert(analyse(unrelated).findings.some(f=>f.code==='discriminator.composition'));
  });
 }
}

for(const anchored of ['item: &name current','&name current: item'])test(`replacing an anchored descendant cannot rebind unrelated aliases: ${anchored}`,()=>{
 const root='file:///project/root.yaml',text=`x-first: &name old\nvalue: {${anchored}}\nx-preserved: *name\n`;
 const doc=new SourceDocument(text,root),input={root,snapshot:'shared-subtree',resources:[{id:root,text,generation:1}],target:{resource:root,pointer:'/value',generation:1}};
 assert.throws(()=>doc.set('/value',false),error=>error.code==='edit.shared');
 assert.throws(()=>doc.remove('/value'),error=>error.code==='edit.shared');
 assert.throws(()=>propose({...input,actions:[{kind:'setData',pointer:'/value',raw:'false'}]}),error=>error.code==='edit.shared');
 assert.equal(doc.dataJson('/x-preserved'),'"current"');
});
test('data edits compare mapping meaning independently of member order and retain exact decimals',()=>{
 const root='file:///project/root.yaml',text='value: {a: 9007199254740993.00, b: true}\n',pointer='/value';
 const input={root,snapshot:'order',resources:[{id:root,text,generation:1}],target:{resource:root,pointer,generation:1}};
 const plan=propose({...input,actions:[{kind:'setData',pointer,raw:'{"b":false,"a":9007199254740993.00}'}]});
 const doc=new SourceDocument(apply(text,plan),root);
 assert.equal(doc.dataJson(pointer),'{"a":9007199254740993.00,"b":false}');
});

for(const description of ['[Manual][m]\n\n[m]: guide.md','[Manual][]\n\n[Manual]: <guide.md> "Title"','[Manual]\n\n[manual]: guide.md','![Image][m]\n\n[m]: image.png','[Manual](guide.md)','[Manual][m]\n\n[m]: &#103;uide.md'])
 test(`cross-file operations protect rendered Markdown destinations: ${description.split('\n')[0]}`,()=>{
  const input=fixture('3.2.1',true,{components:{schemas:{Model:{type:'string',description}}}});
  const destination='file:///project/defs/models.json',target={id:destination,text:'{"openapi":"3.2.1","info":{"title":"Models","version":"1"},"paths":{}}',generation:1};
  const resources=[...input.resources,target],contexts=[{root:input.root,resources:resources.map(r=>r.id)}];
  assert.throws(()=>planMoveDefinition({...input,resources,contexts,target:{resource:input.root,pointer:'/components/schemas/Model',generation:1},destinationResource:destination,name:'Moved'}),error=>error.code==='refactor.copy.uri-context');
  assert.throws(()=>planFileMove({...input,contexts:[{root:input.root,resources:[input.root]}],target:{resource:input.root,generation:1},destinationResource:destination}),error=>error.code==='file.move.documentation');
  const use={...target,text:JSON.stringify({openapi:'3.2.1',info:{title:'Use',version:'1'},paths:{},components:{schemas:{Use:{$ref:'../api/root.json#/components/schemas/Model'}}}})};
  assert.throws(()=>planInline({...input,resources:[input.resources[0],use],contexts:[{root:destination,resources:[input.root,destination]}],target:{root:destination,resource:destination,pointer:'/components/schemas/Use',generation:1}}),error=>error.code==='refactor.inline.uri-context');
 });
for(const description of ['`[Manual](guide.md)`','[Manual][m]\n\n[m]: https://example.com/guide.md','[Manual](#section)','````\n[Manual][m]\n\n[m]: guide.md\n````'])
 test(`Markdown guard permits base-independent text: ${description.split('\n')[0]}`,()=>{
  const input=fixture('3.2.1',true,{components:{schemas:{Model:{type:'string',description}}}});
  const result=planFileMove({...input,contexts:[{root:input.root,resources:[input.root]}],target:{resource:input.root,generation:1},destinationResource:'file:///project/defs/root.json'});
  assert(result.file);
 });
