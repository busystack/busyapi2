const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {SourceDocument,RawJsonValue}=require('./dist/document.cjs');
const {propose,analyse}=require('./dist/model.cjs');
const {semanticSearch}=require('./dist/source_assistance.cjs');
const {planRename}=require('./dist/refactoring.cjs');
const root='file:///integrity/openapi.yaml';
function input(text){return {root,snapshot:'integrity',resources:[{id:root,generation:1,text}]};}
function apply(text,plan){for(const e of [...plan.edits].sort((a,b)=>b.start-a.start)){assert.equal(text.slice(e.start,e.end),e.expected);text=text.slice(0,e.start)+e.replacement+text.slice(e.end);}return text;}
const header='openapi: 3.2.1\ninfo: {title: API, version: "1"}\npaths: {}\n';
test('R02 mapping removal keeps its owning sequence and nearby source',()=>{
 const cases=[
  ['servers:\n  - description: First\n    url: https://first.example\n','/servers/0/description',[{url:'https://first.example'}]],
  ['servers:\n  - description: First\n    # URL stays\n    url: https://first.example\n  - url: https://second.example\n','/servers/0/description',[{url:'https://first.example'},{url:'https://second.example'}]],
  ['servers:\n  - url: https://first.example\n    description: First\n    x-last: keep\n','/servers/0/description',[{url:'https://first.example','x-last':'keep'}]],
  ['servers:\n  - url: https://first.example\n    description: First\n','/servers/0/description',[{url:'https://first.example'}]],
  ['x-nested:\n  - description: First\n','/x-nested/0/description',[{}]],
  ['x-nested:\n  - - description: First\n      url: https://first.example\n','/x-nested/0/0/description',[[{url:'https://first.example'}]]],
 ];
 for(const [body,pointer,expected]of cases)for(const newline of ['\n','\r\n']){
  const text=(header+body+'# untouched tail\nx-tail: true\n').replaceAll('\n',newline),doc=new SourceDocument(text,root);
  const low=doc.remove(pointer),plan=propose({...input(text),target:{resource:root,generation:1,pointer},actions:[{kind:'remove',pointer}]});
  const changed=apply(text,plan);assert.equal(changed,low);
  const value=YAML.parse(changed);assert.deepEqual(value[pointer.startsWith('/servers')?'servers':'x-nested'],expected);
  assert(changed.startsWith(header.replaceAll('\n',newline)));assert(changed.endsWith(('# untouched tail\nx-tail: true\n').replaceAll('\n',newline)));
  if(body.includes('# URL stays'))assert(changed.includes('# URL stays'));
  if(newline==='\r\n')assert(!/(?<!\r)\n/.test(changed));
 }
});
test('R03 implicit null replacements preserve value and comment separation',()=>{
 for(const version of ['3.1.2','3.2.1'])for(const comment of ['', ' # documented empty default'])for(const kind of ['set','setData'])for(const raw of ['"hello"','"hello\\nworld"','true','9007199254740993.00','{"a":[1,null]}']){
  for(const [body,pointer]of [[`default:${comment}\n`,'/components/schemas/Model/default'],[`examples:\n  -${comment}\n`,'/components/schemas/Model/examples/0']]){
   const text=header.replace('3.2.1',version)+'components:\n  schemas:\n    Model:\n'+body.split('\n').filter(Boolean).map(line=>'      '+line).join('\n')+'\n      type: [string, "null"]\nx-number: 9007199254740993.00\n';
   const value=kind==='set'?JSON.parse(raw):undefined;
   const plan=propose({...input(text),target:{resource:root,generation:1,pointer},actions:[{kind,pointer,...(kind==='set'?{value}:{raw})}]});
   const changed=apply(text,plan),doc=new SourceDocument(changed,root);
   assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));
   if(kind==='setData')assert.equal(doc.dataJson(pointer),raw);
   if(comment)assert(changed.includes('# documented empty default'));
   assert(changed.endsWith('x-number: 9007199254740993.00\n'));
  }
 }
 const text=header+'components: {schemas: {Model: {default: null, type: [string, "null"]}}}\n';
 const pointer='/components/schemas/Model/default';
 const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[{kind:'set',pointer,value:'hello'}]}));
 assert.equal(new SourceDocument(changed,root).node(pointer).value,'hello');
 const {assistSource}=require('./dist/source_assistance.cjs');
 for(const version of ['3.1.2','3.2.1'])for(const comment of ['', ' # preserved'])for(const [field,label,value]of [['type','string','string'],['deprecated','false',false]]){
  const text=header.replace('3.2.1',version)+`components:\n  schemas:\n    Model:\n      ${field}:${comment}\n`,pointer='/components/schemas/Model/'+field,doc=new SourceDocument(text,root);
  const choice=assistSource({...input(text),resource:root,caret:doc.node(pointer).range[0]}).completions.find(c=>c.label===label);assert(choice);
  const changed=apply(text,choice);assert.equal(new SourceDocument(changed,root).node(pointer).value,value);if(comment)assert(changed.includes(comment));
 }
});
test('R06 alias scopes retain semantic search and unrelated rename',()=>{
 const text=header.replace('paths: {}','paths: {"/test": {get: {summary: Test, responses: {"200": {description: ok}}}}}')+'components:\n  schemas:\n    A: &shared\n      type: object\n      properties:\n        id: {type: string}\n    B: *shared\n    C: &shared {type: boolean}\n    D: *shared\n    Unrelated: {type: string}\n';
 assert.equal(analyse(input(text)).findings.length,0);
 assert.equal(semanticSearch({...input(text),query:'Test',category:'operations'}).matches.length,1);
 const components=semanticSearch({...input(text),query:'B',category:'components'}).matches;
 assert(components.some(m=>m.pointer==='/components/schemas/B'&&m.range[1]>m.range[0]));
 const plan=planRename({...input(text),contexts:[{root,resources:[root]}],target:{resource:root,generation:1,pointer:'/components/schemas/Unrelated'},name:'Renamed'});
 assert(apply(text,plan).includes('Renamed: {type: string}'));
 assert(apply(text,plan).includes('D: *shared'));
});
const {planPropertyRename}=require('./dist/refactoring.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
test('R05 a nested composition property rename preserves enclosing and sibling instance constraints',async()=>{
 for(const version of ['3.1.2','3.2.1']){
  const model={type:'object',required:['old'],allOf:[{properties:{old:{type:'string'}}},{dependentRequired:{other:['old']},dependentSchemas:{old:{required:['old']}}}],properties:{nested:{type:'object',properties:{old:{type:'string'}},required:['old']}},$defs:{Unused:{properties:{old:{type:'string'}},required:['old']}},examples:[{old:'literal'}]};
  const value={openapi:version,info:{title:'Rename',version:'1'},paths:{},components:{schemas:{Model:model}}};
  const text=YAML.stringify(value),target={resource:root,generation:1,pointer:'/components/schemas/Model/allOf/0/properties/old'},before=input(text);
  const check=async(snapshot,instance)=>(await evaluateSchemas({...snapshot,runtimeInstances:[{subject:'renamed',location:'json',text:JSON.stringify(instance),schema:{resource:root,pointer:'/components/schemas/Model'}}]})).runtimeEvaluations[0];
  assert.equal((await check(before,{old:'ok'})).valid,true);
  const plan=planPropertyRename({...before,contexts:[{root,resources:[root]}],target,name:'new'}),changed=apply(text,plan),after=input(changed);
  assert.deepEqual(YAML.parse(changed).components.schemas.Model.required,['new']);
  assert.equal((await check(after,{new:'ok'})).valid,true);
  assert.equal((await check(after,{old:'ok'})).valid,false);
  assert.equal((await check(after,{new:'ok',other:true,nested:{old:'child'}})).valid,true);
  const actual=YAML.parse(changed).components.schemas.Model;
  assert.deepEqual(actual.allOf[1].dependentRequired.other,['new']);assert.deepEqual(actual.allOf[1].dependentSchemas.new.required,['new']);
  assert.deepEqual(actual.properties.nested.required,['old']);assert.deepEqual(actual.$defs.Unused.required,['old']);assert.deepEqual(actual.examples,[{old:'literal'}]);
  const collision=YAML.stringify({...value,components:{schemas:{Model:{...model,allOf:[model.allOf[0],{properties:{new:{type:'boolean'}}}]}}}});
  assert.throws(()=>planPropertyRename({...input(collision),contexts:[{root,resources:[root]}],target,name:'new'}),e=>e.code==='edit.collision');
 }
});
test('R06 unrelated component rename is independent of physical alias descendants',()=>{
 const text=header+'components:\n  schemas:\n    A: &shared {type: object, properties: {id: {type: string}}}\n    B: *shared\n    Unrelated: {type: string}\n';
 const plan=planRename({...input(text),contexts:[{root,resources:[root]}],target:{resource:root,generation:1,pointer:'/components/schemas/Unrelated'},name:'Renamed'});
 assert(apply(text,plan).includes('Renamed: {type: string}'));
});
test('R06-A inspection navigates a resolved alias descendant with both coordinates',()=>{
 const {inspect}=require('./dist/model.cjs');
 const text=header+'components:\n  schemas:\n    A: &shared {type: object, properties: {id: {type: string}}}\n    B: *shared\n    Use: {$ref: "#/components/schemas/B/properties/id"}\n';
 assert.equal(analyse(input(text)).references[0].resolution,'resolved');
 const view=inspect({...input(text),resource:root,pointer:'/components/schemas/Use'});
 const target=view.references[0].target;
 assert.equal(target.pointer,'/components/schemas/B/properties/id');assert.equal(target.physicalPointer,'/components/schemas/A/properties/id');
 assert.equal(text.slice(...target.occurrenceRange),'*shared');assert.equal(text.slice(...target.range),'{type: string}');
});
test('R02 sequence-member controls remove their own marker but retain compact ancestors',()=>{
 for(const [body,pointer,expected]of [
  ['servers:\n  - url: https://first.example\n','/servers/0',[]],
  ['servers:\n  - url: https://first.example\n  - url: https://last.example\n','/servers/0',[{url:'https://last.example'}]],
  ['x-nested:\n  - - first\n','/x-nested/0/0',[[]]],
  ['x-nested:\n  - - first\n    - last\n','/x-nested/0/0',[['last']]],
 ]){
  const changed=new SourceDocument(header+body,root).remove(pointer);
  assert.deepEqual(YAML.parse(changed)[pointer.startsWith('/servers')?'servers':'x-nested'],expected);
 }
});
test('R04 operation response relocation repairs consumers and combines field changes',()=>{
 const {planResponseRename}=require('./dist/refactoring.cjs');
 for(const version of ['3.1.2','3.2.1']){
  const value={openapi:version,info:{title:'Response',version:'1'},paths:{'/pets':{get:{responses:{200:{description:'before'}}}}},components:{responses:{Use:{$ref:'#/paths/~1pets/get/responses/200'}}}};
  const text=YAML.stringify(value),target={resource:root,generation:1,pointer:'/paths/~1pets/get/responses/200'},initial=input(text);
  assert.equal(analyse(initial).references[0].resolution,'resolved');
  const plan=planResponseRename({...initial,contexts:[{root,resources:[root]}],target,name:'201',actions:[{kind:'set',pointer:target.pointer+'/description',value:'after'}]});
  const changed=apply(text,plan),actual=YAML.parse(changed);
  assert.equal(actual.paths['/pets'].get.responses[201].description,'after');assert.equal(actual.components.responses.Use.$ref,'#/paths/~1pets/get/responses/201');assert.equal(analyse(input(changed)).references[0].resolution,'resolved');
  assert.throws(()=>planResponseRename({...initial,contexts:[{root,resources:[root]}],target:{...target,range:[0,1]},name:'201'}),e=>e.code==='edit.stale');
  assert.throws(()=>planResponseRename({...initial,contexts:[{root,resources:[root]}],target:{...target,pointer:'/components/responses/Use'},name:'201'}),e=>e.code==='refactor.response.context');
 }
});
test('R04 property form changes use the relocated target and requested membership atomically',()=>{
 const text=header+'components:\n  schemas:\n    Model: {type: object, required: [old], properties: {old: {type: string}}, dependentRequired: {other: [old]}}\n    Use: {$ref: "#/components/schemas/Model/properties/old"}\n';
 const target={resource:root,generation:1,pointer:'/components/schemas/Model/properties/old'};
 for(const required of [true,false]){
  const plan=planPropertyRename({...input(text),contexts:[{root,resources:[root]}],target,name:'new',actions:[{kind:'set',pointer:target.pointer+'/type',value:'boolean'},{kind:'setRequired',pointer:'/components/schemas/Model',name:'new',required}]});
  const value=YAML.parse(apply(text,plan)).components.schemas;
  assert.equal(value.Model.properties.new.type,'boolean');assert.equal(value.Model.required.includes('new'),required);assert.deepEqual(value.Model.dependentRequired.other,['new']);assert.equal(value.Use.$ref,'#/components/schemas/Model/properties/new');
 }
});
test('R03-A replacing an existing block collection keeps its enclosing indentation',()=>{
 const text=header+'components:\n  schemas:\n    Model:\n      type:\n        - string\n      description: keep # unchanged\n';
 const pointer='/components/schemas/Model/type';
 const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[{kind:'set',pointer,value:['string','null']}]}));
 const doc=new SourceDocument(changed,root);assert.deepEqual(doc.node(pointer).value,['string','null']);assert(changed.includes('      description: keep # unchanged\n'));
});

test('R03 implicit null repair retains unrelated authored syntax errors',()=>{
 const text=header+'components:\n  schemas:\n    Model:\n      default: # keep\n      type: [string, "null"]\nx-broken: [unfinished\n';
 const pointer='/components/schemas/Model/default',before=new SourceDocument(text,root,true);
 assert(before.issues.length>0);assert(before.syntaxSafe(pointer));
 const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[{kind:'setData',pointer,raw:'"hello"'}]}));
 const after=new SourceDocument(changed,root,true);assert.equal(after.node(pointer).value,'hello');assert.equal(after.issues.length,before.issues.length);assert(changed.endsWith('x-broken: [unfinished\n'));
});
test('R05 nested dependent-schema ownership keeps combined edits and final navigation together',()=>{
 const text=header+'components:\n  schemas:\n    Model: {type: object, required: [old], dependentSchemas: {old: {properties: {old: {type: string}}}}}\n';
 const pointer='/components/schemas/Model/dependentSchemas/old/properties/old',owner='/components/schemas/Model/dependentSchemas/old';
 const plan=planPropertyRename({...input(text),contexts:[{root,resources:[root]}],target:{resource:root,generation:1,pointer},name:'new',actions:[{kind:'set',pointer:pointer+'/description',value:'combined'},{kind:'setRequired',pointer:owner,name:'new',required:true}]});
 const changed=apply(text,plan),doc=new SourceDocument(changed,root);
 assert.equal(plan.to.pointer,'/components/schemas/Model/dependentSchemas/new/properties/new');
 assert.equal(doc.node(plan.to.pointer+'/description').value,'combined');assert.deepEqual(doc.node('/components/schemas/Model/dependentSchemas/new/required').value,['new']);
});
test('R06-A semantic usages retain alias occurrence and physical scalar ranges',()=>{
 const text=header+'components:\n  schemas:\n    Target: {type: string}\n    A: &shared {$ref: "#/components/schemas/Target"}\n    B: *shared\n';
 const matches=semanticSearch({...input(text),query:'Target',category:'usages'}).matches;
 assert.equal(matches.length,2);
 for(const match of matches)assert(Array.isArray(match.range)&&match.range[1]>match.range[0]);
 const alias=matches.find(m=>m.pointer==='/components/schemas/B/$ref');
 assert.equal(alias.physicalPointer,'/components/schemas/A/$ref');assert.equal(text.slice(...alias.occurrenceRange),'*shared');
});
test('R05-A property rename refuses collisions in required and dependent name lists',()=>{
 for(const version of ['3.1.2','3.2.1'])for(const relationship of [{required:['old','new']},{dependentRequired:{other:['old','new']}}]){
  const text=YAML.stringify({openapi:version,info:{title:'Collision',version:'1'},paths:{},components:{schemas:{Model:{type:'object',properties:{old:{type:'string'}},...relationship}}}});
  assert.equal(analyse(input(text)).findings.length,0);
  assert.throws(()=>planPropertyRename({...input(text),contexts:[{root,resources:[root]}],target:{resource:root,generation:1,pointer:'/components/schemas/Model/properties/old'},name:'new'}),e=>e.code==='edit.collision');
 }
});

test('R03-B collection to multiline string preserves nested compact sequence positions',()=>{
 for(const version of ['3.1.2','3.2.1'])for(const newline of ['\n','\r\n'])for(const kind of ['set','setData']){
  const text=(header.replace('3.2.1',version)+'components:\n  schemas:\n    Model:\n      default:\n        - - a: one\n            b: two\n          - last\n      description: keep # surrounding\n').replaceAll('\n',newline);
  const pointer='/components/schemas/Model/default';assert.equal(analyse(input(text)).findings.length,0);
  const value=[['hello\nworld','last']],action=kind==='set'?{kind,pointer,value}:{kind,pointer,raw:JSON.stringify(value)};
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[action]})),parsed=new SourceDocument(changed,root);
  assert.deepEqual(parsed.node(pointer).value,value);assert(changed.endsWith(('      description: keep # surrounding\n').replaceAll('\n',newline)));
  if(newline==='\r\n')assert(!/(?<!\r)\n/.test(changed));
 }
});
test('R05-B aliased same-instance constraint collections require explicit ownership',async()=>{
 for(const version of ['3.1.2','3.2.1'])for(const relation of [
  ['names','[old]','required: *names'],
  ['deps','{other: [old]}','dependentRequired: *deps'],
  ['names','[old]','dependentRequired: {other: *names}'],
  ['branches','[{required: [old]}]','allOf: *branches'],
  ['schemas','{old: {required: [old]}}','dependentSchemas: *schemas'],
  ['disc','{propertyName: old}','discriminator: *disc'],
  ['name','old','required: [*name]'],
  ['name','old','discriminator: {propertyName: *name}'],
 ]){
  const [anchor,value,field]=relation,text=header.replace('3.2.1',version)+`x-shared: &${anchor} ${value}\ncomponents:\n  schemas:\n    Model:\n      type: object\n      properties: {old: {type: string}}\n      ${field}\n${field.startsWith('discriminator:')?'      allOf: [true]\n':''}`;
  assert.equal(analyse(input(text)).findings.length,0);
  const evaluation=await evaluateSchemas({...input(text),runtimeInstances:[{subject:'shared',location:'json',text:'{"old":"ok","other":true}',schema:{resource:root,pointer:'/components/schemas/Model'}}]});
  assert.equal(evaluation.runtimeEvaluations[0].valid,true);
  assert.throws(()=>planPropertyRename({...input(text),contexts:[{root,resources:[root]}],target:{resource:root,generation:1,pointer:'/components/schemas/Model/properties/old'},name:'new'}),e=>e.code==='refactor.property.shared');
 }
});

test('R03-C existing block scalars retain complete requested whitespace',()=>{
 for(const version of ['3.1.2','3.2.1'])for(const newline of ['\n','\r\n'])for(const style of ['|-','>-'])for(const kind of ['set','setData'])for(const value of ['hello\nworld\n\n','hello\nworld  ','hello\n\nworld\n\n',' leading\nworld','\n',' \n  ','hello\nworld']){
  const prefix=header.replace('3.2.1',version)+'components:\n  schemas:\n    Model:\n      default:\n        # before value\n        message: ',suffix='        keep: unchanged # after value\nx-number: 9007199254740993.00\n';
  const text=(prefix+style+'\n          original\n          text\n'+suffix).replaceAll('\n',newline),pointer='/components/schemas/Model/default/message';
  const action=kind==='set'?{kind,pointer,value}:{kind,pointer,raw:JSON.stringify(value)};
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[action]}));
  assert.equal(new SourceDocument(changed,root).node(pointer).value,value,JSON.stringify({version,newline,style,kind,value}));
  assert(changed.startsWith(prefix.replaceAll('\n',newline)));assert(changed.endsWith(suffix.replaceAll('\n',newline)));
  if(newline==='\r\n')assert(!/(?<!\r)\n/.test(changed));
 }
});
test('R03-D collection emission retains trailing block-string data',()=>{
 for(const newline of ['\n','\r\n'])for(const kind of ['set','setData'])for(const value of [{message:'hello\nworld\n\n'},{message:'hello\nworld  '},{message:'hello\nworld\n'},['hello\n\nworld\n\n']]){
  const text=(header+'components:\n  schemas:\n    Model:\n      default: {old: value}\n      description: keep # surrounding\n').replaceAll('\n',newline),pointer='/components/schemas/Model/default';
  // Also exercise a block collection target: a flow target intentionally
  // emits JSON and does not reach the shared YAML serializer.
  const block=text.replace('{old: value}','\n        old: value'.replaceAll('\n',newline));
  const action=kind==='set'?{kind,pointer,value}:{kind,pointer,raw:JSON.stringify(value)};
  for(const source of [text,block]){
   const changed=apply(source,propose({...input(source),target:{resource:root,generation:1,pointer},actions:[action]}));
   assert.deepEqual(new SourceDocument(changed,root).node(pointer).value,value);
   assert(changed.endsWith(('      description: keep # surrounding\n').replaceAll('\n',newline)));
  }
 }
});
test('R03-C block scalar edits retain whitespace at compact and EOF boundaries',()=>{
 for(const newline of ['\n','\r\n'])for(const finalNewline of ['',newline])for(const value of ['hello\nworld\n\n','hello\nworld\n','hello\nworld','hello\nworld  ']){
  const text=(header+'components:\n  schemas:\n    Model:\n      default:\n        - - |-\n              original\n              text').replaceAll('\n',newline)+finalNewline,pointer='/components/schemas/Model/default/0/0';
  const doc=new SourceDocument(text,root),changed=doc.set(pointer,value);
  assert.equal(new SourceDocument(changed,root).node(pointer).value,value);
  const collection=doc.set('/components/schemas/Model/default',{message:value});
  assert.deepEqual(new SourceDocument(collection,root).node('/components/schemas/Model/default').value,{message:value});
 }
});
test('R03-E block scalar header comments survive retained and quoted replacements',()=>{
 const note='# preserve this user note # exactly';
 for(const version of ['3.1.2','3.2.1'])for(const newline of ['\n','\r\n'])for(const style of ['|-','>-'])for(const kind of ['set','setData'])for(const value of ['hello\nworld','hello\n# scalar data\n\n']){
  const prefix=header.replace('3.2.1',version)+'components:\n  schemas:\n    Model:\n      description: ',suffix='      type: string # sibling\n';
  const text=(prefix+style+'  '+note+'\n        original # scalar data\n        text\n'+suffix).replaceAll('\n',newline),pointer='/components/schemas/Model/description';
  const action=kind==='set'?{kind,pointer,value}:{kind,pointer,raw:JSON.stringify(value)};
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[action]})),doc=new SourceDocument(changed,root);
  assert.equal(doc.node(pointer).value,value);
  assert(changed.includes('  '+note+newline));
  assert.deepEqual(doc.comments('/components/schemas/Model').map(r=>changed.slice(...r)),[note,'# sibling']);
  assert(changed.startsWith(prefix.replaceAll('\n',newline)));assert(changed.endsWith(suffix.replaceAll('\n',newline)));
  if(newline==='\r\n')assert(!/(?<!\r)\n/.test(changed));
 }
 for(const kind of ['set','setData']){
  const text=header+'components:\n  schemas:\n    Model:\n      description: |-\n        # this is scalar data\n        text\n      type: string\n',pointer='/components/schemas/Model/description',value='hello\n# new scalar data';
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[kind==='set'?{kind,pointer,value}:{kind,pointer,raw:JSON.stringify(value)}]})),doc=new SourceDocument(changed,root);
  assert.equal(doc.node(pointer).value,value);assert.deepEqual(doc.comments('/components/schemas/Model'),[]);
 }
 for(const raw of ['true','null','["# scalar data"]','{"n":9007199254740993.00}']){
  const text=header+'components:\n  schemas:\n    Model:\n      default: |-  '+note+'\n        original\n      type: object\n',pointer='/components/schemas/Model/default';
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[{kind:'setData',pointer,raw}]})),doc=new SourceDocument(changed,root);
  assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert(changed.includes('  '+note+'\n'));
  assert.deepEqual(doc.comments('/components/schemas/Model').map(r=>changed.slice(...r)),[note]);
  if(raw.startsWith('{'))assert(doc.dataJson(pointer).includes('9007199254740993.00'));
 }
});
test('R03-F multiline exact JSON replacing a YAML scalar retains valid indentation',()=>{
 const raw='{\n"n":9007199254740993.00\n}';
 for(const newline of ['\n','\r\n'])for(const initial of ['|- # keep\n        original','null','']){
  const text=(header+'components:\n  schemas:\n    Model:\n      default: '+initial+'\n      type: object\n').replaceAll('\n',newline),pointer='/components/schemas/Model/default';
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer},actions:[{kind:'setData',pointer,raw}]})),doc=new SourceDocument(changed,root);
  assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert(doc.dataJson(pointer).includes('9007199254740993.00'));assert(changed.endsWith('      type: object'+newline));
  if(initial.startsWith('|'))assert(changed.includes('# keep'+newline));
 }
 const id=root.replace('.yaml','.json'),text=JSON.stringify({openapi:'3.1.2',info:{title:'API',version:'1'},paths:{},components:{schemas:{Model:{default:'old'}}}}),pointer='/components/schemas/Model/default';
 const changed=apply(text,propose({root:id,resources:[{id,generation:1,text}],target:{resource:id,generation:1,pointer},actions:[{kind:'setData',pointer,raw}]}));
 assert.deepEqual(JSON.parse(changed).components.schemas.Model.default,JSON.parse(raw));assert(changed.includes('9007199254740993.00'));
});
test('R03-F whole-default edits respect compact mapping and flow contexts',()=>{
 const fixtures=[
  ['mapping','value: null\nkeep: yes','{"value":VALUE,"keep":"yes"}'],
  ['sequence','- null\n- yes','[VALUE,"yes"]'],
  ['compact','- value: null\n  keep: yes','[{"value":VALUE,"keep":"yes"}]'],
  ['nested compact','- - value: null\n    keep: yes','[[{"value":VALUE,"keep":"yes"}]]'],
  ['compact flow mapping','- nested: {value: null}\n  keep: yes','[{"nested":{"value":VALUE},"keep":"yes"}]'],
  ['compact flow sequence','- value: [null]\n  keep: yes','[{"value":[VALUE],"keep":"yes"}]'],
  ['flow container replacement','- value: {old: yes}\n  keep: yes','[{"value":VALUE,"keep":"yes"}]'],
  ['nested flow containers','- value: {inner: [null]}\n  keep: yes','[{"value":{"inner":[VALUE]},"keep":"yes"}]'],
  ['flow control','[{value: null, keep: yes}]','[{"value":VALUE,"keep":"yes"}]'],
 ];
 const failures=[];
 for(const version of ['3.1.2','3.2.1'])for(const newline of ['\n','\r\n'])for(const [label,body,template]of fixtures)for(const value of ['{\n"n":9007199254740993.00\n}','[\n9007199254740993.00\n]']){
  const prefix=header.replace('3.2.1',version)+'components:\n  schemas:\n    Model:\n      default:\n',suffix='      description: sentinel # retained\nx-number: 9007199254740993.00\n';
  const text=(prefix+body.split('\n').map(line=>'        '+line).join('\n')+'\n'+suffix).replaceAll('\n',newline),pointer='/components/schemas/Model/default',raw=template.replace('VALUE',value);
  assert.equal(analyse(input(text)).findings.length,0);assert.doesNotThrow(()=>JSON.parse(raw));
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw}]}));
  try{
   const doc=new SourceDocument(changed,root);
   assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert(doc.dataJson(pointer).includes('9007199254740993.00'));
   assert.equal(analyse(input(changed)).findings.length,0);assert(changed.startsWith(prefix.replaceAll('\n',newline)));assert(changed.endsWith(suffix.replaceAll('\n',newline)));
   if(newline==='\r\n')assert(!/(?<!\r)\n/.test(changed));
  }catch(e){failures.push({version,newline,label,kind:value[0],error:e.code??e.message});}
 }
 assert.deepEqual(failures,[]);
});
test('R03-F compact whole-default insertions and block strings retain their context',()=>{
 const failures=[];
 for(const [body,raw]of [
  ['- {keep: yes}','[{"keep":"yes","value":{"n":\n9007199254740993.00\n}}]'],
  ['- value: [1]\n  keep: yes','[{"value":[1,{"n":\n9007199254740993.00\n}],"keep":"yes"}]'],
  ['- value: # retained header\n  keep: yes','[{"value":{"n":\n9007199254740993.00\n},"keep":"yes"}]'],
  ['- value: |- # retained header\n    old\n    text\n  keep: yes','[{"value":"hello\\nworld","keep":"yes"}]'],
  ['- value: |- # retained header\n    old\n    text\n  keep: yes',JSON.stringify([{value:'hello '.repeat(15)+'\nworld  \n\n',keep:'yes'}])],
 ]){
  const text=header+'components:\n  schemas:\n    Model:\n      default:\n'+body.split('\n').map(line=>'        '+line).join('\n')+'\n      description: sentinel\n',pointer='/components/schemas/Model/default';
  assert.equal(analyse(input(text)).findings.length,0);
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw}]}));
  try{const doc=new SourceDocument(changed,root);assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert.equal(analyse(input(changed)).findings.length,0);if(raw.includes('9007199254740993.00'))assert(doc.dataJson(pointer).includes('9007199254740993.00'));if(body.includes('#'))assert(changed.includes('# retained header\n'));}catch(e){failures.push({body,error:e.code??e.message});}
 }
 assert.deepEqual(failures,[]);
});
test('R03-G whole-default flow insertions respect authored trailing commas',()=>{
 const failures=[];
 for(const version of ['3.1.2','3.2.1'])for(const newline of ['\n','\r\n'])for(const mapping of [true,false])for(const multiline of [false,true])for(const trailing of [false,true]){
  const collection=mapping?'{keep: yes'+(trailing?',':'')+'}':'[yes'+(trailing?',':'')+']';
  const prefix=header.replace('3.2.1',version)+'components:\n  schemas:\n    Model:\n      default:\n',suffix='      description: sentinel # untouched\n';
  const text=(prefix+'        - '+collection+'\n'+suffix).replaceAll('\n',newline),pointer='/components/schemas/Model/default';
  const value=multiline?'{\n"n":9007199254740993.00\n}':'{"n":9007199254740993.00}',raw=mapping?'[{"keep":"yes","value":'+value+'}]':'[["yes",'+value+']]';
  assert.equal(analyse(input(text)).findings.length,0);
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw}]}));
  try{const doc=new SourceDocument(changed,root);assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert(doc.dataJson(pointer).includes('9007199254740993.00'));assert.equal(analyse(input(changed)).findings.length,0);assert(changed.startsWith((prefix+'        - '+collection.slice(0,-1)).replaceAll('\n',newline)));assert.equal(changed.includes(mapping?',}':',]'),trailing);assert(changed.endsWith(suffix.replaceAll('\n',newline)));}catch(e){failures.push({version,newline,mapping,multiline,trailing,error:e.code??e.message});}
 }
 assert.deepEqual(failures,[]);
});
test('R03-G flow separator tokens preserve comments commas in data and empty controls',()=>{
 const bodies=[
  ['{keep: yes, # collection note\n          }','[{"keep":"yes","value":{"n":\n9007199254740993.00\n}}]'],
  ['[yes, # collection note\n          ]','[["yes",{"n":\n9007199254740993.00\n}]]'],
  ['{keep: yes # collection note\n          }','[{"keep":"yes","value":{"n":9007199254740993.00}}]'],
  ['[yes # collection note\n          ]','[["yes",{"n":9007199254740993.00}]]'],
  ['{keep: yes, other: 1}','[{"keep":"yes","other":1,"value":{"n":9007199254740993.00}}]'],
  ['[yes, 1,]','[["yes",1,{"n":9007199254740993.00}]]'],
  ['{keep: yes,}','[{"keep":"yes","first":{"n":9007199254740993.00},"second":true}]'],
  ['{keep: "yes,"}','[{"keep":"yes,","value":1}]'],
  ['{keep: yes, :}','[{"keep":"yes","":null,"value":1}]'],
  ['{keep: yes, ?}','[{"keep":"yes","":null,"value":1}]'],
  ['{keep: yes, : ,}','[{"keep":"yes","":null,"value":1}]'],
  ['{keep: yes, ? ,}','[{"keep":"yes","":null,"value":1}]'],
  ['{ # collection note,\n          }','[{"value":1}]'],
  ['[ # collection note,\n          ]','[[1]]'],
 ];
 for(const newline of ['\n','\r\n'])for(const [body,raw]of bodies){
  const text=(header+'components:\n  schemas:\n    Model:\n      default:\n        - '+body+'\n      description: sentinel\n').replaceAll('\n',newline),pointer='/components/schemas/Model/default';
  assert.equal(analyse(input(text)).findings.length,0);
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw}]})),doc=new SourceDocument(changed,root);
  assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert.equal(analyse(input(changed)).findings.length,0);
  for(const range of new SourceDocument(text,root).comments('/components/schemas/Model'))assert(changed.includes(text.slice(...range)));
 }
 const text=header+'components: {schemas: {Model: {default: {keep: yes,}}}}\n';
 const doc=new SourceDocument(text,root),changed=doc.set('/components/schemas/Model/default/value',true);
 assert.deepEqual(new SourceDocument(changed,root).node('/components/schemas/Model/default').value,{keep:'yes',value:true});
});
test('R03-H sole flow-member deletion retires its trailing separator',()=>{
 for(const mapping of [true,false])for(const comment of ['', ' # collection note\n          '])for(const replacement of ['empty','new']){
  const body=mapping?'{keep: yes,'+comment+'}':'[yes,'+comment+']';
  const text=header+'components:\n  schemas:\n    Model:\n      default:\n        - '+body+'\n      description: sentinel\n',pointer='/components/schemas/Model/default';
  const raw=mapping?(replacement==='empty'?'[{}]':'[{"value":{"n":9007199254740993.00}}]'):(replacement==='empty'?'[[]]':'[[{"n":9007199254740993.00}]]');
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw}]})),doc=new SourceDocument(changed,root);
  assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert.equal(analyse(input(changed)).findings.length,0);if(comment)assert(changed.includes('# collection note'));
  if(replacement==='empty')assert.deepEqual(new SourceDocument(new SourceDocument(text,root).remove(pointer+'/0/'+(mapping?'keep':'0')),root).node(pointer).value,JSON.parse(raw));
 }
});
test('R03-H flow member bounds include explicit keys and valueless entries',()=>{
 const failures=[];
 for(const version of ['3.1.2','3.2.1'])for(const newline of ['\n','\r\n'])for(const member of ['? keep: yes','keep','? keep','? keep:','keep: null'])for(const trailing of [false,true])for(const position of ['sole','first','middle','last']){
  const members=position==='sole'?[member]:position==='first'?[member,'after: two']:position==='middle'?['before: one',member,'after: two']:['before: one',member];
  const expected=position==='sole'?{}:position==='first'?{after:'two'}:position==='middle'?{before:'one',after:'two'}:{before:'one'};
  const prefix=header.replace('3.2.1',version)+'components:\n  schemas:\n    Model:\n      default:\n',suffix='      description: sentinel # untouched\n';
  const text=(prefix+'        - {'+members.join(', ')+(trailing?',':'')+'}\n'+suffix).replaceAll('\n',newline),pointer='/components/schemas/Model/default';
  assert.equal(analyse(input(text)).findings.length,0);
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:JSON.stringify([expected])}]}));
  try{const doc=new SourceDocument(changed,root);assert.deepEqual(doc.node(pointer).value,[expected]);assert.equal(analyse(input(changed)).findings.length,0);assert(changed.startsWith(prefix.replaceAll('\n',newline)));assert(changed.endsWith(suffix.replaceAll('\n',newline)));}catch(e){failures.push({version,newline,member,trailing,position,error:e.code??e.message});}
 }
 assert.deepEqual(failures,[]);
});
test('R03-H flow removal retains surrounding separator comments and pair syntax',()=>{
 for(const newline of ['\n','\r\n'])for(const body of [
  '{? keep: yes, # collection note\n          }',
  '{keep # key note\n          , # collection note\n          }',
  '{before: one, # before note\n          ? keep # key note\n          , # after note\n          after: two, # collection note\n          }',
  '{before: one, # before note\n          ? keep: yes # key note\n          }',
  '[? keep: yes, # collection note\n          ]',
 ]){
  const text=(header+'components:\n  schemas:\n    Model:\n      default:\n        - '+body+'\n      description: sentinel\n').replaceAll('\n',newline),pointer='/components/schemas/Model/default';
  const original=new SourceDocument(text,root),value=JSON.parse(original.dataJson(pointer));
  if(body.startsWith('['))value[0]=[];else delete value[0].keep;
  assert.equal(analyse(input(text)).findings.length,0);
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:JSON.stringify(value)}]})),doc=new SourceDocument(changed,root);
  assert.deepEqual(doc.node(pointer).value,value);assert.equal(analyse(input(changed)).findings.length,0);
  for(const range of original.comments('/components/schemas/Model'))assert(changed.includes(text.slice(...range)));
 }
});
test('R03-H valueless member updates use their real insertion point',()=>{
 for(const body of ['{keep}','{? keep}','{? keep,}','[? keep]','? keep','{?}','{? }','{? ,}','{""}','{:}','{: ,}'])for(const raw of ['true','{"n":9007199254740993.00}']){
  const text=header+'components:\n  schemas:\n    Model:\n      default:\n        '+body+'\n      description: sentinel\n',pointer='/components/schemas/Model/default';
  const key=body.includes('keep')?'keep':'',member={[key]:JSON.parse(raw)},expected=body.startsWith('[')?[member]:member;
  assert.equal(analyse(input(text)).findings.length,0);
  const requested='{'+JSON.stringify(key)+':'+raw+'}',data=body.startsWith('[')?'['+requested+']':requested;
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:data}]})),doc=new SourceDocument(changed,root);
  assert.deepEqual(doc.node(pointer).value,expected);assert.equal(analyse(input(changed)).findings.length,0);if(raw.startsWith('{'))assert(doc.dataJson(pointer).includes('9007199254740993.00'));
  const original=new SourceDocument(text,root),leaf=pointer+(body.startsWith('[')?'/0/':'/')+key;
  const set=original.set(leaf,raw==='true'?true:new RawJsonValue(raw)),setDoc=new SourceDocument(set,root);
  assert.deepEqual(setDoc.node(pointer).value,expected);assert.equal(analyse(input(set)).findings.length,0);if(raw.startsWith('{'))assert(setDoc.dataJson(pointer).includes('9007199254740993.00'));
  const empty=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:body.startsWith('[')?'[{}]':'{}'}]}));
  assert.deepEqual(new SourceDocument(empty,root).node(pointer).value,body.startsWith('[')?[{}]:{});assert.equal(analyse(input(empty)).findings.length,0);
 }
 // Removing a property from an implicit pair retains its map/sequence item;
 // adding one must supply braces instead of treating the key as a closer.
 for(const body of ['[? keep]','[? keep: yes]','[keep: yes]'])for(const raw of ['[{}]','[{"keep":true,"value":{"n":9007199254740993.00}}]','[[true]]']){
  const text=header+'components:\n  schemas:\n    Model:\n      default: '+body+'\n      description: sentinel\n',pointer='/components/schemas/Model/default';
  assert.equal(analyse(input(text)).findings.length,0);
  const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw}]})),doc=new SourceDocument(changed,root);
  assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert.equal(analyse(input(changed)).findings.length,0);if(raw.includes('9007199254740993.00'))assert(doc.dataJson(pointer).includes('9007199254740993.00'));
 }
});
test('R03-H invalid edit and removal bounds fail before source mutation',()=>{
 const text=header+'components: {schemas: {Model: {default: {keep: yes}}}}\n',doc=new SourceDocument(text,root);
 for(const [start,end]of [[10,5],[-1,2],[0,text.length+1],[0.5,2]])assert.throws(()=>doc.replace(start,end,''),e=>e.code==='edit.range');
 assert.throws(()=>doc.remove(''),e=>e.code==='edit.target');assert.equal(doc.text,text);
 const member=doc.node('/components/schemas/Model/default/keep');
 member.entryEnd=0;
 assert.throws(()=>doc.remove(member.pointer),e=>e.code==='edit.range');assert.equal(doc.text,text);
});
test('R03-I whole-default implicit empty-key edits retain comment separators and exact values',()=>{
 const failures=[];
 for(const version of ['3.1.2','3.2.1'])for(const newline of ['\n','\r\n'])for(const marker of ['?',':'])for(const raw of ['[7]','[{}]','[{"":null,"next":1}]']){
  const prefix=header.replace('3.2.1',version)+'components:\n  schemas:\n    Model:\n      default: [',tail='# key note\n        ]\n      description: sentinel # untouched\n';
  const text=(prefix+marker+' '+tail).replaceAll('\n',newline),pointer='/components/schemas/Model/default',original=new SourceDocument(text,root);
  assert.deepEqual(original.node(pointer).value,[{'':null}]);assert.equal(analyse(input(text)).findings.length,0);
  try{
   const changed=apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw}]})),doc=new SourceDocument(changed,root);
   assert.deepEqual(doc.node(pointer).value,JSON.parse(raw));assert.equal(analyse(input(changed)).findings.length,0);
   assert(changed.startsWith(prefix.replaceAll('\n',newline)));assert(changed.endsWith(tail.replaceAll('\n',newline)));assert(/\s# key note/.test(changed));
  }catch(e){failures.push({version,newline,marker,raw,error:e.code??e.message});}
 }
 assert.deepEqual(failures,[]);
});
test('R03-I physical member bounds retain trivia across implicit-pair edits and controls',()=>{
 const fixtures=[
  ['?',' '],[':','\t'],['? :','  '],['? keep',' '],['keep:',' '],['? keep:',' '],
  ['? : null',' '],[': null',' '],['keep: null',' '],['keep: "value # data  "',' '],
  ['?',' \n          '],[':',' \n          '],
 ];
 for(const newline of ['\n','\r\n'])for(const [member,trivia]of fixtures){
  const key=member.includes('keep')?'keep':'',comment='# key note\n        ',pointer='/components/schemas/Model/default';
  const text=(header+'components:\n  schemas:\n    Model:\n      default: ['+member+trivia+comment+']\n      description: sentinel\n').replaceAll('\n',newline),original=new SourceDocument(text,root);
  assert.equal(analyse(input(text)).findings.length,0);
  const value=JSON.parse(original.dataJson(pointer));
  const rawExpanded='[{'+JSON.stringify(key)+':'+JSON.stringify(value[0][key])+',"next":{"n":\n9007199254740993.00\n}}]',expanded=JSON.parse(rawExpanded);
  const changes=[
   [original.set(pointer+'/0',7),[7]],
   [original.remove(pointer+'/0/'+key),[{}]],
   [original.remove(pointer+'/0'),[]],
   [apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:'[]'}]})),[]],
   [original.set(pointer+'/0/next',new RawJsonValue('{"n":\n9007199254740993.00\n}')),expanded],
   [apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:rawExpanded}]})),expanded],
   [apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:'[{'+JSON.stringify(key)+':7,"next":1}]'}]})),[{[key]:7,next:1}]],
   [apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:'[[7]]'}]})),[[7]]],
   [apply(text,propose({...input(text),target:{resource:root,generation:1,pointer:'/components/schemas/Model'},actions:[{kind:'setData',pointer,raw:'["literal # data  "]'}]})),['literal # data  ']],
  ];
  for(const [changed,expected]of changes){
   const doc=new SourceDocument(changed,root);assert.deepEqual(doc.node(pointer).value,expected);assert.equal(analyse(input(changed)).findings.length,0);
   assert(changed.includes((trivia+comment).replaceAll('\n',newline)),JSON.stringify({member,newline,expected,changed}));assert(changed.endsWith(('      description: sentinel\n').replaceAll('\n',newline)));
   if(expected===expanded)assert(doc.dataJson(pointer).includes('9007199254740993.00'));
  }
 }
});
