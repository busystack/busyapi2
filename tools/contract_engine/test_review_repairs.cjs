const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse,createGraph}=require('./dist/model.cjs');
const {planDelete}=require('./dist/refactoring_delete.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {semanticSearch}=require('./dist/source_assistance.cjs');
const id='file:///review/openapi.json';
const fixture=(version,value,json=true)=>({root:json?id:id.replace('.json','.yaml'),snapshot:'review',resources:[{id:json?id:id.replace('.json','.yaml'),generation:1,text:json?JSON.stringify({openapi:version,info:{title:'Review',version:'1'},paths:{},...value}):YAML.stringify({openapi:version,info:{title:'Review',version:'1'},paths:{},...value})}]});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true]) {
 const id=json?'file:///review/openapi.json':'file:///review/openapi.yaml';
 test(`F10 implicit Link identities survive unrelated reviewed deletion ${version} ${json?'JSON':'YAML'}`,()=>{
  const input=fixture(version,{paths:{'/pets':{get:{operationId:'get pets',responses:{200:{description:'ok',links:{again:{operationId:'get pets'}}}}}}},components:{schemas:{Unused:{type:'string'}}}},json);
  assert.equal(analyse(input).findings.length,0);
  const plan=planDelete({...input,contexts:[{root:id,resources:[id]}],target:{resource:id,generation:1,pointer:'/components/schemas/Unused'}});
  assert.equal(plan.blockers.length,0);
  let text=input.resources[0].text;
  for(const edit of [...plan.edits].sort((a,b)=>b.start-a.start)){assert.equal(text.slice(edit.start,edit.end),edit.expected);text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);}
  assert(text.includes('get pets'));assert.equal(createGraph({...input,resources:[{...input.resources[0],text}]}).graph.issues.length,0);
  const blocked=planDelete({...input,contexts:[{root:id,resources:[id]}],target:{resource:id,generation:1,pointer:'/paths/~1pets/get'}});
  // The Link is inside the removed operation, so it is removed together.
  assert.equal(blocked.blockers.length,0);
 });
 test(`F14 equivalent Paths templates have located canonical findings ${version} ${json?'JSON':'YAML'}`,()=>{
  const item=name=>({get:{parameters:[{name,in:'path',required:true,schema:{type:'string'}}],responses:{200:{description:'ok'}}}});
  const input=fixture(version,{paths:{'/pets/{id}':item('id'),'/pets/{name}':item('name'),'/owners/{name}':item('name')}},json);
  const result=analyse(input), findings=result.findings.filter(f=>f.code==='path.template.equivalent');
  assert.equal(findings.length,2);assert(findings.every(f=>f.resource===id&&f.pointer.startsWith('/paths/')&&f.range[1]>f.range[0]));
  assert(!findings.some(f=>f.pointer.includes('owners')));
 });
 test(`F15 optional discriminator metadata is version aware ${version} ${json?'JSON':'YAML'}`,async()=>{
  const value={components:{schemas:{Model:{type:'object',properties:{kind:{type:'string'}},oneOf:[{required:['a']},{required:['b']}],discriminator:{propertyName:'kind'},examples:[{a:true}]}}}};
  const result=await evaluateSchemas(fixture(version,value,json));
  const finding=result.findings.find(f=>f.code==='discriminator.default-mapping.required');
  assert.equal(Boolean(finding),version==='3.2.1');
  if(finding){assert.equal(finding.pointer,'/components/schemas/Model/discriminator');assert(finding.range[1]>finding.range[0]);}
  value.components.schemas.Model.required=['kind'];
  assert(!(await evaluateSchemas(fixture(version,value,json))).findings.some(f=>f.code==='discriminator.default-mapping.required'));
 });
}
test('F14 3.2 Paths grammar and repetition are checked separately from callbacks/webhooks',()=>{
 const result=analyse(fixture('3.2.1',{paths:{'/pets/{id}/{id}':{},'/bad{':{},'/pets?filter=1':{},'/empty//segment':{},'/literal%7B':{},'/':{},'/trailing/':{},'/name/{slash/name}/':{}},webhooks:{'arbitrary{':{}}}));
 assert(result.findings.some(f=>f.code==='path.template.repeated'));
 assert.equal(result.findings.filter(f=>f.code==='path.template.syntax').length,3);
 assert(!result.findings.some(f=>f.code.startsWith('path.template.')&&(f.pointer.includes('webhooks')||f.pointer.includes('literal%7B')||f.pointer.includes('trailing')||f.pointer.includes('slash~1name'))));
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`R05 path literal tokens do not cross expressions ${version} ${json?'JSON':'YAML'}`,()=>{
 const invalid=['/%{id}20','/%2{id}0','/%{id}2{other}0','/%2G{id}'];
 const valid=['/%20{id}','/{id}%20','/%25{id}20','/{id}2F'];
 const input=fixture(version,{paths:Object.fromEntries([...invalid,...valid].map(path=>[path,{}]))},json);
 const result=analyse(input),syntax=result.findings.filter(f=>f.code==='path.template.syntax');
 assert.deepEqual(syntax.map(f=>f.pointer).sort(),version==='3.2.1'?invalid.map(path=>'/paths/'+path.replaceAll('~','~0').replaceAll('/','~1')).sort():[]);
 for(const finding of syntax)assert.equal(input.resources[0].text.slice(...finding.range).includes(finding.pointer.slice('/paths/'.length).replaceAll('~1','/')),true);
});
test('F06 empty root servers get the root-only default; operation overrides remain explicit',()=>{
 for(const version of ['3.1.2','3.2.1'])for(const servers of [undefined,[]]){
  const input=fixture(version,{servers,paths:{'/pets':{get:{responses:{200:{description:'ok'}}}}}});
  let op=analyse(input).operations[0],plan=requestOperation({...input,resource:id,pointer:op.pointer,occurrence:op.occurrence});
  assert.deepEqual(plan.servers.map(s=>s.url),['/']);
 }
});
for(const json of [false,true])test(`F15 canonical proof follows required references and preserves schema validity ${json?'JSON':'YAML'}`,async()=>{
 const input=fixture('3.2.1',{components:{schemas:{Base:{type:'object',required:['kind']},Model:{allOf:[{$ref:'#/components/schemas/Base'}],properties:{kind:{type:'string'}},discriminator:{propertyName:'kind'}}}}},json);
 const required=await evaluateSchemas(input);
 assert.equal(required.complete,true);assert(!required.findings.some(f=>f.code.startsWith('discriminator.')));
 const optional=fixture('3.2.1',{components:{schemas:{Model:{type:'object',properties:{kind:{type:'string'}},oneOf:[{required:['a']},{required:['b']}],discriminator:{propertyName:'kind'},examples:[{a:true}]}}}},json);
 const checked=await evaluateSchemas({...optional,runtimeInstances:[{subject:'test',location:'absent-kind',text:'{"a":true}',schema:{resource:optional.root,pointer:'/components/schemas/Model'}}]});
 assert(checked.findings.some(f=>f.code==='discriminator.default-mapping.required'));
 assert.equal(checked.runtimeEvaluations[0].valid,true);assert.equal(checked.runtimeEvaluations[0].complete,true);
 assert.deepEqual(checked.evaluations.map(e=>e.valid),[true]);
 const value={components:{schemas:{Other:{type:'object'},Model:{type:'object',oneOf:[{required:['a']},{required:['b']}],discriminator:{propertyName:'kind',defaultMapping:'Other'},examples:[{a:true}]}}}};
 const valid=fixture('3.2.1',value,json);
 assert.equal(analyse(valid).references.find(r=>r.keyword==='defaultMapping').resolution,'resolved');
 assert.equal((await evaluateSchemas(valid)).complete,true);
});
test('F15 absence of a local required keyword is not an optionality proof',async()=>{
 const input=fixture('3.2.1',{components:{schemas:{Model:{type:'object',minProperties:1,additionalProperties:false,properties:{kind:{type:'string'}},allOf:[true],discriminator:{propertyName:'kind'}}}}});
 const result=await evaluateSchemas(input);
 assert.equal(result.complete,false);
 assert(!result.findings.some(f=>f.code==='discriminator.default-mapping.required'));
 assert(result.findings.some(f=>f.code==='discriminator.required.incomplete'));
});
test('F14 3.1 does not inherit 3.2-only path grammar assertions',()=>{
 const input=fixture('3.1.2',{paths:{'/pets/{id}/{id}':{},'/bad{':{},'/pets?filter=1':{}}});
 assert(!analyse(input).findings.some(f=>['path.template.syntax','path.template.repeated'].includes(f.code)));
});
for(const version of ['3.1.2','3.2.1'])test(`F10 explicit discriminator URI fragments still follow array index repairs ${version}`,()=>{
 const variant=kind=>({type:'object',required:['kind'],properties:{kind:{const:kind}}});
 const input=fixture(version,{components:{schemas:{Choices:{anyOf:[false,variant('a'),variant('b')]},Dispatch:{type:'object',required:['kind'],oneOf:[{$ref:'#/components/schemas/Choices/anyOf/1'},{$ref:'#/components/schemas/Choices/anyOf/2'}],discriminator:{propertyName:'kind',mapping:{a:'#/components/schemas/Choices/anyOf/1',b:'#/components/schemas/Choices/anyOf/2'}}}}}});
 const plan=planDelete({...input,contexts:[{root:id,resources:[id]}],target:{resource:id,generation:1,pointer:'/components/schemas/Choices/anyOf/0'}});
 assert.equal(plan.blockers.length,0);
 let text=input.resources[0].text;
 for(const edit of [...plan.edits].sort((a,b)=>b.start-a.start))text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
 const value=JSON.parse(text);
 assert.deepEqual(value.components.schemas.Dispatch.discriminator.mapping,{a:'#/components/schemas/Choices/anyOf/0',b:'#/components/schemas/Choices/anyOf/1'});
 assert.equal(createGraph({...input,resources:[{...input.resources[0],text}]}).graph.issues.length,0);
});
for(const version of ['3.1.2','3.2.1'])test(`F03 runtime syntax and parser bounds remain distinct ${version}`,async()=>{
 const input=fixture(version,{components:{schemas:{Value:true}}});
 const result=await evaluateSchemas({...input,runtimeInstances:[
  {subject:'syntax',location:'json',text:'BAD',schema:{resource:id,pointer:'/components/schemas/Value'}},
  {subject:'valid',location:'json',text:'{}',schema:{resource:id,pointer:'/components/schemas/Value'}},
  {subject:'bounded',location:'json',text:'['.repeat(130)+'0'+']'.repeat(130),schema:{resource:id,pointer:'/components/schemas/Value'}}
 ]});
 assert.equal(result.complete,false);
 assert.deepEqual(result.runtimeEvaluations.map(value=>[value.subject,value.complete,value.valid,value.reason]),[
  ['syntax',true,false,'invalid-json'],['valid',true,true,undefined],['bounded',false,false,'instance-limit']
 ]);
 assert.equal(result.runtimeFindings.find(value=>value.subject==='bounded').severity,'warning');
});
test('F07 semantic search labels preserve additional-method identity',()=>{
 const operation={responses:{200:{description:'ok'}}};
 const input=fixture('3.2.1',{paths:{'/pets':{get:operation,additionalOperations:{purge:operation,PURGE:operation}}}});
 const result=semanticSearch({...input,query:'pets',category:'operations'});
 assert.deepEqual(result.matches.map(match=>match.label),['GET · /pets','purge · /pets','PURGE · /pets']);
 assert.equal(new Set(result.matches.map(match=>match.semanticId)).size,3);
});
