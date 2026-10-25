const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('./node_modules/yaml');
const {planFileMove,planFileDeletion}=require('./dist/refactoring_file.cjs');
const {createGraph}=require('./dist/model.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`file move cannot rewrite a dual literal/schema value ${version} ${json}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,model='file:///project/model.'+ext,document={openapi:version,info:{title:'Dual move',version:'1'},paths:{},components:{schemas:{Literal:{const:{$ref:'model.'+ext}},Use:{$ref:'#/components/schemas/Literal/const'}}}},encode=value=>json?JSON.stringify(value):YAML.stringify(value),resources=[{id:root,text:encode(document),generation:1},{id:model,text:encode({type:'string'}),generation:2}],input={snapshot:'dual-file',resources,contexts:[{root,resources:[root,model]}],target:{resource:model,generation:2},destinationResource:'file:///project/deep/moved.'+ext},frozen=resources.map(value=>value.text);
 const range=createGraph({root,resources}).docs.get(root).dataNode('/components/schemas/Literal/const/$ref').range;
 assert.throws(()=>planFileMove(input),error=>error.code==='file.move.literal.ownership'&&JSON.stringify(error.range)===JSON.stringify(range));
 const manifest={id:'file:///project/busyapi.yaml',text:'version: 1\nroots: [{name: Main, path: root.'+ext+'}]\n',generation:1},retained=planFileMove({...input,manifest,retainIdentity:true});
 const after=apply(input,retained);assert.equal(after[0].text,resources[0].text);assert.equal(after[1].text,resources[1].text);assert.equal(after[1].id,input.destinationResource);assert.equal(retained.file.retainedIdentity,model);assert.deepEqual(resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`file deletion distinguishes semantic consumers from literal source-looking data ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///project/root.'+(json?'json':'yaml'),model='file:///project/model.'+(json?'json':'yaml');
 const data={openapi:version,info:{title:'Delete',version:'1'},paths:{},components:{examples:{Payload:{value:{$ref:model+'#/Value',security:{Model:[]}}}}},'x-data':{$ref:model}};
 const encode=value=>json?JSON.stringify(value):YAML.stringify(value),source={id:model,text:encode({Value:{type:'integer',example:111}}).replace('111','9007199254740993'),generation:3,identity:'captured-model'};
 const resources=[{id:root,text:encode(data),generation:1}],input={snapshot:'delete',resources,contexts:[{root,resources:[root]}],target:{resource:model,generation:3},deletionSource:source},frozen=resources.map(value=>value.text);
 const unused=planFileDeletion(input);assert.equal(unused.kind,'file-delete');assert.deepEqual(unused.blockers,[]);assert.deepEqual(unused.usages,[]);assert.deepEqual(unused.edits,[]);
 assert.equal(unused.changes[0].before,source.text);assert.equal(unused.changes[0].after,'');assert.equal(unused.transitions[0].mode,'removal');
 data.components.schemas={Use:{$ref:model+'#/Value'}};
 const linked={...input,resources:[{...resources[0],text:encode(data)},source],contexts:[{root,resources:[root,model]}]},blocked=planFileDeletion(linked);
 assert.equal(blocked.usages.length,1);assert.equal(blocked.usages[0].pointer,'/components/schemas/Use/$ref');assert.equal(blocked.usages[0].target.resource,model);assert(blocked.blockers.some(value=>value.code==='file.delete.consumer'));
 assert.deepEqual(resources.map(value=>value.text),frozen);assert(source.text.includes('9007199254740993'));
 const self=planFileDeletion({...input,target:{resource:root,generation:1},deletionSource:resources[0]});assert(self.blockers.some(value=>value.code==='file.delete.root'));assert.deepEqual(self.edits,[]);
 assert.throws(()=>planFileDeletion({...input,target:{resource:model,generation:4}}),error=>error.code==='file.delete.snapshot');
});
test('file deletion retains exact physical usages with every affected root and blocks incomplete analysis',()=>{
 const root='file:///project/root.json',other='file:///project/other.json',model='file:///project/model.json';
 const api={openapi:'3.2.1',info:{title:'Usages',version:'1'},paths:{},components:{schemas:{Use:{$ref:'model.json#/Value'}}}},source={id:model,text:'{"Value":false}',generation:1};
 const shared={id:'file:///project/shared.json',text:JSON.stringify(api),generation:1};
 const resources=[{id:root,text:JSON.stringify({...api,components:{schemas:{Use:{$ref:'shared.json#/components/schemas/Use'}}}}),generation:1},{id:other,text:JSON.stringify({...api,components:{schemas:{Use:{$ref:'shared.json#/components/schemas/Use'}}}}),generation:1},shared,source];
 const input={snapshot:'delete-shared',resources,contexts:[{root,resources:[root,shared.id,model]},{root:other,resources:[other,shared.id,model]}],target:{resource:model,generation:1},deletionSource:source};
 const plan=planFileDeletion(input);assert.equal(plan.usages.length,1);assert.equal(plan.usages[0].resource,shared.id);assert.deepEqual(plan.usages[0].roots,[other,root]);
 const incomplete=planFileDeletion({...input,resources:resources.map(value=>value.id===shared.id?{...value,text:value.text.replace('model.json','unavailable.json')}:value)});
 assert(incomplete.blockers.some(value=>value.code==='file.delete.analysis'));assert.deepEqual(incomplete.edits,[]);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`file deletion reviews external serialized examples without acquiring or interpreting payloads ${version} ${json?'JSON':'YAML'}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,model='file:///project/payload.'+ext;
 const data={openapi:version,...(version.startsWith('3.2')?{$self:'https://identity.example/entry'}:{}),info:{title:'External example',version:'1'},paths:{},components:{examples:{Serialized:{externalValue:version.startsWith('3.2')?model+'#arbitrary/data':'payload.'+ext+'#arbitrary/data'},Literal:{value:{externalValue:model,$ref:model}},Ignored:{$ref:'#/components/examples/Literal',externalValue:model}}},'x-data':{externalValue:model}};
 const encode=value=>json?JSON.stringify(value):YAML.stringify(value),source={id:model,text:'not a contract: [ deliberately invalid serialized data',generation:1};
 const resources=[{id:root,text:encode(data),generation:1}],input={snapshot:'external-example',resources,contexts:[{root,resources:[root]}],target:{resource:model,generation:1},deletionSource:source};
 const plan=planFileDeletion(input);
 assert.equal(plan.usages.length,1);assert.equal(plan.usages[0].pointer,'/components/examples/Serialized/externalValue');assert.equal(plan.usages[0].connection,'externalValue');
 assert.deepEqual(plan.usages[0].target,{resource:model,pointer:''});assert.deepEqual(plan.usages[0].roots,[root]);assert.equal(plan.blockers.length,1);assert.equal(plan.blockers[0].code,'file.delete.consumer');
 assert.deepEqual(createGraph({root,resources}).graph.references.map(ref=>ref.keyword),['$ref']);assert.equal(resources.length,1);assert.deepEqual(plan.edits,[]);
 data.components.examples.Serialized.externalValue=version.startsWith('3.2')?'payload.'+ext:model.replace('payload.','other.');
 assert.deepEqual(planFileDeletion({...input,resources:[{...resources[0],text:encode(data)}]}).blockers,[],'$self must not be confused with a filesystem retrieval locator');
});
test('external example usages retain shared-root attribution and unavailable URI analysis is not clean',()=>{
 const root='file:///project/root.json',other='file:///project/other.json',shared='file:///project/examples.json',payload='file:///project/payload.json';
 const api={openapi:'3.2.1',info:{title:'Shared',version:'1'},paths:{},components:{examples:{Shared:{$ref:'examples.json'}}}};
 const source={id:payload,text:'900719925474099312345678901',generation:1};
 const resources=[{id:root,text:JSON.stringify(api),generation:1},{id:other,text:JSON.stringify(api),generation:1},{id:shared,text:'{"externalValue":"payload.json#not-a-pointer"}',generation:1}];
 const input={snapshot:'shared-data',resources,contexts:[{root,resources:[root,shared]},{root:other,resources:[other,shared]}],target:{resource:payload,generation:1},deletionSource:source};
 const plan=planFileDeletion(input);assert.equal(plan.usages.length,1);assert.deepEqual(plan.usages[0].roots,[other,root]);assert.equal(plan.usages[0].resource,shared);
 const invalid=planFileDeletion({...input,resources:resources.map(value=>value.id===shared?{...value,text:'{"externalValue":"bad %escape"}'}:value)});
 assert(invalid.blockers.some(value=>value.code==='file.delete.analysis'&&value.resource===shared&&value.pointer==='/externalValue'));
});
function apply(input,plan){return input.resources.map(r=>{let text=r.text;for(const e of plan.edits.filter(e=>e.buffer===r.id).sort((a,b)=>b.start-a.start)){assert.equal(text.slice(e.start,e.end),e.expected);text=text.slice(0,e.start)+e.replacement+text.slice(e.end);}return {...r,text,id:r.id===plan.file.source?plan.file.destination:r.id,...(r.id===plan.file.source&&plan.file.retainedIdentity?{aliases:[plan.file.retainedIdentity]}:{})};});}
for(const version of ['3.2.0','3.2.1'])for(const configured of [false,true])test(`security relocation does not configure unrelated URI bindings ${version} configured=${configured}`,()=>{
 const root='file:///project/api.json',scheme='file:///project/security.json',other='file:///project/other/api.json',otherScheme='file:///project/other/deep/new.json',destination='file:///project/deep/new.json';
 const api=value=>JSON.stringify({openapi:version,info:{title:'Separate roots',version:'1'},paths:{},security:[{[value]:['reader']}]});
 const resources=[{id:root,generation:1,text:api('security.json#/Key')},{id:scheme,generation:2,text:JSON.stringify({Key:{type:'apiKey',in:'header',name:'X-First'}})},
  {id:other,generation:3,text:api('deep/new.json#/Key')},{id:otherScheme,generation:4,text:JSON.stringify({Key:{type:'apiKey',in:'header',name:'X-Other'}})}];
 const manifest={id:'file:///project/busyapi.yaml',generation:1,identity:'config',text:'version: 1\nroots: [{name: api, path: api.json}, {name: other, path: other/api.json}]\nenvironments:\n  manual:\n    authentication:\n      schemes:\n        "security.json#/Key": {secretRef: captured-reference}\n'+(configured?'        "deep/new.json#/Key": {secretRef: captured-reference}\n':'')};
 const input={snapshot:'separate-uri-security',resources,contexts:[{root,resources:[root,scheme]},{root:other,resources:[other,otherScheme]}],target:{resource:scheme,generation:2},destinationResource:destination,manifest};
 if(configured)assert(!planFileMove(input).changes.some(change=>change.resource===manifest.id));
 else assert.throws(()=>planFileMove(input),error=>error.code==='refactor.configuration.ambiguous'&&error.source?.resource===manifest.id);
});
function capture(version,json,rootMove=false){
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,models='file:///project/models.'+ext;
 const data={openapi:version,info:{title:'Move',version:'1'},paths:{},components:{schemas:{Model:{$ref:'models.'+ext+'#/a~1b'},Again:{$ref:'models.'+ext+'#/a~01b'}}}};
 const values={'a/b':{type:'object',properties:{next:{$ref:'#/a~1b'},external:{$ref:'root.'+ext+'#/components/schemas/Leaf'}},example:{$ref:'literal data',keep:9007199254740993n.toString()}},'a~1b':false};
 data.components.schemas.Leaf={type:'string'};
 const encode=d=>json?JSON.stringify(d,null,2):YAML.stringify(d),resources=[{id:root,generation:1,text:encode(data)},{id:models,generation:2,text:encode(values)}];
 return {snapshot:'captured',resources,contexts:[{root,resources:[root,models]}],target:{resource:rootMove?root:models,generation:rootMove?1:2},destinationResource:'file:///project/moved/new%20'+ext+'.'+ext};
}
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const moved of ['root','fragment','scheme'])for(const shared of [false,true])for(const configured of [false,true])test(`file move preserves URI security keys ${version} ${format} moved=${moved} shared=${shared} configured=${configured}`,()=>{
 const root='file:///project/api.'+format,other='file:///project/other.'+format,fragment='file:///project/part.'+format,scheme='file:///project/security.'+format;
 const locator='security.'+format+'#/Key~1~0';
 const api={openapi:version,info:{title:'Security file move 雪',version:'1'},paths:{'/items':{$ref:'part.'+format+'#/Path'}},
  components:{securitySchemes:{Local:{type:'apiKey',in:'header',name:'X-Local'},Alias:{$ref:locator}}},security:[{Local:[],[locator]:['reader']}],
  'x-payload':{[locator]:['reader']},'x-number':'__exact__'};
 const part={Path:{get:{security:[{Local:[],[locator]:['reader']}],responses:{204:{description:'Empty'}}}},'x-payload':{[locator]:['reader']}};
 const encode=value=>(format==='json'?JSON.stringify(value,null,2):'# retained ownership\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll(format==='json'?'"__exact__"':'__exact__','9007199254740993.00');
 const resources=[{id:root,generation:1,text:encode(api)},{id:fragment,generation:2,text:encode(part)},{id:scheme,generation:3,text:encode({'Key/~':{type:'apiKey',in:'header',name:'X-Remote'}})},
  ...(shared?[{id:other,generation:4,text:encode(api)}]:[])];
 const source={root,fragment,scheme}[moved],destination='file:///project/deep/moved.'+format;
 const contexts=[{root,resources:[root,fragment,scheme]},...(shared?[{root:other,resources:[other,fragment,scheme]}]:[])];
 const manifest=configured?{id:'file:///project/busyapi.yaml',generation:8,identity:'configuration',text:`version: 1\n# persistent environment\nroots: [{name: api, path: api.${format}}${shared?`, {name: other, path: other.${format}}`:''}]\nenvironments:\n  manual:\n    authentication:\n      schemes:\n        Local: {secretRef: local-reference}\n        ${JSON.stringify(locator)}: {secretRef: remote-reference} # retained\nx-number: 9007199254740993.00\n`}:undefined;
 const input={snapshot:'security-file-move',resources,contexts,target:{resource:source,generation:resources.find(resource=>resource.id===source).generation},destinationResource:destination,...(manifest?{manifest}:{})};
 const original=resources.map(resource=>resource.text),before=contexts.map(context=>createGraph({root:context.root,resources:resources.filter(resource=>context.resources.includes(resource.id))}));
 for(const context of before)assert.equal(context.graph.issues.length,0,JSON.stringify(context.graph.issues));
 const plan=planFileMove(input),afterResources=apply(input,plan),move=id=>id===source?destination:id;
 for(let index=0;index<contexts.length;index++){
  const context=contexts[index],after=createGraph({root:move(context.root),resources:afterResources.filter(resource=>context.resources.map(move).includes(resource.id))});
  assert.equal(after.graph.issues.length,0,JSON.stringify(after.graph.issues));
  for(const old of before[index].graph.references){
   const matching=after.graph.references.filter(ref=>ref.resource===move(old.resource)&&ref.pointer===old.pointer&&ref.connection===old.connection&&ref.targetResource===move(old.targetResource)&&ref.targetPointer===old.targetPointer);
   assert(matching.length>0,JSON.stringify(old));
   if(old.connection==='security')for(const ref of matching)assert.equal(after.docs.get(ref.resource).dataJson(ref.pointer+'/'+ref.keyword.replaceAll('~','~0').replaceAll('/','~1')),before[index].docs.get(old.resource).dataJson(old.pointer+'/'+old.keyword.replaceAll('~','~0').replaceAll('/','~1')));
  }
  for(const id of [context.root,fragment])assert.equal(after.docs.get(move(id)).dataJson('/x-payload'),before[index].docs.get(id).dataJson('/x-payload'));
  assert.equal(after.docs.get(move(context.root)).dataJson('/x-number'),'9007199254740993.00');
  if(manifest){
   const configuration=new SourceDocument(plan.changes.find(change=>change.resource===manifest.id)?.after??manifest.text,manifest.id);
   for(const ref of after.graph.references.filter(ref=>ref.connection==='security'))assert.equal(configuration.dataNode('/environments/manual/authentication/schemes/'+ref.value.replaceAll('~','~0').replaceAll('/','~1')+'/secretRef').value,ref.value==='Local'?'local-reference':'remote-reference');
   assert.equal(configuration.dataJson('/x-number'),'9007199254740993.00');assert(configuration.text.includes(`${JSON.stringify(locator)}: {secretRef: remote-reference} # retained`));
  }
 }
 assert.deepEqual(resources.map(resource=>resource.text),original);
 if(format==='yaml')for(const resource of afterResources){assert(resource.text.startsWith('# retained ownership\r\n'));assert(!/(?<!\r)\n/.test(resource.text));}
 assert(plan.usages.some(use=>use.resource===fragment&&use.connection==='security'));
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const duplicate of [false,true])test(`file move proves security URI name precedence and distinct role bindings ${version} ${format} duplicate=${duplicate}`,()=>{
 const root='file:///project/api.'+format,scheme='file:///project/security.'+format,destination='file:///project/moved.'+format;
 const uri='./security.'+format,requirements={[uri]:['reader'],...(duplicate?{['security.'+format+'#']:['writer']}:{})};
 const value={openapi:version,info:{title:'URI precedence',version:'1'},paths:{},components:{securitySchemes:{['moved.'+format]:{type:'apiKey',in:'header',name:'X-Shadow'}}},security:[requirements]};
 const encode=value=>format==='json'?JSON.stringify(value):YAML.stringify(value);
 const resources=[{id:root,generation:1,text:encode(value)},{id:scheme,generation:2,text:encode({type:'apiKey',in:'header',name:'X-Remote'})}];
 const input={snapshot:'uri-precedence',resources,contexts:[{root,resources:[root,scheme]}],target:{resource:scheme,generation:2},destinationResource:destination};
 const original=resources.map(resource=>resource.text),plan=planFileMove(input),after=createGraph({root,resources:apply(input,plan)});
 assert.equal(after.graph.issues.length,0,JSON.stringify(after.graph.issues));
 const bindings=after.graph.references.filter(ref=>ref.connection==='security');
 assert.equal(bindings.length,duplicate?2:1);
 for(const ref of bindings){assert.equal(ref.targetResource,destination);assert.equal(ref.targetPointer,'');assert.notEqual(ref.value,'moved.'+format);}
 assert.deepEqual([...after.docs.get(root).dataNode('/security/0').children.values()].map(node=>node.value),Object.values(requirements));
 assert.equal(after.docs.get(root).dataNode('/components/securitySchemes/moved.'+format+'/name').value,'X-Shadow');
 assert.deepEqual(resources.map(resource=>resource.text),original);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`file move retains discriminator name bindings ${version} ${format}`,()=>{
 const root='file:///project/api.'+format,destination='file:///project/deep/moved.'+format;
 const value={openapi:version,info:{title:'Named discriminator',version:'1'},paths:{},components:{schemas:{
  Base:{type:'object',required:['kind'],properties:{kind:{type:'string'}},discriminator:{propertyName:'kind',mapping:{cat:'Cat'}}},Cat:{allOf:[{$ref:'#/components/schemas/Base'},{type:'object',properties:{name:{type:'string'}}}]}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),resources=[{id:root,text,generation:1}];
 const input={snapshot:'named-discriminator',resources,contexts:[{root,resources:[root]}],target:{resource:root,generation:1},destinationResource:destination};
 const after=createGraph({root:destination,resources:apply(input,planFileMove(input))});
 assert.equal(after.graph.issues.length,0,JSON.stringify(after.graph.issues));
 assert.equal(after.docs.get(destination).dataNode('/components/schemas/Base/discriminator/mapping/cat').value,'Cat');
 assert.equal(after.graph.references.find(ref=>ref.connection==='discriminator').targetResource,destination);
 assert.equal(resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`file move repairs typed external example locators and preserves opaque fragment spelling ${version} ${json?'JSON':'YAML'}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,model='file:///project/model.'+ext,destination='file:///project/deep/new.'+ext;
 const data={openapi:version,info:{title:'Data consumers',version:'1'},paths:{},components:{schemas:{Value:{$ref:'model.'+ext}},examples:{Serialized:{externalValue:'model.'+ext+'#opaque%7E%2Fdata'},Literal:{value:{externalValue:'model.'+ext}},Ignored:{$ref:'#/components/examples/Literal',externalValue:'model.'+ext}}}};
 const encode=value=>json?JSON.stringify(value,null,2):YAML.stringify(value),source=encode({type:'integer',example:111}).replace('111','900719925474099312345678901');
 const resources=[{id:root,text:encode(data),generation:1},{id:model,text:source,generation:2}],input={snapshot:'opaque-fragment',resources,contexts:[{root,resources:[root,model]}],target:{resource:model,generation:2},destinationResource:destination};
 const plan=planFileMove(input),after=apply(input,plan),doc=new SourceDocument(after[0].text,root);
 assert.equal(after[1].text,source);assert.equal(doc.node('/components/examples/Serialized/externalValue').value,'deep/new.'+ext+'#opaque%7E%2Fdata');
 assert.equal(doc.node('/components/examples/Literal/value/externalValue').value,'model.'+ext);assert.equal(doc.node('/components/examples/Ignored/externalValue').value,'model.'+ext);
 assert(plan.usages.some(usage=>usage.connection==='externalValue'&&usage.pointer==='/components/examples/Serialized/externalValue'&&usage.target.resource===model));
 const changed={...input,resources:resources.map(value=>value.id===model?{...value,text:encode({$ref:'root.'+ext+'#/components/schemas/Leaf'})}:value.id===root?{...value,text:encode({...data,components:{...data.components,schemas:{...data.components.schemas,Leaf:false}}})}:value)};
 assert.throws(()=>planFileMove(changed),error=>error.code==='file.move.example-content');
 const manifest={id:'file:///project/busyapi.yaml',text:'version: 1\nroots: [{name: Main, path: root.'+ext+'}]\n',generation:1};
 const retained=planFileMove({...changed,manifest,retainIdentity:true}),retainedAfter=apply(changed,retained);
 assert.equal(retainedAfter[1].text,changed.resources[1].text);assert.equal(retainedAfter[0].text,changed.resources[0].text);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const rootMove of [false,true])test(`file move preserves physical pointers/recursion/literal data ${version} ${json?'JSON':'YAML'} ${rootMove?'root':'fragment'}`,()=>{
 const input=capture(version,json,rootMove),original=input.resources.map(r=>r.text),plan=planFileMove(input),resources=apply(input,plan),root=rootMove?input.destinationResource:input.contexts[0].root;
 assert.deepEqual(input.resources.map(r=>r.text),original);
 const graph=createGraph({root,resources}).graph;assert.deepEqual(graph.issues,[]);
 const first=graph.references.find(r=>r.resource===root&&r.pointer==='/components/schemas/Model');
 assert.equal(first.targetPointer,'/a~1b');assert.equal(first.targetResource,rootMove?input.resources[1].id:input.destinationResource);
 const falseRef=graph.references.find(r=>r.pointer==='/components/schemas/Again');assert.equal(new SourceDocument(resources.find(r=>r.id===falseRef.targetResource).text,falseRef.targetResource).node(falseRef.targetPointer).value,false);
 assert.equal(new SourceDocument(resources[1].text,resources[1].id).node('/a~1b/example/$ref').value,'literal data');
 assert(plan.usages.some(u=>u.target.pointer==='/a~1b'));assert(plan.edits.length>0);assert.equal(plan.transitions.length,1);
});
for(const json of [false,true])test(`file move preserves relative nested identities and actual dynamic evaluation ${json?'JSON':'YAML'}`,async()=>{
 const root='file:///project/root.'+(json?'json':'yaml'),models='file:///project/models.'+(json?'json':'yaml');
 const data={openapi:'3.2.1',info:{title:'Dynamic',version:'1'},paths:{},components:{schemas:{Strict:{$id:'strict', $dynamicAnchor:'node',type:'object',properties:{value:{type:'string'},children:{type:'array',items:{$dynamicRef:'#node'}}},unevaluatedProperties:false,examples:[{value:'yes',children:[{value:'yes'}]},{value:'yes',children:[{unexpected:true}]}]},External:{$ref:'models.'+(json?'json':'yaml')+'#nested'}}}};
 const external={$id:'external', $defs:{Nested:{$id:'child', $anchor:'nested',type:'string'}},$ref:'child#nested'};
 data.components.schemas.External.$ref='models.'+(json?'json':'yaml')+'#/$defs/Nested';
 const encode=d=>json?JSON.stringify(d,null,2):YAML.stringify(d),resources=[{id:root,generation:1,text:encode(data)},{id:models,generation:1,text:encode(external)}];
 // An explicit approved retrieval mapping retains the original acquisition
 // capability when a reference uses a declared identifier, not the local path.
 resources[1].aliases=['file:///project/external'];
 const input={snapshot:'dynamic',resources,contexts:[{root,resources:[root,models]}],target:{resource:root,generation:1},destinationResource:'file:///project/deep/renamed.'+(json?'json':'yaml')};
 const before=await evaluateSchemas({root,resources}),plan=planFileMove(input),afterResources=apply(input,plan),after=await evaluateSchemas({root:input.destinationResource,resources:afterResources});
 assert.deepEqual(before.evaluations.filter(e=>e.schema.pointer.includes('/Strict')).map(e=>e.valid),[true,false]);
 assert.deepEqual(after.evaluations.filter(e=>e.schema.pointer.includes('/Strict')).map(e=>e.valid),[true,false]);
 const graph=createGraph({root:input.destinationResource,resources:afterResources}).graph;
 assert.equal(graph.scopes.get(input.destinationResource+'#/components/schemas/Strict').base,'file:///project/strict');
});
test('a relative $self retains its identity, source values, URL targets and manifest unknowns',()=>{
 const root='file:///project/root.yaml',other='file:///project/other.yaml';
 const text='openapi: 3.2.1\n$self: ./public\ninfo: {title: Exact, version: "1"}\nservers:\n  - url: ../service\npaths: {}\ncomponents:\n  schemas:\n    Value:\n      type: integer\n      example: 900719925474099312345678901 # exact\n    Other:\n      $ref: other.yaml#/components/schemas/Value\n';
 const resources=[{id:root,generation:3,text},{id:other,generation:1,text:'openapi: 3.2.1\ninfo: {title: Other, version: "1"}\npaths: {}\ncomponents: {schemas: {Value: false}}\n'}];
 const manifest={id:'file:///project/busyapi.yaml',generation:4,text:'version: 1\n# preserve root spelling outside this field\nroots:\n  - name: Main\n    path: "root.yaml" # owner\nunknown: {$ref: literal, number: 900719925474099312345678901}\n'};
 const input={snapshot:'self',resources,contexts:[{root,resources:[root,other]}],target:{resource:root,generation:3},destinationResource:'file:///project/deep/new.yaml',manifest};
 const plan=planFileMove(input),after=apply(input,plan),doc=new SourceDocument(after[0].text,after[0].id);
 assert.equal(new URL(doc.node('/$self').value,after[0].id).href,'file:///project/public');
 assert.equal(new URL(doc.node('/servers/0/url').value,after[0].id).href,'file:///service');
 assert(after[0].text.includes('example: 900719925474099312345678901 # exact'));
 const e=plan.edits.find(e=>e.buffer===manifest.id),updated=manifest.text.slice(0,e.start)+e.replacement+manifest.text.slice(e.end);
 assert(updated.includes('path: "deep/new.yaml" # owner'));assert(updated.includes('unknown: {$ref: literal, number: 900719925474099312345678901}'));
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const mapped of [false,true])test(`file move retains description URI bases separately from Server URLs ${version} ${json?'JSON':'YAML'} mapped=${mapped}`,()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,destination='file:///project/deep/new.'+ext;
 const retrieval=mapped?'https://device.example/contracts/root.'+ext:root;
 const self='https://identities.example/documentation/entry.'+ext;
 const data={openapi:version,...(version.startsWith('3.2')?{$self:self}:{}),info:{title:'URI ownership',version:'1',termsOfService:'./terms',contact:{url:'../contact'},license:{name:'License',url:'license.txt'}},externalDocs:{url:'guide.html'},servers:[{url:'../service'}],paths:{},components:{examples:{External:{externalValue:'./payload.txt#part'},Literal:{value:{externalValue:'payload data',url:'literal'}},Ignored:{$ref:'#/components/examples/Literal',externalValue:'ignored-relative-data'}}},'x-data':{externalValue:'payload data',url:'literal'}};
 const encode=value=>json?JSON.stringify(value,null,2):YAML.stringify(value);
 const source=encode(data),resources=[{id:root,text:source,generation:3,...(mapped?{aliases:[retrieval]}:{})}];
 const input={snapshot:'description-uris',resources,contexts:[{root,resources:[root]}],target:{resource:root,generation:3},destinationResource:destination};
 const plan=planFileMove(input),after=apply(input,plan),doc=new SourceDocument(after[0].text,destination);
 const base=version.startsWith('3.2')?self:retrieval,afterBase=version.startsWith('3.2')?self:mapped?retrieval:destination;
 for(const pointer of ['/info/termsOfService','/info/contact/url','/info/license/url','/externalDocs/url','/components/examples/External/externalValue']){
  const before=new SourceDocument(source,root).node(pointer).value,now=doc.node(pointer).value;
  assert.equal(new URL(now,afterBase).href,new URL(before,base).href,pointer);
  if(version.startsWith('3.2')||mapped)assert.equal(now,before,pointer+' must not be needlessly rewritten');
 }
 assert.equal(new URL(doc.node('/servers/0/url').value,mapped?retrieval:destination).href,new URL(data.servers[0].url,retrieval).href);
 assert.equal(doc.node('/components/examples/Ignored/externalValue').value,'ignored-relative-data');
 assert.equal(doc.node('/components/examples/Literal/value/externalValue').value,'payload data');
 assert.equal(doc.node('/x-data/externalValue').value,'payload data');
 assert.equal(resources[0].text,source);
});
test('no-op, stale, captured destination collisions and unresolved graphs fail without editing source',()=>{
 const input=capture('3.1.2',true),noop=planFileMove({...input,destinationResource:input.target.resource});assert.deepEqual(noop.edits,[]);assert.deepEqual(noop.transitions,[]);
 assert.throws(()=>planFileMove({...input,target:{...input.target,generation:99}}),e=>e.code==='edit.stale');
 assert.throws(()=>planFileMove({...input,destinationResource:input.resources[0].id}),e=>e.code==='edit.collision');
 assert.throws(()=>planFileMove({...input,resources:input.resources.slice(0,1)}),e=>e.code==='edit.stale');
 assert.throws(()=>planFileMove({...input,resources:input.resources.map(r=>r.id===input.target.resource?{...r,text:r.text.replace('root.json','missing.json')}:r)}),e=>e.code==='refactor.graph');
});
test('several entry contexts preserve incoming references to a space/non-ASCII filename',()=>{
 const root='file:///project/root.json',other='file:///project/other.json';
 const resources=[{id:root,generation:1,text:'{"openapi":"3.2.1","info":{"title":"Root","version":"1"},"paths":{},"components":{"schemas":{"Number":{"type":"integer"},"Other":{"$ref":"other.json#/components/schemas/Value"}}}}'},
 {id:other,generation:1,text:'{"openapi":"3.2.1","info":{"title":"Other","version":"1"},"paths":{},"components":{"schemas":{"Value":false,"Incoming":{"$ref":"root.json#/components/schemas/Number"}}}}'}];
 const input={snapshot:'several',resources,contexts:[{root,resources:[root,other]},{root:other,resources:[root,other]}],target:{resource:root,generation:1},destinationResource:new URL('file:///project/new folder/新しい.json').href};
 assert.doesNotThrow(()=>planFileMove(input));
});
test('relative server variables and authored escaping retain their URL-template meaning',()=>{
 const root='file:///project/root.json',resources=[{id:root,generation:1,text:JSON.stringify({openapi:'3.2.1',info:{title:'Templates',version:'1'},paths:{},servers:[{url:'../{region}/service/%7Bid%7D',variables:{region:{default:'eu'}}}]})}];
 const input={snapshot:'templates',resources,contexts:[{root,resources:[root]}],target:{resource:root,generation:1},destinationResource:'file:///project/sub/new.json'};
 const plan=planFileMove(input),after=apply(input,plan),value=JSON.parse(after[0].text).servers[0].url;
 assert.equal(value,'../../{region}/service/%7Bid%7D');
 assert.deepEqual(JSON.parse(after[0].text).servers[0].variables,{region:{default:'eu'}});
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`retained URI file moves preserve source, descriptions and real dynamic evaluation ${version} ${json?'JSON':'YAML'}`,async()=>{
 const ext=json?'json':'yaml',root='file:///project/root.'+ext,other='file:///project/other.'+ext,destination='file:///project/deep/moved.'+ext;
 const api={openapi:version,...(version.startsWith('3.2')?{$self:'./root.'+ext}:{}),info:{title:'Retained',version:'1',description:'[Relative guide](../guide/file.md) and literal `$ref`.'},paths:{},components:{schemas:{Node:{$id:'node', $dynamicAnchor:'node',type:'object',properties:{name:{type:'string'},children:{type:'array',items:{$dynamicRef:'#node'}}},unevaluatedProperties:false,examples:[{name:'ok',children:[{name:'ok'}]},{name:'ok',children:[{unexpected:1}]}]}}}};
 const encode=value=>json?JSON.stringify(value,null,2):YAML.stringify(value),source=encode(api).replace('"ok"','"ok"');
 const resources=[{id:root,text:source,generation:1},{id:other,text:encode({openapi:version,info:{title:'Other',version:'1'},paths:{},components:{schemas:{Use:{$ref:'root.'+ext+'#/components/schemas/Node'}}}}),generation:2}];
 const manifest={id:'file:///project/busyapi.yaml',text:'version: 1\nroots: [{name: Main, path: root.'+ext+'}, {name: Other, path: other.'+ext+'}]\nunknown: {number: 900719925474099312345}\n',generation:1};
 const input={snapshot:'retained',resources,contexts:[{root,resources:[root]},{root:other,resources:[root,other]}],target:{resource:root,generation:1},destinationResource:destination,retainIdentity:true,manifest};
 const before=await evaluateSchemas({root,resources:resources.slice(0,1)}),plan=planFileMove(input),after=apply(input,plan),evaluated=await evaluateSchemas({root:destination,resources:after});
 assert.equal(after[0].text,source);assert.equal(after[1].text,resources[1].text);
 assert.equal(plan.file.retainedIdentity,root);assert.deepEqual(evaluated.evaluations.map(e=>e.valid),before.evaluations.map(e=>e.valid));assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,false]);
 const edit=plan.edits.find(e=>e.buffer===manifest.id),text=manifest.text.slice(0,edit.start)+edit.replacement+manifest.text.slice(edit.end),configuration=new SourceDocument(text,manifest.id).root.value;
 assert.equal(configuration.resourceMappings['root.'+ext],'deep/moved.'+ext);assert.equal(configuration.roots[0].path,'deep/moved.'+ext);
 assert(text.includes('unknown: {number: 900719925474099312345}'));
 assert.equal(createGraph({root:other,resources:after}).graph.issues.length,0);
});
for(const [url,variables,values]of [
 ['../{tenant}/../resource',{tenant:{default:'a/b'}},[{tenant:'a/b'},{tenant:'x/../../y'},{tenant:'{literal}'}]],
 ['v/{tenant}/../resource',{tenant:{default:'a/b'}},[{tenant:'a/b'},{tenant:'../x'},{tenant:''}]],
 ['{prefix}/v',{prefix:{default:'a',enum:['a','b/c']}},[{prefix:'a'},{prefix:'b/c'}]],
 ['{protocol}://example.test:{port}/v',{protocol:{default:'https',enum:['https','http']},port:{default:'443'}},[{protocol:'https',port:'443'},{protocol:'http',port:'8080'}]],
 ['?{query}',{query:{default:'q=1'}},[{query:'q=1'},{query:'q=two#part'}]],
 ['//example.test/{path}',{path:{default:'v'}},[{path:'v/a'},{path:'v/../b'}]],
])test('file moves use shared Server template semantics '+url,()=>{
 const root='file:///project/root.json',destination='file:///project/new/deep/spec.json';
 const resources=[{id:root,generation:1,text:JSON.stringify({openapi:'3.2.1',info:{title:'Server',version:'1'},paths:{},servers:[{url,variables}]})}];
 const input={snapshot:'template-meaning',resources,contexts:[{root,resources:[root]}],target:{resource:root,generation:1},destinationResource:destination};
 const result=JSON.parse(apply(input,planFileMove(input))[0].text).servers[0];
 for(const data of values){const expand=template=>template.replace(/\{([^{}]+)\}/g,(_all,name)=>data[name]);assert.equal(new URL(expand(result.url),destination).href,new URL(expand(url),root).href);}
 assert.deepEqual(result.variables,variables);
});
