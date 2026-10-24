const assert=require('node:assert/strict');
const {test}=require('node:test');
const path=require('node:path');
const YAML=require('yaml');
const dist=process.env.BUSYAPI_REVIEW_DIST||path.join(__dirname,'dist');
const {SourceDocument}=require(path.join(dist,'document.cjs'));
const {analyse,createGraph}=require(path.join(dist,'model.cjs'));
const {evaluateSchemas}=require(path.join(dist,'schema_evaluation.cjs'));
const {planInline}=require(path.join(dist,'refactoring_copy.cjs'));

const fixture=(version,json,extra)=>{
 const root='file:///project/root.'+(json?'json':'yaml');
 const value={openapi:version,info:{title:'Follow-up',version:'1'},paths:{},...extra};
 return {root,snapshot:'follow-up',resources:[{id:root,text:json?JSON.stringify(value):YAML.stringify(value),generation:1}]};
};
const parent=()=>({type:'object',required:['kind'],properties:{kind:{type:'string'}},discriminator:{propertyName:'kind'}});

for(const version of ['3.1.2','3.2.1']) {
 for(const kind of ['schemas','responses'])for(const anchor of ['key','value'])
  test(`inline guards anchored reference ${anchor} descendants ${version} ${kind}`,()=>{
   const root='file:///project/root.yaml',pointer='/components/'+kind+'/Use';
   const definition=kind==='schemas'?'type: string':'description: OK';
   const ref=anchor==='key'?`&name $ref: '#/components/${kind}/Target'`:`$ref: &name '#/components/${kind}/Target'`;
   const text=`openapi: ${version}\ninfo: {title: Anchors, version: "1"}\npaths: {}\nx-first: &name earlier\ncomponents:\n  ${kind}:\n    Target: {${definition}}\n    Use: {${ref}}\nx-preserved: *name\n`;
   const input={root,snapshot:'inline-anchor',resources:[{id:root,text,generation:1}]},doc=new SourceDocument(text,root);
   assert.deepEqual(analyse(input).findings,[]);
   const wanted=doc.dataJson('/x-preserved');
   assert.throws(()=>doc.set(pointer,kind==='schemas'?{type:'string'}:{description:'OK'}),error=>error.code==='edit.shared');
   assert.throws(()=>planInline({...input,contexts:[{root,resources:[root]}],target:{root,resource:root,pointer,generation:1}}),error=>error.code==='edit.shared');
   assert.equal(input.resources[0].text,text);
   assert.equal(new SourceDocument(input.resources[0].text,root).dataJson('/x-preserved'),wanted);
  });
 test(`inline preserves an anchor on the occurrence's containing key ${version}`,()=>{
  const root='file:///project/root.yaml',pointer='/components/schemas/Use';
  const text=`openapi: ${version}\ninfo: {title: Anchors, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Target: {type: string}\n    &name Use: {$ref: '#/components/schemas/Target'}\nx-preserved: *name\n`;
  const input={root,snapshot:'inline-owner-key',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,pointer,generation:1}};
  const plan=planInline(input);let changed=text;
  for(const edit of [...plan.edits].sort((a,b)=>b.start-a.start))changed=changed.slice(0,edit.start)+edit.replacement+changed.slice(edit.end);
  const doc=new SourceDocument(changed,root);
  assert.equal(doc.dataJson('/x-preserved'),'"Use"');
  assert.deepEqual(doc.node(pointer).value,{type:'string'});
 });

 for(const json of [false,true]) {
  for(const spelling of ['pointer','anchor','dynamic-anchor-pointer'])
   test(`static-equivalent dynamic references establish allOf parent relationships ${version} ${json} ${spelling}`,async()=>{
    const model=parent();
    if(spelling==='anchor')model.$anchor='parent';
    if(spelling==='dynamic-anchor-pointer')model.$dynamicAnchor='parent';
    const ref=spelling==='anchor'?'#parent':'#/components/schemas/Parent';
    const input=fixture(version,json,{components:{schemas:{Parent:model,Child:{allOf:[{$dynamicRef:ref}]}}}});
    const edge=createGraph(input).graph.references.find(ref=>ref.keyword==='$dynamicRef');
    assert.equal(edge.resolution,'resolved');assert.equal(edge.dynamic,undefined);
    assert(!analyse(input).findings.some(f=>f.code==='discriminator.composition'));
    assert(!(await evaluateSchemas(input)).findings.some(f=>f.code==='discriminator.composition'));
   });
  for(const name of ['allOf','renamed'])
   test(`a literal ${name} key cannot establish a composition owner ${version} ${json}`,async()=>{
    const pointer='/components/schemas/Data/const/'+name+'/0';
    const input=fixture(version,json,{components:{schemas:{Parent:parent(),Data:{const:{[name]:[{$ref:'#/components/schemas/Parent'}]}},Use:{$ref:'#'+pointer}}}});
    const graph=createGraph(input).graph;
    assert.equal(graph.scope(input.root,pointer).kind,'schema');
    assert.notEqual(graph.scopes.get(input.root+'#/components/schemas/Data/const')?.kind,'schema');
    assert(analyse(input).findings.some(f=>f.code==='discriminator.composition'&&f.pointer==='/components/schemas/Parent/discriminator'));
    assert((await evaluateSchemas(input)).findings.some(f=>f.code==='discriminator.composition'&&f.pointer==='/components/schemas/Parent/discriminator'));
   });
  test(`literal data explicitly reused as a whole schema owns its allOf ${version} ${json}`,async()=>{
   const input=fixture(version,json,{components:{schemas:{Parent:parent(),Data:{const:{allOf:[{$dynamicRef:'#/components/schemas/Parent'}]}},Use:{$ref:'#/components/schemas/Data/const'}}}});
   const graph=createGraph(input).graph;
   assert.equal(graph.scope(input.root,'/components/schemas/Data/const').kind,'schema');
   assert(!analyse(input).findings.some(f=>f.code==='discriminator.composition'));
   assert(!(await evaluateSchemas(input)).findings.some(f=>f.code==='discriminator.composition'));
  });
  test(`both static applicators contribute parent relationships ${version} ${json}`,()=>{
   const input=fixture(version,json,{components:{schemas:{First:parent(),Second:parent(),Child:{allOf:[{$ref:'#/components/schemas/First',$dynamicRef:'#/components/schemas/Second'}]}}}});
   assert(!analyse(input).findings.some(f=>f.code==='discriminator.composition'));
  });
  test(`genuinely dynamic targets do not establish a static parent relationship ${version} ${json}`,()=>{
   const model={...parent(),$dynamicAnchor:'parent'};
   const input=fixture(version,json,{components:{schemas:{Parent:model,Override:{$id:'urn:override',$dynamicAnchor:'parent',type:'object'},Child:{allOf:[{$dynamicRef:'#parent'}]}}}});
   const edge=createGraph(input).graph.references.find(ref=>ref.keyword==='$dynamicRef');
   assert(edge.dynamic);assert.equal(edge.dynamic.candidates.length,2);
   assert(analyse(input).findings.some(f=>f.code==='discriminator.composition'&&f.pointer==='/components/schemas/Parent/discriminator'));
  });
 }
}
