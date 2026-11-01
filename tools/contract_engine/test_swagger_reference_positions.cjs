const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {createGraph,inspect,analyse}=require('./dist/model.cjs');
const {referenceChoices}=require('./dist/reference_choices.cjs');
const {referencePage}=require('./dist/reference_projection.cjs');
const {assistSource}=require('./dist/source_assistance.cjs');

for(const json of [false,true])for(const kind of ['parameter','response'])test(`Swagger reusable ${kind} permits an object, not a Reference Object ${json?'JSON':'YAML'}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/api.'+ext,fragment='file:///project/fragment.'+ext;
 const group=kind==='parameter'?'parameters':'responses',binding='/'+group+'/Forward';
 const schema={type:'string'},object=kind==='parameter'?{name:'q',in:'query',type:'string'}:{description:'Original',schema};
 const value={...object,$ref:'fragment.'+ext+'#/Actual'};
 const use=kind==='parameter'?{parameters:[{$ref:'#'+binding}],responses:{204:{description:'Empty'}}}:{responses:{200:{$ref:'#'+binding}}};
 const document={swagger:'2.0',info:{title:'Reference positions',version:'1'},paths:{'/items':{get:use}},[group]:{Forward:value}};
 const encode=value=>json?JSON.stringify(value,null,2):YAML.stringify(value);
 const input={root,snapshot:'positions',resources:[{id:root,text:encode(document),generation:1},{id:fragment,text:encode({Actual:object}),generation:2}]};
 const before=JSON.stringify(input.resources),{graph,docs}=createGraph(input);
 assert(!graph.references.some(ref=>ref.resource===root&&ref.pointer===binding),'the invalid field must not become a contract edge');
 assert(!graph.scopes.has(fragment+'#/Actual'),'an invalid forwarder must not acquire a semantic target');
 const page=inspect({...input,resource:root,pointer:binding});
 assert(!page.fields.some(field=>field.name==='$ref'),'Design must not offer a Reference Object at a definition position');
 assert(page.fields.some(field=>field.name===(kind==='parameter'?'name':'description')));
 assert.throws(()=>referenceChoices({...input,resource:root,pointer:binding,keyword:'$ref',query:''}),error=>error.code==='reference.choice.context');
 const reference=referencePage({...input,resource:root,pointer:binding});
 assert.equal(reference.interpretation,'inline');
 if(kind==='response'){
  assert.equal(graph.scope(root,binding+'/schema').kind,'schema');
  assert(reference.entries.some(entry=>entry.name==='schema'&&entry.kind==='schema'&&!entry.data));
 }
 const ref=docs.get(root).node(binding+'/$ref');
 assert.equal(assistSource({...input,resource:root,caret:ref.range[0]+1,action:'definition'}).definition,undefined);
 const analysis=analyse(input);assert.equal(analysis.status,'invalid');
 assert(analysis.findings.some(finding=>finding.code==='structure.additionalProperties'&&finding.pointer.startsWith(binding)));
 assert.equal(JSON.stringify(input.resources),before);
});

for(const json of [false,true])for(const kind of ['parameter','response'])test(`Swagger unversioned ${kind} fragments retain chained references ${json?'JSON':'YAML'}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/api.'+ext,fragment='file:///project/fragment.'+ext;
 const group=kind==='parameter'?'parameters':'responses',at='/'+group+'/Forward';
 const object=kind==='parameter'?{name:'q',in:'query',type:'string'}:{description:'Empty'};
 const use=kind==='parameter'?{parameters:[{$ref:'fragment.'+ext+'#'+at}],responses:{204:{description:'Empty'}}}:{responses:{200:{$ref:'fragment.'+ext+'#'+at}}};
 const encode=value=>json?JSON.stringify(value,null,2):YAML.stringify(value);
 const input={root,snapshot:'fragments',resources:[{id:root,text:encode({swagger:'2.0',info:{title:'Fragments',version:'1'},paths:{'/items':{get:use}}}),generation:1},
  {id:fragment,text:encode({[group]:{Forward:{$ref:'#/Actual'}},Actual:object}),generation:2}]};
 const {graph}=createGraph(input);assert.deepEqual(graph.issues,[]);
 assert(graph.references.some(ref=>ref.resource===fragment&&ref.pointer===at&&ref.resolution==='resolved'&&ref.targetPointer==='/Actual'));
 assert(inspect({...input,resource:fragment,pointer:at}).fields.some(field=>field.name==='$ref'));
});

for(const version of ['3.0.0','3.0.4','3.1.0','3.1.2','3.2.0','3.2.1'])for(const json of [false,true])test(`component Reference Objects remain native ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///project/api.'+(json?'json':'yaml'),document={openapi:version,info:{title:'Modern aliases',version:'1'},paths:{},components:{parameters:{Use:{$ref:'#/components/parameters/Actual'},Actual:{name:'q',in:'query',schema:{type:'string'}}},responses:{Use:{$ref:'#/components/responses/Actual'},Actual:{description:'Empty'}}}};
 const input={root,snapshot:'components',resources:[{id:root,text:json?JSON.stringify(document):YAML.stringify(document),generation:1}]}, {graph}=createGraph(input);
 assert.deepEqual(graph.issues,[]);assert.equal(graph.references.length,2);
 for(const group of ['parameters','responses'])assert(inspect({...input,resource:root,pointer:'/components/'+group+'/Use'}).fields.some(field=>field.name==='$ref'));
});
