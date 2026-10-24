const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {analyse,createGraph}=require('./dist/model.cjs');
const {referencePage,referenceDocument}=require('./dist/reference_projection.cjs');
const {governanceProjection}=require('./dist/governance_projection.cjs');
const {referenceDisplay}=require('./dist/reference_display.cjs');

for(const version of ['3.1.2','3.2.1'])for(const json of [false,true]) {
 const modern=version.startsWith('3.2'),suffix=json?'json':'yaml',root='file:///approved/root.'+suffix,part='file:///approved/part.'+suffix;
 const operation=modern?'/additionalOperations/COPY':'/get';
 function input(overlap=false) {
  const shared={operationId:'shared',summary:'Shared operation',responses:{204:{description:'Intentionally bodyless'}}};
  const definition=modern?{additionalOperations:{COPY:shared}}:{get:shared};
  if(overlap)definition.parameters=[];
  const path=name=>({$ref:'part.'+suffix+'#/Shared',servers:[{url:'https://'+name+'.invalid'}],parameters:[{name:'id',in:'path',required:true,description:name+' parameter owner',schema:{type:'string'}}]});
  const first={openapi:version,info:{title:'Located Path Items',version:'1'},paths:{'/one/{id}':path('one'),'/two/{id}':path('two'),'/local':{$ref:'part.'+suffix+'#/Read',post:{summary:'Local operation',responses:{204:{description:'No body'}}}}},'x-literal':{$ref:'payload only',get:{responses:{200:{description:'Not an operation'}}},exact:111}};
  const other={Shared:definition,Read:{get:{summary:'Read operation',responses:{204:{description:'Read without body'}}}}};
  const render=value=>json?JSON.stringify(value).replace('111','9007199254740993.00'):'# exact 雪😀\r\n'+YAML.stringify(value).replace('111','9007199254740993.00');
  return {root,snapshot:'path-context-'+version+'-'+suffix,resources:[{id:root,text:render(first),generation:3},{id:part,text:render(other),generation:4}]};
 }
 test(`disjoint Path Item fields retain every operation and exact field owner ${version} ${suffix}`,()=>{
  const captured=input(),before=captured.resources.map(resource=>resource.text),result=analyse(captured);
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.status,'complete');
  assert.equal(result.operations.length,4);
  assert.deepEqual(result.operations.map(operation=>[operation.path,operation.method]),[['/one/{id}',modern?'COPY':'get'],['/two/{id}',modern?'COPY':'get'],['/local','post'],['/local','get']]);
  const {graph}=createGraph(captured),view=graph.pathItem({resource:root,pointer:'/paths/~1one~1{id}',kind:'path-item'});
  assert.equal(view.complete,true);assert.equal(view.chain.length,2);
  assert.deepEqual(view.fields.get('parameters'),{resource:root,pointer:'/paths/~1one~1{id}/parameters',kind:'parameter-array'});
  assert.equal(view.fields.get(modern?'additionalOperations':'get').resource,part);
  assert.deepEqual(captured.resources.map(resource=>resource.text),before);
 });
 test(`a shared Operation's effective values use the selected occurrence, not one global parent ${version} ${suffix}`,async()=>{
  const captured=input(),{graph}=createGraph(captured),pointer='/Shared'+operation;
  for(const name of ['one','two']) {
   const path='/paths/~1'+name+'~1{id}',occurrence=root+'#'+path+operation;
   const page=referencePage({...captured,resource:part,pointer,occurrence});
   assert.equal(page.complete,true);
   assert.equal(page.effective.find(field=>field.name==='parameters').entries.length,1);
   assert.equal(page.effective.find(field=>field.name==='parameters').entries[0].source.resource,root);
   assert.equal(page.effective.find(field=>field.name==='servers').source.pointer,path+'/servers');
   assert.equal(page.effective.find(field=>field.name==='parameters').entries[0].source.pointer,path+'/parameters/0');
  }
  const physical=referenceDocument(captured).sections.find(section=>section.source.resource===part&&section.source.pointer===pointer);
  assert.equal(physical.contexts.length,2);
  assert.deepEqual(physical.contexts.map(context=>context.occurrence).sort(),['one','two'].map(name=>root+'#/paths/~1'+name+'~1{id}'+operation).sort());
  const output='https://display.invalid/reference.json',display=referenceDisplay({...captured,outputId:output});
  const presented=display.projection.sections.find(section=>section.kind==='operation'&&section.contexts?.length===2);
  assert(presented);assert.equal(presented.effective.length,0,'A physical definition does not choose one inherited context globally');
  assert(presented.contexts.every(context=>context.occurrence.startsWith(output+'#')&&context.pathItem.resource===output&&context.effective.every(field=>!field.source||field.source.resource===output)));
  assert(!JSON.stringify(display.projection).includes(root),'Private physical entry identities stay with the native owner');
  const {graphAddressedDisplay,presentationSection}=await import('../documentation_renderers/graph_display.mjs');
  const renderer=graphAddressedDisplay(display.output.text,display.projection,'https://display.invalid/index.html',{addresses:'document-pointer'});
  for(const name of ['one','two']) {
   const logical='/paths/~1'+name+'~1{id}'+operation;
   const section=presentationSection(renderer,logical,{followReference:true,occurrence:logical});
   assert.equal(section.effective.find(field=>field.name==='servers').source.pointer,'/paths/~1'+name+'~1{id}/servers');
  }
  assert.throws(()=>presentationSection(renderer,'/paths/~1one~1{id}'+operation,{followReference:true,occurrence:'/paths/~1missing/get'}),/operation-context/);
  const neutral=referencePage({...captured,resource:part,pointer});
  assert.equal(neutral.occurrence,null);assert.equal(neutral.contextSelectionRequired,true);assert.deepEqual(neutral.effective,[]);
  const definition=referencePage({...captured,resource:part,pointer,definitionOnly:true,occurrence:'removed'});
  assert.equal(definition.contextSelectionRequired,true);assert.deepEqual(definition.effective,[]);
  assert.throws(()=>referencePage({...captured,resource:part,pointer,occurrence:root+'#/paths/~1removed/get'}),error=>error.code==='reference.occurrence');
 });
 test(`resolved governance uses the same disjoint owners and never resolves payload keys ${version} ${suffix}`,()=>{
  const captured=input(),{graph}=createGraph(captured),projection=governanceProjection(graph,true);
  assert.deepEqual(projection.problems,[]);
  const method=modern?'additionalOperations':'get';
  assert.equal(projection.value.paths['/one/{id}'][method]!==undefined,true);
  assert.equal(projection.value.paths['/local'].post.summary,'Local operation');assert.equal(projection.value.paths['/local'].get.summary,'Read operation');
  assert.equal(projection.value['x-literal'].$ref,'payload only');
  assert.equal(projection.origins.get('/paths/~1one~1{id}/servers').resource,root);
  assert.equal(projection.origins.get('/paths/~1one~1{id}'+operation).resource,part);
 });
 test(`overlapping fields stay precisely incomplete with both source locations, not first-wins ${version} ${suffix}`,()=>{
  const captured=input(true),{graph}=createGraph(captured),view=graph.pathItem({resource:root,pointer:'/paths/~1one~1{id}',kind:'path-item'});
  assert.equal(view.complete,false);assert.equal(view.fields.has('parameters'),false);
  const overlaps=graph.issues.filter(issue=>issue.code==='path.reference.overlap');
  assert(overlaps.some(issue=>issue.resource===root&&issue.pointer==='/paths/~1one~1{id}/parameters'));
  assert(overlaps.some(issue=>issue.resource===part&&issue.pointer==='/Shared/parameters'));
  const result=analyse(captured);assert.equal(result.complete,false);assert(result.findings.some(finding=>finding.code==='path.reference.overlap'&&finding.severity==='warning'));
  assert(!result.findings.some(finding=>finding.code==='parameter.path.missing'),'Unknown inheritance must not invent a missing declaration');
 });
}

test('all logical contexts are paged and a selection outside the page keeps its own complete inherited values',()=>{
 const root='file:///approved/many.json',method='/get',pointer='/components/pathItems/Shared/get';
 const value={openapi:'3.2.1',info:{title:'Many contexts',version:'1'},servers:[{url:'https://global.invalid'}],paths:{},components:{pathItems:{Shared:{get:{summary:'One physical operation',responses:{204:{description:'Bodyless'}}}},Unused:{post:{responses:{204:{description:'Unused'}}}}}}};
 for(let n=0;n<123;n++)value.paths['/path-'+n]={$ref:'#/components/pathItems/Shared',servers:[{url:'https://owner-'+n+'.invalid'}]};
 const input={root,snapshot:'many-contexts',resources:[{id:root,text:JSON.stringify(value),generation:0}]},occurrence=root+'#/paths/~1path-122'+method;
 const all=[];
 for(const offset of [0,50,100]) {
  const page=referencePage({...input,resource:root,pointer,contextOffset:offset,occurrence});
  assert.equal(page.contextCount,123);assert.equal(page.contextOffset,offset);assert.equal(page.selectedContext.occurrence,occurrence);
  assert.equal(page.effective.find(field=>field.name==='servers').source.pointer,'/paths/~1path-122/servers');
  assert.equal(page.contexts.length,offset===100?23:50);all.push(...page.contexts);
 }
 assert.equal(new Set(all.map(context=>context.occurrence)).size,123);
 assert.equal(new Set(all.map(context=>context.navigationId)).size,123);
 const summary=({pathItem,effective,...value})=>({...value,pathItem:{resource:pathItem.resource,pointer:pathItem.pointer,range:pathItem.range,generation:pathItem.generation}});
 assert.deepEqual(all.map(summary),referenceDocument(input).sections.find(section=>section.source.pointer===pointer).contexts.map(summary));
 const unused=referencePage({...input,resource:root,pointer:'/components/pathItems/Unused/post'});
 assert.equal(unused.contextCount,0);assert.equal(unused.contextSelectionRequired,false);assert.deepEqual(unused.effective,[],'An unused definition has no global inherited server/security context');
});

test('unavailable Path Item inheritance stays incomplete even when a local list is known; unrelated overlap does not erase safe parameters',()=>{
 const root='file:///approved/root.json';
 const operation={responses:{204:{description:'No body'}}};
 const value={openapi:'3.2.1',info:{title:'Progressive scopes',version:'1'},paths:{'/p/{id}':{$ref:'unapproved.json#/Item',servers:[{url:'https://known.invalid'}],parameters:[{in:'path',name:'id',required:true,schema:{type:'string'}}],get:operation}}};
 const input=()=>({root,snapshot:'partial',resources:[{id:root,text:JSON.stringify(value),generation:0}]});
 let page=referencePage({...input(),resource:root,pointer:'/paths/~1p~1{id}/get',occurrence:root+'#/paths/~1p~1{id}/get'});
 assert.equal(page.effective.find(field=>field.name==='servers').complete,false);
 assert.equal(page.effective.find(field=>field.name==='parameters').complete,false);
 assert.equal(page.effective.find(field=>field.name==='parameters').entries.length,1);
 assert(!analyse(input()).findings.some(finding=>finding.code==='parameter.path.missing'));
 value.paths['/p/{id}'].$ref='#/components/pathItems/Server';
 value.components={pathItems:{Server:{servers:[{url:'https://different.invalid'}]}}};
 page=referencePage({...input(),resource:root,pointer:'/paths/~1p~1{id}/get',occurrence:root+'#/paths/~1p~1{id}/get'});
 assert.equal(page.effective.find(field=>field.name==='servers').complete,false);
 assert.equal(page.effective.find(field=>field.name==='parameters').complete,true);
 assert.equal(page.effective.find(field=>field.name==='parameters').entries[0].name,'id');
});

test('YAML aliases retain logical operation contexts and exact physical provenance without granting virtual edit ownership',()=>{
 const root='file:///approved/aliases.yaml',text='openapi: 3.2.1\ninfo: {title: Aliases, version: "1"}\nx-operation: &operation\n  summary: Shared alias\n  responses:\n    200:\n      description: Exact body\n      content:\n        application/json:\n          example: {n: 9007199254740993.00}\npaths:\n  /one:\n    servers: [{url: https://one.invalid}]\n    get: *operation\n  /two:\n    servers: [{url: https://two.invalid}]\n    get: *operation\n';
 const input={root,snapshot:'alias-contexts',resources:[{id:root,text,generation:1}]},before=input.resources[0].text;
 for(const name of ['one','two']) {
  const pointer='/paths/~1'+name+'/get',page=referencePage({...input,resource:root,pointer,occurrence:root+'#'+pointer});
  assert.equal(page.physicalPointer,'/x-operation');assert.equal(page.occurrence,root+'#'+pointer);
  assert.equal(page.effective.find(field=>field.name==='servers').source.pointer,'/paths/~1'+name+'/servers');
  const preview=page.previews.find(item=>item.label==='example');
  assert.equal(preview.text,'{"n":9007199254740993.00}');
  assert.equal(preview.source.pointer,pointer+'/responses/200/content/application~1json/example');
  assert.equal(preview.source.physicalPointer,'/x-operation/responses/200/content/application~1json/example');
  assert.equal(text.slice(...preview.source.range),'{n: 9007199254740993.00}');
  assert.equal(text.slice(...preview.source.occurrenceRange),'*operation');
 }
 const {docs}=createGraph(input);assert.throws(()=>docs.get(root).node('/paths/~1one/get/responses'),error=>error.code==='edit.target');
 assert.equal(input.resources[0].text,before);
});
