const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const root=__dirname;
const {requestOperation}=require(path.join(root,'dist/execution.cjs'));
const {analyse}=require(path.join(root,'dist/model.cjs'));
const YAML=require(path.join(root,'node_modules/yaml'));
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const modern=v=>v.startsWith('3.1')||v.startsWith('3.2');
const render=(v,format)=>(format==='yaml'?'# Keep branch ownership\r\n'+YAML.stringify(v).replaceAll('\n','\r\n'):JSON.stringify(v)+'\r\n').replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
function packet(v,format,schema,override){
 const id='file:///controlled/conditional.'+format;
 const value={openapi:v,info:{title:'Authored branch choices',version:'business'},paths:{'/data':{post:{requestBody:{content:{'application/json':{schema,...override}}},responses:{200:{description:'Reply'}}}}}};
 return {root:id,resource:id,pointer:'/paths/~1data/post',snapshot:v+format,resources:[{id,text:render(value,format),generation:3}]};
}
const media=p=>requestOperation(p).requestBody.content[0];
const example=(v,value)=>modern(v)?{examples:[value]}:{example:value};
for(const v of versions)for(const format of ['yaml','json'])for(const keyword of ['oneOf','anyOf'])test(`${v} ${format} ${keyword} retains separate authored whole-instance choices`,()=>{
 const p=packet(v,format,{[keyword]:[{type:'string',...example(v,'雪😀')},{type:'integer',...example(v,'EXACT')}]});
 const before=p.resources[0].text,result=media(p),base='/paths/~1data/post/requestBody/content/application~1json/schema/'+keyword;
 assert.equal(analyse(p).complete,true);
 assert.deepEqual(result.examples.map(e=>e.raw),['"雪😀"','9007199254740993.00']);
 assert(result.examples.every(e=>e.origin==='schema'&&e.source.resource===p.root&&e.source.generation===3));
 assert.deepEqual(result.examples.map(e=>e.source.pointer),[0,1].map(index=>base+'/'+index+(modern(v)?'/examples/0':'/example')));
 assert.deepEqual(result.examples.map(e=>[e.name,e.schemaApplicability,e.schemaContext.map(s=>[s.keyword,s.selector,s.source.pointer])]),[0,1].map(index=>[
  `${keyword}[${index}] · ${modern(v)?'examples[0]':'example'}`,'not-evaluated',[[keyword,String(index),base+'/'+index]],
 ]));
 assert.deepEqual(result.schemaExamples,{complete:true,issues:[]});
 assert.equal(p.resources[0].text,before);
});
for(const v of versions.filter(modern))for(const format of ['yaml','json'])test(`${v} ${format} if then and else retain same-instance values without child or negated samples`,()=>{
 const p=packet(v,format,{if:{type:'string',examples:['Predicate']},then:{type:'string',examples:['']},else:{type:'integer',examples:[0]},not:{const:42,examples:[42]},properties:{child:{examples:['Child']}}});
 const before=p.resources[0].text,result=media(p);
 assert.deepEqual(result.examples.map(e=>e.raw),['"Predicate"','""','0']);assert.deepEqual(result.schemaExamples,{complete:true,issues:[]});assert.equal(p.resources[0].text,before);
 assert.deepEqual(result.examples.map(e=>e.schemaContext.map(s=>s.keyword)),[['if'],['then'],['else']]);
});
for(const v of versions.filter(modern))for(const format of ['yaml','json'])test(`${v} ${format} dependent schema choices preserve whole-object payload and escaped trigger source`,()=>{
 const p=packet(v,format,{type:'object',dependentSchemas:{'trigger/~':{examples:[{'trigger/~':false,n:'EXACT'}]}},properties:{child:{examples:['Child']}}});
 const before=p.resources[0].text,result=media(p);
 assert.deepEqual(result.examples.map(e=>e.raw),['{"trigger/~":false,"n":9007199254740993.00}']);
 assert(result.examples[0].source.pointer.endsWith('/dependentSchemas/trigger~1~0/examples/0'));assert.deepEqual(result.schemaExamples,{complete:true,issues:[]});assert.equal(p.resources[0].text,before);
 assert.equal(result.examples[0].name,'dependentSchemas["trigger/~"] · examples[0]');
 assert.equal(result.examples[0].schemaContext[0].selector,'trigger/~');
});
for(const v of versions)for(const format of ['yaml','json'])test(`${v} ${format} explicit owner example suppresses every branch candidate`,()=>{
 const p=packet(v,format,{oneOf:[example(v,'Branch')]},{example:false}),before=p.resources[0].text,result=media(p);
 assert.deepEqual(result.examples.map(e=>e.raw),['false']);assert.equal(result.schemaExamples,undefined);assert.equal(p.resources[0].text,before);
});
for(const rootVersion of versions.filter(modern))for(const ownerVersion of versions.filter(modern))for(const format of ['yaml','json'])test(`${rootVersion} ${format} conditional choices retain defining ${ownerVersion} references and resource identity`,()=>{
 const shared='file:///controlled/shared.'+format,p=packet(rootVersion,format,{$ref:'shared.'+format+'#/components/schemas/Branch~1~0'});
 const owner={openapi:ownerVersion,info:{title:'Defining branches',version:'business'},paths:{},components:{schemas:{
  'Branch/~':{oneOf:[{$ref:'#/components/schemas/Alias'},{type:'array',examples:[[false,0,'']]}]},
  Alias:{$ref:'#/components/schemas/Value~1~0'},'Value/~':{type:'object',examples:[{n:'EXACT',$ref:'literal.json'}]},
 }}};
 p.resources.push({id:shared,text:render(owner,format),generation:9});
 const original=p.resources.map(r=>r.text),result=media(p);
 assert.deepEqual(result.examples.map(e=>e.raw),['{"n":9007199254740993.00,"$ref":"literal.json"}','[false,0,""]']);
 assert.deepEqual(result.examples.map(e=>e.source.pointer),['/components/schemas/Value~1~0/examples/0','/components/schemas/Branch~1~0/oneOf/1/examples/0']);
 assert(result.examples.every(e=>e.source.resource===shared&&e.source.generation===9));
 assert.deepEqual(result.examples.map(e=>e.schemaContext[0].source.pointer),[0,1].map(i=>'/components/schemas/Branch~1~0/oneOf/'+i));
 assert(result.examples.every(e=>e.schemaContext[0].source.resource===shared&&e.schemaContext[0].source.generation===9));
 assert.deepEqual(result.schemaExamples,{complete:true,issues:[]});assert.deepEqual(p.resources.map(r=>r.text),original);
});
for(const v of versions.filter(modern))for(const format of ['yaml','json'])test(`${v} ${format} conditional discovery obeys local if ownership and boolean reachability`,()=>{
 const samples=value=>({examples:[value]});
 for(const [schema,expected]of [
  [{then:samples('Ignored then'),else:samples('Ignored else')},[]],
  [{allOf:[{if:samples('Predicate')},{then:samples('Ignored across allOf')}]},['"Predicate"']],
  [{if:true,then:samples(false),else:samples('Unreachable')},['false']],
  [{if:false,then:samples('Unreachable'),else:samples(0)},['0']],
 ]){
  const p=packet(v,format,schema),before=p.resources[0].text,result=media(p);
  assert.deepEqual(result.examples.map(e=>e.raw),expected);assert.deepEqual(result.schemaExamples,{complete:true,issues:[]});assert.equal(p.resources[0].text,before);
 }
 const p=packet(v,format,{$ref:'shared.'+format,then:samples('Ignored across ref')});
 p.resources.push({id:'file:///controlled/shared.'+format,text:render({if:samples('Referenced predicate')},format),generation:4});
 assert.deepEqual(media(p).examples.map(e=>e.raw),['"Referenced predicate"']);
});
for(const v of versions.filter(modern))for(const format of ['yaml','json'])test(`${v} ${format} unavailable branch evaluation remains explicitly incomplete`,()=>{
 for(const [branch,code]of [[{$id:'branch.json',$schema:'https://example.invalid/dialect',examples:['Unavailable']},'request.schema-examples.dialect'],[{$ref:'missing.json#/Value'},'request.schema-examples.reference']]){
  const p=packet(v,format,{anyOf:[{examples:[false]},branch]}),before=p.resources[0].text,result=media(p);
  assert.deepEqual(result.examples.map(e=>e.raw),['false']);assert.equal(result.schemaExamples.complete,false);assert.equal(result.schemaExamples.issues.length,1);
  const issue=result.schemaExamples.issues[0];assert.equal(issue.code,code);assert.equal(issue.source.resource,p.root);assert(issue.source.pointer.includes('/anyOf/1'));assert(issue.source.range[1]>issue.source.range[0]);assert.equal(p.resources[0].text,before);
 }
});
for(const v of ['3.0.4','3.1.2','3.2.1'])test(`${v} aliased branches retain physical context and example locations`,()=>{
 const p=packet(v,'yaml',{$ref:'shared.yaml#/Value'}),shared='file:///controlled/shared.yaml';
 const annotation=modern(v)?'examples: [{n: 9007199254740993.00, flag: false}]':'example: {n: 9007199254740993.00, flag: false}';
 p.resources.push({id:shared,generation:5,text:'# Keep both aliases\r\nx-branch: &branch\r\n  '+annotation+'\r\nx-shape: &shape\r\n  oneOf: [*branch]\r\nValue: *shape\r\n'});
 const before=p.resources.map(r=>r.text),result=media(p),choice=result.examples[0];
 assert.equal(choice.raw,'{"n":9007199254740993.00,"flag":false}');assert.equal(choice.source.pointer,'/x-branch/'+(modern(v)?'examples/0':'example'));
 assert.equal(choice.schemaContext[0].source.pointer,'/x-branch');assert.equal(choice.schemaContext[0].source.resource,shared);
 assert.equal(p.resources[1].text.slice(...choice.source.range),'{n: 9007199254740993.00, flag: false}');assert.deepEqual(result.schemaExamples,{complete:true,issues:[]});assert.deepEqual(p.resources.map(r=>r.text),before);
});
for(const v of versions.filter(v=>!modern(v)))for(const format of ['yaml','json'])test(`${v} ${format} newer conditional keywords remain invalid and provide no authored candidates`,()=>{
 const p=packet(v,format,{type:'string',if:{example:'Wrong predicate'},then:{example:'Wrong then'},else:{example:'Wrong else'},dependentSchemas:{trigger:{example:'Wrong dependency'}}}),before=p.resources[0].text;
 assert(analyse(p).findings.length>0);assert.deepEqual(media(p).examples,[]);assert.equal(p.resources[0].text,before);
});
for(const v of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${v} ${format} repeated and recursive branches have deterministic first-occurrence provenance`,()=>{
 const p=packet(v,format,{$ref:'#/components/schemas/Root'}),value={type:'string',...example(v,'Shared')};
 const root={oneOf:[{$ref:'#/components/schemas/Root'},{$ref:'#/components/schemas/Value'},{$ref:'#/components/schemas/Value'}]};
 const doc={openapi:v,info:{title:'Recursive choices',version:'business'},paths:{'/data':{post:{requestBody:{content:{'application/json':{schema:{$ref:'#/components/schemas/Root'}}}},responses:{200:{description:'Reply'}}}}},components:{schemas:{Root:root,Value:value}}};
 p.resources[0].text=render(doc,format);const before=p.resources[0].text,result=media(p);
 assert.deepEqual(result.examples.map(e=>e.raw),['"Shared"']);assert.equal(result.examples[0].schemaContext[0].source.pointer,'/components/schemas/Root/oneOf/1');assert.deepEqual(result.schemaExamples,{complete:true,issues:[]});assert.equal(p.resources[0].text,before);
});
for(const format of ['yaml','json'])test(`${format} nested branch provenance has a bounded partial result and located limit marker`,()=>{
 let schema={examples:Array.from({length:512},(_,i)=>i)};
 for(let i=0;i<30;i++)schema={allOf:[schema]};
 const p=packet('3.2.1',format,schema),before=p.resources[0].text,result=media(p);
 assert(result.examples.length>0&&result.examples.length<512);assert.equal(result.schemaExamples.complete,false);assert.equal(result.schemaExamples.issues.length,1);
 const issue=result.schemaExamples.issues[0];assert.equal(issue.code,'limit.request.schema-examples');assert.equal(issue.source.resource,p.root);assert(issue.source.range[1]>issue.source.range[0]);
 assert(Buffer.byteLength(JSON.stringify(result))<3*1024*1024);assert.equal(p.resources[0].text,before);
});
