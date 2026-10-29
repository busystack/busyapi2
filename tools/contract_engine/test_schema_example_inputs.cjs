const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {requestOperation}=require('./dist/execution.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');

const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const modern=version=>version.startsWith('3.1')||version.startsWith('3.2');
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
const render=(value,format)=>(format==='yaml'?'# Keep 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)+'\r\n')
 .replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
function document(version,schema,mediaType='application/json',extra={}){
 const legacy=version==='2.0';
 return {...(legacy?{swagger:version,consumes:[mediaType]}:{openapi:version}),info:{title:'Schema examples',version:'business'},paths:{'/data':{post:{
  ...(legacy?{parameters:[{in:'body',name:'payload',schema}]}:{requestBody:{content:{[mediaType]:{schema,...extra}}}}),
  responses:{200:{description:'Reply',...(legacy?{schema,examples:{[mediaType]:'Response override'}}:{content:{[mediaType]:{schema,...extra}}})}},
 }}},'x-number':'EXACT'};
}
function input(version,format,schema,mediaType='application/json',extra={}){
 const root='file:///controlled/api.'+format,text=render(document(version,schema,mediaType,extra),format);
 return {root,snapshot:version+format,resource:root,pointer:'/paths/~1data/post',resources:[{id:root,text,generation:7}]};
}
const body=plan=>plan.requestBody.content[0];
const values=[{n:'EXACT',flag:false,empty:'',text:'雪😀',$ref:'literal.json'},null,false,0,'',[],{}];
const exact=value=>JSON.stringify(value).replaceAll('"EXACT"','9007199254740993.00');

for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} schema request choices retain exact values and physical provenance`,()=>{
 for(const value of values){
  const packet=input(version,format,modern(version)?{examples:[value]}:{example:value}),before=packet.resources[0].text;
  const checked=analyse(packet);assert.equal(checked.complete,true);assert.deepEqual(checked.findings,[]);
  const plan=requestOperation(packet),media=body(plan),example=media.example;
  assert.equal(plan.representationRevisions.schemaExamples,'2');assert.equal(media.examples.length,1);
  assert.equal(example.raw,exact(value));assert.equal(example.origin,'schema');assert.equal(example.representation,'json');assert.equal(example.level,'media');
  const owner=version==='2.0'?'/paths/~1data/post/parameters/0/schema':'/paths/~1data/post/requestBody/content/application~1json/schema';
  assert.equal(example.source.resource,packet.root);assert.equal(example.source.pointer,owner+(modern(version)?'/examples/0':'/example'));assert.equal(example.source.generation,7);
  assert(example.source.range[1]>example.source.range[0]);assert.deepEqual(media.schemaExamples,{complete:true,issues:[]});
  assert.equal(packet.resources[0].text,before);
 }
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} schema references keep target choices and family-specific siblings`,()=>{
 const legacy=version==='2.0',base=legacy?'/definitions/':'/components/schemas/',name='Value/~',target=base+escape(name);
 const schema={$ref:'shared.'+format+'#'+base+'Alias',example:'Sibling',...(modern(version)?{examples:[false]}:{})};
 const packet=input(version,format,schema),shared='file:///controlled/shared.'+format;
 const definitions={Alias:{$ref:'#'+target},[name]:{example:{n:'EXACT',$ref:'literal.json'}}};
 packet.resources.push({id:shared,text:render({...legacy?{swagger:version}:{openapi:version},info:{title:'Shared',version:'1'},paths:{},...legacy?{definitions}:{components:{schemas:definitions}}},format),generation:9});
 const before=packet.resources.map(r=>r.text),plan=requestOperation(packet),examples=body(plan).examples;
 assert.deepEqual(examples.map(e=>e.raw),modern(version)?['false','"Sibling"','{"n":9007199254740993.00,"$ref":"literal.json"}']:['{"n":9007199254740993.00,"$ref":"literal.json"}']);
 const referenced=examples.at(-1);assert.equal(referenced.source.resource,shared);assert.equal(referenced.source.pointer,target+'/example');assert.equal(referenced.source.generation,9);
 assert.deepEqual(packet.resources.map(r=>r.text),before);
});
for(const version of versions.filter(v=>v!=='2.0'))for(const format of ['yaml','json'])test(`${version} ${format} explicit media and parameter choices suppress schema fallback`,()=>{
 for(const extra of [{example:false},{examples:{}},{examples:{External:{externalValue:'https://example.invalid/data'}}},{examples:{Missing:{$ref:'#/components/examples/Missing'}}}]){
  const packet=input(version,format,{example:'Schema',...modern(version)?{examples:['Array']} :{}},'application/json',extra),plan=requestOperation(packet),media=body(plan);
  assert.equal(media.examples.length,Object.hasOwn(extra,'example')?1:0);
  if(Object.hasOwn(extra,'example'))assert.equal(media.example.raw,'false');assert.equal(media.schemaExamples,undefined);
  const doc=document(version,{example:'Body'}),parameter={in:'query',name:'value',schema:{example:'Schema'},...extra};
  doc.paths['/data'].post.parameters=[parameter];packet.resources[0].text=render(doc,format);
  const projected=requestOperation(packet).parameters[0];assert.equal(projected.examples.length,Object.hasOwn(extra,'example')?1:0);if(projected.example)assert.equal(projected.example.raw,'false');
 }
});
for(const version of versions.filter(v=>v!=='2.0'))for(const format of ['yaml','json'])test(`${version} ${format} parameter style and content share schema example ownership`,()=>{
 const packet=input(version,format,{example:0}),doc=document(version,{example:0});
 doc.paths['/data'].post.parameters=[{name:'value',in:'query',schema:modern(version)?{examples:[false,0,'']}:{example:false}},{name:'body',in:'header',content:{'application/json':{schema:{example:{n:'EXACT'}}}}}];
 packet.resources[0].text=render(doc,format);const plan=requestOperation(packet);
 assert.equal(plan.parameters[0].example.raw,'false');assert.equal(plan.parameters[0].example.representation,'json');assert.equal(plan.parameters[0].example.level,'parameter');
 assert.equal(plan.parameters[1].content[0].example.raw,'{"n":9007199254740993.00}');assert.equal(plan.parameters[1].content[0].example.level,'media');
 assert.equal(plan.responses[0].content[0].example.raw,'0');
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} recursion and allOf provide candidates without merging branch or child payloads`,()=>{
 const base=version==='2.0'?'/definitions/':'/components/schemas/',packet=input(version,format,{$ref:'#'+base+'Recursive'}),doc=document(version,{$ref:'#'+base+'Recursive'});
 const definitions={Recursive:{allOf:[{$ref:'#'+base+'Recursive'},{example:false},{example:{n:'EXACT'}}],properties:{child:{example:'Child'}},...version!=='2.0'?{oneOf:[{example:'Branch'}]}:{}}};
 if(version==='2.0')doc.definitions=definitions;else doc.components={schemas:definitions};packet.resources[0].text=render(doc,format);
 const media=body(requestOperation(packet));assert.deepEqual(media.examples.map(e=>e.raw),['false','{"n":9007199254740993.00}',...(version==='2.0'?[]:['"Branch"'])]);assert.equal(media.schemaExamples.complete,true);
 assert.deepEqual(media.schemaExamples.issues,[]);
});
for(const version of versions.filter(modern))for(const format of ['yaml','json'])test(`${version} ${format} modern array strings remain data while legacy escaped examples keep their representation`,()=>{
 const packet=input(version,format,{type:'string',examples:['a%20b',''],example:'c%20d'},'application/x-www-form-urlencoded');
 const media=body(requestOperation(packet));assert.deepEqual(media.examples.map(e=>[e.raw,e.representation]),[['"a%20b"','json'],['""','json'],['c%20d','serialized']]);
});
for(const version of versions.filter(modern))for(const format of ['yaml','json'])test(`${version} ${format} unavailable dialects and references explicitly limit schema example discovery`,()=>{
 for(const [schema,code]of [[{$schema:'https://example.invalid/dialect',examples:[false]},'request.schema-examples.dialect'],[{$ref:'missing.json#/Value'},'request.schema-examples.reference']]){
  const packet=input(version,format,schema),media=body(requestOperation(packet));assert.equal(media.examples.length,0);assert.equal(media.schemaExamples.complete,false);assert.equal(media.schemaExamples.issues[0].code,code);assert.equal(media.schemaExamples.issues[0].source.resource,packet.root);
 }
});
test('shared resources and repeated family or unsaved source changes cannot leak schema example semantics',()=>{
 for(let run=0;run<3;run++)for(const version of ['3.2.1','3.0.4','2.0','3.1.2']){
  const packet=input(version,'json',{$ref:'schema.json'});packet.snapshot='captured-'+run+version;
  packet.resources.push({id:'file:///controlled/schema.json',text:'{"example":false,"examples":[0,""]}',generation:run+8});
  const media=body(requestOperation(packet));assert.deepEqual(media.examples.map(e=>e.raw),modern(version)?['0','""','false']:['false']);
  assert(media.examples.every(e=>e.source.generation===run+8));
  packet.resources[1].text='{"example":null,"examples":[false]}';packet.resources[1].generation++;
  assert.deepEqual(body(requestOperation(packet)).examples.map(e=>e.raw),modern(version)?['false','null']:['null']);
 }
});
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])test(`${version} schema aliases retain the physical annotation source without rewriting YAML`,()=>{
 const packet=input(version,'yaml',{$ref:'shared.yaml#/Value'}),shared='file:///controlled/shared.yaml';
 packet.resources.push({id:shared,generation:3,text:'# Preserve anchor\r\nx-schema: &shape\r\n  example: {n: 9007199254740993.00, flag: false}\r\nValue: *shape\r\n'});
 const original=packet.resources[1].text,example=body(requestOperation(packet)).example;
 assert.equal(example.raw,'{"n":9007199254740993.00,"flag":false}');assert.equal(example.source.pointer,'/x-schema/example');
 assert.equal(original.slice(...example.source.range),'{n: 9007199254740993.00, flag: false}');assert.equal(packet.resources[1].text,original);
});
test('modern fixed dynamic references preserve candidates and a competing binding is explicitly incomplete',()=>{
 const packet=input('3.2.1','json',{$dynamicRef:'#Candidate'}),doc=document('3.2.1',{$dynamicRef:'#Candidate'});
 doc.components={schemas:{Value:{$dynamicAnchor:'Candidate',examples:[false]}}};packet.resources[0].text=JSON.stringify(doc);
 let media=body(requestOperation(packet));assert.deepEqual(media.examples.map(e=>e.raw),['false']);assert.equal(media.schemaExamples.complete,true);
 doc.components.schemas.Other={$id:'https://example.invalid/other',$dynamicAnchor:'Candidate',examples:[0]};packet.resources[0].text=JSON.stringify(doc);
 media=body(requestOperation(packet));assert.deepEqual(media.examples,[]);assert.equal(media.schemaExamples.complete,false);assert.equal(media.schemaExamples.issues[0].code,'request.schema-examples.reference');
});
test('schema example discovery reports depth bounds and refuses overflowing choice lists',()=>{
 const packet=input('3.2.1','json',{$ref:'#/components/schemas/V0'}),doc=document('3.2.1',{$ref:'#/components/schemas/V0'});
 doc.components={schemas:Object.fromEntries(Array.from({length:130},(_,i)=>['V'+i,i===129?{examples:[false]}:{$ref:'#/components/schemas/V'+(i+1)}]))};packet.resources[0].text=JSON.stringify(doc);
 const media=body(requestOperation(packet));assert.equal(media.schemaExamples.complete,false);assert.equal(media.schemaExamples.issues[0].code,'limit.request.schema-examples');assert.deepEqual(media.examples,[]);
 const overflow=input('3.2.1','json',{examples:Array(2049).fill(false)});
 assert.throws(()=>requestOperation(overflow),error=>error.code==='limit.request.schema-examples');
});
test('wide schema example discovery stops at exhaustion with one located limit marker',()=>{
 const packet=input('3.2.1','json',{allOf:Array.from({length:2050},()=>({}))}),media=body(requestOperation(packet));
 assert.equal(media.schemaExamples.complete,false);assert.equal(media.schemaExamples.issues.length,1);
 const issue=media.schemaExamples.issues[0];assert.equal(issue.code,'limit.request.schema-examples');assert.equal(issue.source.resource,packet.root);assert(issue.source.range[1]>issue.source.range[0]);
 assert.deepEqual(media.examples,[]);
});
for(const rootVersion of versions.filter(modern))for(const ownerVersion of versions.filter(modern))for(const format of ['yaml','json'])test(`${rootVersion} ${format} request choices retain defining ${ownerVersion} schema semantics`,()=>{
 const packet=input(rootVersion,format,{$ref:'shared.'+format+'#/components/schemas/Value'}),shared='file:///controlled/shared.'+format;
 const source={openapi:ownerVersion,info:{title:'Defining schema',version:'business'},paths:{},components:{schemas:{Value:{examples:[false,0,''],example:null}}}};
 packet.resources.push({id:shared,text:render(source,format),generation:11});
 const original=packet.resources.map(r=>r.text),media=body(requestOperation(packet));
 assert.deepEqual(media.examples.map(e=>e.raw),['false','0','""','null']);assert(media.examples.every(e=>e.source.resource===shared&&e.source.generation===11&&e.representation==='json'));
 assert.deepEqual(media.schemaExamples,{complete:true,issues:[]});assert.deepEqual(packet.resources.map(r=>r.text),original);
 source.components.schemas.Value.$schema='https://example.invalid/dialect';packet.resources[1].text=render(source,format);packet.resources[1].generation++;
 const unavailable=body(requestOperation(packet));assert.deepEqual(unavailable.examples,[]);assert.equal(unavailable.schemaExamples.complete,false);
 assert.equal(unavailable.schemaExamples.issues[0].code,'request.schema-examples.dialect');assert.equal(unavailable.schemaExamples.issues[0].source.resource,shared);assert.equal(unavailable.schemaExamples.issues[0].source.generation,12);
});
for(const format of ['yaml','json'])for(const [kind,extra]of [
 ['body-example',{example:'Wrong'}],['body-examples',{examples:{Named:{value:'Wrong'}}}],
 ['flat',{schema:{example:'WrongSchema'},example:'Wrong',content:{'application/json':{schema:{example:'WrongContent'}}}}],
])test(`Swagger ${format} ${kind} does not reinterpret 3.x parameter fields`,()=>{
 const parameter=kind==='flat'?{in:'query',name:'value',type:'string',...extra}:{in:'body',name:'payload',schema:{example:'Native'},...extra};
 parameter['x-example']={$ref:'literal.json',value:false};
 const packet=input('2.0',format,{example:'Native'}),doc=document('2.0',{example:'Native'});doc.paths['/data'].post.parameters=[parameter];packet.resources[0].text=render(doc,format);
 doc.paths['/data'].post.responses[200].headers={'X-Value':{type:'string',schema:{example:'WrongHeader'},content:{'application/json':{schema:{example:'WrongHeaderContent'}}}}};packet.resources[0].text=render(doc,format);
 const before=packet.resources[0].text,checked=analyse(packet);assert(checked.findings.length>0,'Wrong-family fields remain invalid source');assert(!checked.findings.some(f=>f.code==='reference.missing'));
 const plan=requestOperation(packet);
 const header=plan.responses[0].headers[0];assert.equal(header.type,'string');assert.equal(header.schema.resource,packet.root);assert.equal(header.schema.pointer,'/paths/~1data/post/responses/200/headers/X-Value');assert.deepEqual(header.content,[]);
 if(kind==='flat'){
  const p=plan.parameters[0];assert.equal(p.type,'string');assert.equal(p.schema.resource,packet.root);assert.equal(p.schema.pointer,'/paths/~1data/post/parameters/0');assert.deepEqual(p.examples,[]);assert.equal(p.example,undefined);assert.deepEqual(p.content,[]);
 }else{assert.deepEqual(body(plan).examples.map(e=>e.raw),['"Native"']);assert.equal(body(plan).example.origin,'schema');}
 assert.equal(packet.resources[0].text,before);
});
for(const format of ['yaml','json'])test(`Swagger ${format} a separately referenced schema role does not change parameter-field grammar`,()=>{
 const packet=input('2.0',format,{example:'Native'}),doc=document('2.0',{example:'Native'}),pointer='/paths/~1data/post/parameters/0/schema';
 doc.paths['/data'].post.parameters=[{name:'value',in:'query',type:'string',schema:{example:'Separately interpreted'}}];
 doc.definitions={ExplicitSchema:{$ref:'#'+pointer}};packet.resources[0].text=render(doc,format);
 assert.equal(createGraph(packet).graph.scopeAs(packet.root,pointer,'schema').kind,'schema');
 const parameter=requestOperation(packet).parameters[0];assert.equal(parameter.schema.resource,packet.root);assert.equal(parameter.schema.pointer,'/paths/~1data/post/parameters/0');assert.equal(parameter.example,undefined);assert.deepEqual(parameter.examples,[]);assert.equal(parameter.type,'string');
});
