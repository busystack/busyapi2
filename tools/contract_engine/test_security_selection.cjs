const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {createGraph,inspect}=require('./dist/model.cjs');
const {referenceChoices}=require('./dist/reference_choices.cjs');
const {planReference}=require('./dist/reference_selection.cjs');
const {assistSource}=require('./dist/source_assistance.cjs');

function fixture(version,format,empty=false){
 const root='file:///project/api.'+format,external='file:///project/security.json',legacy=version==='2.0';
 const definitions=Object.fromEntries([['Local',{type:'apiKey',in:'header',name:'X-Key'}],['__proto__',{type:'apiKey',in:'query',name:'key'}],
  ...(!legacy?[['Alias',{$ref:'security.json#/a~1b~0%E9%9B%AA%F0%9F%98%80'}]]:[])]);
 const data={...(legacy?{swagger:version}:{openapi:version}),info:{title:'Security choices 雪',version:'1'},paths:{},
  ...(legacy?{securityDefinitions:definitions}:{components:{securitySchemes:definitions}}),security:[empty?{}:{Local:[]}],
  'x-payload':{security:{Fake:[]},type:'apiKey'},'x-number':'EXACT'};
 const encode=value=>(format==='json'?JSON.stringify(value,null,2):'# retained security source\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 return {root,snapshot:'security-choice-snapshot',resources:[{id:root,text:encode(data),generation:4,identity:'source'},
  {id:external,text:JSON.stringify({'a/b~雪😀':{type:'apiKey',in:'header',name:'X-Remote'}}),generation:7,identity:'external'}],
  contexts:[{root,resources:[root,external]}],data,encode};
}
function selectedPlan(input,pointer,bindingForm){
 const page=referenceChoices({...input,resource:input.root,pointer,keyword:'security',bindingForm,query:''});
 const entry=page.entries.find(entry=>bindingForm==='uri'?entry.target.resource!==input.root:entry.value==='__proto__');
 assert(entry);
 const capture=location=>{
  const resource=input.resources.find(resource=>resource.id===location.resource);
  return {...location,expected:resource.text.slice(...location.range)};
 };
 return planReference({...input,keyword:'security',target:capture(page),choice:{...capture(entry.target),bindingForm:entry.bindingForm,value:entry.value}});
}
function capture(input,location){
 const resource=input.resources.find(resource=>resource.id===location.resource),doc=createGraph(input).docs.get(location.resource),node=doc.node(location.pointer);
 return {root:input.root,...location,generation:resource.generation,range:node.range,expected:resource.text.slice(...node.range)};
}
function planChoice(input,page,entry){
 return planReference({...input,keyword:'security',target:capture(input,page),choice:{...capture(input,entry.target),bindingForm:entry.bindingForm,value:entry.value}});
}
function apply(input,plan){
 return input.resources.map(resource=>{
  let text=resource.text;
  for(const edit of plan.edits.filter(edit=>edit.buffer===resource.id).sort((a,b)=>b.start-a.start)){
   assert.equal(text.slice(edit.start,edit.end),edit.expected);
   text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
  }
  return {...resource,text};
 });
}
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json']){
 test(`security retargeting retains scopes only where representable ${version} ${format}`,()=>{
  const input=fixture(version,format),schemes=version==='2.0'?input.data.securityDefinitions:input.data.components.securitySchemes;
  schemes.OAuth=version==='2.0'?{type:'oauth2',flow:'implicit',authorizationUrl:'https://auth.invalid/authorize',scopes:{read:'Read','雪':'Snow'}}:
   {type:'oauth2',flows:{implicit:{authorizationUrl:'https://auth.invalid/authorize',scopes:{read:'Read','雪':'Snow'}}}};
  input.data.security=[{OAuth:['read','雪']}];input.resources[0].text=input.encode(input.data);
  const pointer='/security/0/OAuth',before=inspect({...input,resource:input.root,pointer});
  assert.equal(before.securityBinding.kind,'scopes');
  const page=referenceChoices({...input,resource:input.root,pointer,keyword:'security',query:''});
  assert(page.entries.some(entry=>entry.value==='OAuth'));
  const target=page.entries.find(entry=>entry.value==='Local');
  assert.equal(Boolean(target),version.startsWith('3.2.'));
  if(target){
   const plan=planChoice(input,page,target),resources=apply(input,plan),changed={...input,resources},doc=createGraph(changed).docs.get(input.root);
   assert.deepEqual(JSON.parse(doc.dataJson('/security/0/Local')),['read','雪']);
   assert.equal(inspect({...changed,resource:input.root,pointer:'/security/0/Local'}).securityBinding.kind,'roles');
   const originalDoc=createGraph(input).docs.get(input.root),originalNode=originalDoc.node(pointer),afterNode=doc.node('/security/0/Local');
   assert.equal(resources[0].text.slice(...afterNode.range),input.resources[0].text.slice(...originalNode.range));
   assert.equal(plan.edits.length,1);assert.equal(plan.edits[0].expected,'OAuth');assert.equal(plan.edits[0].replacement,'Local');
  }
  const empty=fixture(version,format),rule=inspect({...empty,resource:empty.root,pointer:'/security/0/Local'});
  assert.equal(rule.securityBinding.kind,version.startsWith('3.2.')?'roles':'empty');
  assert.equal(rule.capabilities.securityRequirementUris,version.startsWith('3.2.'));
 });
 test(`security selector refuses arbitrary payloads and stale captures ${version} ${format}`,()=>{
  const input=fixture(version,format),page=referenceChoices({...input,resource:input.root,pointer:'/security',keyword:'security',query:''});
  assert.throws(()=>referenceChoices({...input,resource:input.root,pointer:'/x-payload/security',keyword:'security',query:''}),e=>e.code==='reference.choice.context');
  const entry=page.entries.find(entry=>entry.value==='Local'),target=capture(input,page),choice={...capture(input,entry.target),bindingForm:entry.bindingForm,value:entry.value};
  assert.throws(()=>planReference({...input,keyword:'security',target:{...target,generation:3},choice}),e=>e.code==='edit.stale');
  assert.throws(()=>planReference({...input,keyword:'security',target,choice:{...choice,expected:'stale'}}),e=>e.code==='edit.stale');
  assert.throws(()=>planReference({...input,keyword:'security',target,choice:{...choice,value:'guessed'}}),e=>e.code==='reference.choice.context');
  if(!version.startsWith('3.2.'))assert.throws(()=>referenceChoices({...input,resource:input.root,pointer:'/security',keyword:'security',bindingForm:'uri',query:''}),e=>e.code==='reference.choice.security-uri');
 });
}
for(const format of ['yaml','json'])test(`URI security selection retains authored spellings and list bytes ${format}`,()=>{
 const input=fixture('3.2.1',format),value='./security.json#/a~1b~0%E9%9B%AA%F0%9F%98%80';
 input.data.security=[{[value]:['operator','雪']}];input.resources[0].text=input.encode(input.data);
 const pointer='/security/0/'+value.replaceAll('~','~0').replaceAll('/','~1'),page=referenceChoices({...input,resource:input.root,pointer,keyword:'security',query:''});
 const selected=page.entries.filter(entry=>entry.selected);
 assert.equal(selected.length,1);assert.equal(selected[0].value,value);assert.equal(selected[0].bindingForm,'uri');
 const plan=planChoice(input,page,selected[0]);
 assert.deepEqual(plan.edits,[]);assert.deepEqual(plan.changes,[]);assert.deepEqual(plan.transitions,[]);
 assert.deepEqual(apply(input,plan),input.resources);
});
for(const other of ['3.2.1','3.1.2','3.0.4'])test(`shared operation security selection checks every root ${other}`,()=>{
 const root='file:///project/a.json',second='file:///project/b.json',part='file:///project/paths.json',external='file:///project/security.json';
 const document=version=>({openapi:version,info:{title:'Shared',version:'1'},paths:{'/shared':{$ref:'paths.json#/Item'}},components:{securitySchemes:{Local:{type:'apiKey',in:'header',name:'X-Key'},Remote:{$ref:'security.json#/Remote'}}}});
 const resources=[{id:root,generation:1,text:JSON.stringify(document('3.2.1'))},{id:second,generation:1,text:JSON.stringify(document(other))},
  {id:part,generation:1,text:JSON.stringify({Item:{get:{security:[{Local:[]}],responses:{204:{description:'Empty'}}}}})},
  {id:external,generation:1,text:JSON.stringify({Remote:{type:'apiKey',in:'header',name:'X-Remote'}})}];
 const input={root,snapshot:'shared-security',resources,contexts:[{root,resources:[root,part,external]},{root:second,resources:[second,part,external]}]},pointer='/Item/get/security/0/Local';
 const page=referenceChoices({...input,resource:part,pointer,keyword:'security',bindingForm:'uri',query:''});
 const entry=page.entries.find(entry=>entry.target.resource===external);assert(entry);
 if(other.startsWith('3.2.')){
  const plan=planChoice(input,page,entry);assert.deepEqual(plan.checkedRoots,[root,second]);
  for(const context of input.contexts){
   const graph=createGraph({root:context.root,resources:apply(input,plan).filter(resource=>context.resources.includes(resource.id))}).graph;
   const ref=graph.references.find(ref=>ref.resource===part&&ref.connection==='security');
   assert.equal(ref.targetResource,external);assert.equal(ref.targetPointer,'/Remote');
  }
 }else assert.throws(()=>planChoice(input,page,entry),e=>['refactor.context.ambiguous','reference.choice.security-uri'].includes(e.code));
 assert.deepEqual(input.resources,resources);
});
test('shared YAML security keys never receive Source edits or unsafe plans',()=>{
 const root='file:///project/anchors.yaml',text='openapi: 3.2.1\ninfo: {title: Shared, version: "1"}\npaths: {}\ncomponents: {securitySchemes: {Local: {type: apiKey, in: header, name: X-Key}}}\nsecurity:\n  - &owned {Local: []}\n  - *owned\n';
 const input={root,snapshot:'shared',resources:[{id:root,generation:1,text}],contexts:[{root,resources:[root]}]};
 for(const pointer of ['/security/0','/security/1']){
  const node=createGraph(input).docs.get(root).node(pointer),result=assistSource({...input,resource:root,caret:node.range[0]+1,action:'completion'});
  assert.equal(result.completions.length,0);
  const page=referenceChoices({...input,resource:root,pointer,keyword:'security',query:''});
  if(page.entries.length)assert.throws(()=>planChoice(input,page,page.entries[0]),e=>e.code==='reference.choice.context');
 }
 assert.equal(input.resources[0].text,text);
});
for(const format of ['yaml','json'])test(`URI security choices require a cold discoverable identity ${format}`,()=>{
 const input=fixture('3.2.1',format),external=input.resources[1],identity='https://contracts.invalid/security';
 external.text=JSON.stringify({openapi:'3.2.1',$self:identity,info:{title:'Security identity',version:'1'},paths:{},components:{securitySchemes:{Remote:{type:'apiKey',in:'header',name:'X-Remote'}}}});
 delete input.data.components.securitySchemes.Alias;input.resources[0].text=input.encode(input.data);
 const page=referenceChoices({...input,resource:input.root,pointer:'/security/0/Local',keyword:'security',bindingForm:'uri',query:'Remote'});
 const entry=page.entries.find(entry=>entry.target.resource===external.id);assert(entry);
 assert.equal(entry.value,identity+'#/components/securitySchemes/Remote');
 assert.throws(()=>planChoice(input,page,entry),e=>e.code==='reference.choice.retrieval');
 const approved={...input,resources:input.resources.map(resource=>resource===external?{...resource,aliases:[identity]}:resource)};
 const allowed=referenceChoices({...approved,resource:input.root,pointer:'/security/0/Local',keyword:'security',bindingForm:'uri',query:'Remote'});
 const selected=allowed.entries.find(entry=>entry.target.resource===external.id),plan=planChoice(approved,allowed,selected);
 assert.equal(plan.value,entry.value);assert.equal(apply(approved,plan)[1].text,external.text);
});
for(const version of ['2.0','3.0.0','3.0.4','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json']){
 test(`security binding choices are typed and family-owned ${version} ${format}`,()=>{
  const input=fixture(version,format),{graph}=createGraph(input),before=input.resources.map(resource=>resource.text);
  assert.equal(graph.issues.length,0);
  for(const pointer of ['/security','/security/0','/security/0/Local']){
   const result=referenceChoices({...input,resource:input.root,pointer,keyword:'security',query:''});
   assert.equal(result.targetKind,'security');assert(result.entries.length>0);
   assert(result.entries.every(entry=>entry.kind==='security'&&['name','uri'].includes(entry.bindingForm)));
   assert(!result.entries.some(entry=>entry.label==='Fake'));
   for(const entry of result.entries){
    const resolved=graph.resolveConnection({...graph.scope(input.root,pointer),kind:'security',connection:'security',keyword:entry.value,value:entry.value});
    assert.equal(resolved.resolution,'resolved');assert.equal(resolved.targetResource,entry.target.resource);assert.equal(resolved.targetPointer,entry.target.pointer);
   }
   assert.equal(result.entries.some(entry=>entry.bindingForm==='uri'),version.startsWith('3.2.'));
   assert.equal(new Set(result.entries.map(entry=>entry.semanticId)).size,result.entries.length);
  }
  assert.deepEqual(input.resources.map(resource=>resource.text),before);
 });
 test(`Source security completion uses native names and applicable URIs ${version} ${format}`,()=>{
  const input=fixture(version,format,true),{docs}=createGraph(input),node=docs.get(input.root).node('/security/0');
  const result=assistSource({...input,resource:input.root,caret:node.range[0]+1,action:'completion'});
  assert(result.completions.some(entry=>entry.label==='Local'));
  assert(result.completions.some(entry=>entry.label==='__proto__'));
  assert.equal(result.completions.some(entry=>entry.label.includes('security.json#')),version.startsWith('3.2.'));
  assert(!result.completions.some(entry=>entry.label.includes('Fake')));
  for(const completion of result.completions){
   let text=input.resources[0].text;
   for(const edit of [...completion.edits].reverse()){
    assert.equal(text.slice(edit.start,edit.end),edit.expected);
    text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
   }
   const after=createGraph({...input,resources:input.resources.map(resource=>resource.id===input.root?{...resource,text}:resource)});
   assert.equal(after.docs.get(input.root).issues.length,0);assert.equal(after.graph.issues.length,0);
   assert(text.includes('9007199254740993.00'));
  }
 });
 for(const pointer of ['/security','/security/0','/security/0/Local'])for(const bindingForm of ['name',...(version.startsWith('3.2.')?['uri']:[])])
 test(`security selection applies scoped edits ${version} ${format} ${pointer} ${bindingForm}`,()=>{
  const input=fixture(version,format),original=input.resources.map(resource=>resource.text);
  input.configuration={id:'file:///project/busyapi.yaml',generation:1,identity:'configuration',text:'version: 1\nenvironments: {manual: {authentication: {schemes: {Local: {secretRef: old-reference}}}}}\n'};
  const plan=selectedPlan(input,pointer,bindingForm),after=createGraph({...input,resources:apply(input,plan)});
  assert.equal(plan.kind,'reference-selection');assert(plan.edits.length>0);
  assert.equal(after.graph.issues.length,0);assert.equal(after.docs.get(input.root).issues.length,0);
  const requirement=pointer==='/security'?'/security/1':'/security/0';
  const ref=after.graph.references.find(ref=>ref.resource===input.root&&ref.pointer===requirement&&ref.connection==='security'&&ref.value===plan.value);
  assert(ref);assert.equal(ref.targetResource,bindingForm==='uri'?input.resources[1].id:input.root);
  assert.equal(after.docs.get(input.root).dataJson(requirement+'/'+plan.value.replaceAll('~','~0').replaceAll('/','~1')),'[]');
  assert.equal(after.docs.get(input.root).node('/security').children.size,pointer==='/security'?2:1);
  assert.equal(after.docs.get(input.root).node('/security/0').children.size,pointer==='/security/0'?2:1);
  if(pointer.endsWith('/Local'))assert(plan.transitions.some(transition=>transition.from===pointer&&transition.to===requirement+'/'+plan.value.replaceAll('~','~0').replaceAll('/','~1')));
  assert(after.docs.get(input.root).text.includes('9007199254740993.00'));
  assert.equal(after.docs.get(input.resources[1].id).text,original[1]);
  assert(!plan.edits.some(edit=>edit.buffer===input.configuration.id));
  assert.deepEqual(input.resources.map(resource=>resource.text),original);
 });
}
