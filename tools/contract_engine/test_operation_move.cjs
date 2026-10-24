const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {planOperationMove}=require('./dist/refactoring_copy.cjs');
const {createGraph,analyse,inspect}=require('./dist/model.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
function fixture(version,json){
 const suffix=json?'json':'yaml',root='file:///project/root.'+suffix,part='file:///project/links.'+suffix;
 const pointer='/paths/~1old~1{id}/get',schema=pointer+'/responses/200/content/application~1json/schema';
 const operation={operationId:'moveMe',summary:'Move me',description:'First line\n雪😀 second line\n',parameters:[{name:'q',in:'query',schema:{type:'string'}}],responses:{200:{description:'Success',content:{'application/json':{schema:{$id:'https://schemas.invalid/tree',$dynamicAnchor:'node',type:'object',properties:{value:{type:'integer'},child:{$dynamicRef:'#node'}},required:['value'],unevaluatedProperties:false},examples:{Good:{value:{value:1,child:{value:2}}},Bad:{value:{value:'wrong'}}},example:undefined}}},204:{description:'Bodyless'}},'x-data':{$ref:'#'+pointer,n:111}};
 const parameter={name:'id',in:'path',required:true,schema:{type:'integer',minimum:111}};
 const document={openapi:version,info:{title:'Operation moves',version:'1'},paths:{'/old/{id}':{parameters:[parameter],servers:[{url:'./source'}],get:operation,post:{operationId:'staysHere',responses:{204:{description:'Sibling'}}}},'/new/{id}':{parameters:[structuredClone(parameter)],servers:[{url:'./destination'}],get:{operationId:'staysThere',responses:{204:{description:'Destination sibling'}}}}},components:{schemas:{Use:{$ref:'#'+schema}},links:{Use:{$ref:'links.'+suffix+'#/Use'}}},'x-preserved':{n:111,$ref:'literal payload'}};
 const render=value=>json?JSON.stringify(value,null,2):YAML.stringify(value,{lineWidth:0}).replaceAll('\n','\r\n');
 const text=(json?'':'# preserved root comment\r\n')+render(document).trimEnd().replaceAll('111','9007199254740993.00');
 const external={Use:{operationRef:'root.'+suffix+'#'+pointer}};
 return {snapshot:'operation-move',root,resources:[{id:root,text,generation:4},{id:part,text:render(external),generation:7}],contexts:[{root,resources:[root,part]}],target:{root,resource:root,pointer,generation:4},method:version.startsWith('3.2')?'COPY':'patch',additional:version.startsWith('3.2'),path:'/new/{id}',context:'preserve'};
}
function apply(input,plan){return input.resources.map(resource=>{let text=resource.text;for(const edit of plan.edits.filter(edit=>edit.buffer===resource.id).sort((a,b)=>b.start-a.start)){assert.equal(edit.generation,resource.generation);assert.equal(text.slice(edit.start,edit.end),edit.expected);text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);}return {...resource,text};});}
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`reviewed operation relocation preserves exact source, inheritance, usages and real schema outcomes ${version} ${json?'JSON':'YAML'}`,async()=>{
 const input=fixture(version,json),frozen=input.resources.map(resource=>resource.text),before=await evaluateSchemas({...input,root:input.root});
 const plan=planOperationMove(input),resources=apply(input,plan),doc=new SourceDocument(resources[0].text,input.root),destination=plan.to.pointer;
 assert.equal(plan.kind,'operation-move');assert.equal(plan.edits.length,2);assert.equal(plan.checkedRoots[0],input.root);
 assert.equal(doc.nodes.has(input.target.pointer),false);
 assert.equal(doc.node('/paths/~1old~1{id}/post/operationId').value,'staysHere');
 assert.equal(doc.node('/paths/~1new~1{id}/get/operationId').value,'staysThere');
 assert.equal(doc.node(destination+'/operationId').value,'moveMe');
 assert.equal(doc.node(destination+'/parameters/0/name').value,'q');
 assert.equal(doc.node(destination+'/parameters/1/name').value,'id');
 assert(doc.dataJson(destination+'/parameters/1/schema/minimum').includes('9007199254740993.00'));
 assert.equal(doc.node(destination+'/servers/0/url').value,'./source');
 assert.equal(doc.node('/paths/~1new~1{id}/servers/0/url').value,'./destination');
 assert.equal(doc.nodes.has(destination+'/responses/204/content'),false);
 assert.equal(doc.node(destination+'/x-data/$ref').value,'#'+input.target.pointer,'Payload references are data, even when they match a moved pointer');
 assert.equal(doc.node('/x-preserved/$ref').value,'literal payload');
 assert(doc.dataJson('/x-preserved/n').includes('9007199254740993.00'));
 assert.equal(/[\r\n]$/.test(resources[0].text),false);
 if(!json){assert(resources[0].text.startsWith('# preserved root comment\r\n'));assert(!/(?<!\r)\n/.test(resources[0].text));}
 const graph=createGraph({...input,resources}).graph;
 assert.equal(graph.issues.length,0,JSON.stringify(graph.issues));
 assert.equal(graph.references.find(ref=>ref.connection==='operationRef').targetPointer,destination);
 assert.equal(graph.references.find(ref=>ref.pointer==='/components/schemas/Use').targetPointer,destination+'/responses/200/content/application~1json/schema');
 assert(plan.usages.some(usage=>usage.connection==='operationRef'));
 assert.equal(graph.references.find(ref=>ref.keyword==='$dynamicRef').value,'#node','Unchanged anchor spelling must not be normalized');
 const after=await evaluateSchemas({...input,resources});
 assert.equal(before.complete,true,JSON.stringify(before.findings));assert.equal(after.complete,true,JSON.stringify(after.findings));
 assert.deepEqual(before.evaluations.map(value=>value.valid),[true,false]);assert.deepEqual(after.evaluations.map(value=>value.valid),[true,false]);
 assert.deepEqual(input.resources.map(resource=>resource.text),frozen);
 assert.equal(analyse({...input,resources}).status,'complete');
});
test('additional method case, fixed-field exclusion, destination inheritance and no-op stay deliberate',()=>{
 const input=fixture('3.2.1',true);
 const plan=planOperationMove({...input,destinationPointer:'/paths/~1old~1{id}',path:undefined,method:'get',additional:true});
 const doc=new SourceDocument(apply(input,plan)[0].text,input.root);
 assert.equal(doc.node('/paths/~1old~1{id}/additionalOperations/get/operationId').value,'moveMe');
 assert.equal(doc.nodes.has('/paths/~1old~1{id}/get'),false);
 const noop=planOperationMove({...input,path:'/old/{id}',method:'get',additional:false});
 assert.deepEqual(noop.edits,[]);assert.deepEqual(noop.changes,[]);
 for(const method of ['GET','POST','QUERY','BAD METHOD','雪',''])assert.throws(()=>planOperationMove({...input,method}),error=>error.code==='edit.method');
 const destination=planOperationMove({...input,context:'destination'}),moved=new SourceDocument(apply(input,destination)[0].text,input.root);
 assert.equal(moved.nodes.has(destination.to.pointer+'/servers'),false);
 assert.equal(moved.node(destination.to.pointer+'/parameters').children.size,1);
 const older=fixture('3.1.2',true);
 assert.throws(()=>planOperationMove({...older,method:'COPY',additional:true}),error=>error.code==='edit.method');
});
test('collisions, template mismatches, unknown context and aliased ownership cannot produce a partial plan',()=>{
 const input=fixture('3.2.1',true),frozen=input.resources.map(resource=>resource.text);
 for(const change of [{method:'get',additional:false},{path:'/new/{other}'},{context:'unknown'}])
  assert.throws(()=>planOperationMove({...input,...change}),error=>['edit.collision','edit.path.template','edit.path.context'].includes(error.code));
 const withExtra=JSON.parse(input.resources[0].text);withExtra.paths['/new/{id}'].parameters.push({name:'extra',in:'query',schema:{type:'string'}});
 assert.throws(()=>planOperationMove({...input,resources:[{...input.resources[0],text:JSON.stringify(withExtra)},input.resources[1]]}),error=>error.code==='edit.path.context');
 const shared=fixture('3.2.1',false),value=YAML.parse(shared.resources[0].text);
 value.paths['/new/{id}'].parameters=value.paths['/old/{id}'].parameters;
 assert.throws(()=>planOperationMove({...shared,resources:[{...shared.resources[0],text:YAML.stringify(value)},shared.resources[1]]}),error=>['edit.shared','refactor.copy.shared'].includes(error.code));
 assert.deepEqual(input.resources.map(resource=>resource.text),frozen);
});
test('equivalent Server inheritance stays absent and an explicit preservation can materialize only a needed default',()=>{
 const input=fixture('3.2.1',true),document=JSON.parse(input.resources[0].text);
 delete document.paths['/old/{id}'].servers;
 document.servers=[{url:'./same',description:'Root declaration'}];
 document.paths['/new/{id}'].servers=structuredClone(document.servers);
 let params={...input,resources:[{...input.resources[0],text:JSON.stringify(document)},input.resources[1]]};
 let plan=planOperationMove(params),moved=new SourceDocument(apply(params,plan)[0].text,input.root);
 assert.equal(moved.nodes.has(plan.to.pointer+'/servers'),false,'An equivalent effective Server must not be injected');
 delete document.servers;document.paths['/new/{id}'].servers=[{url:'./other'}];
 params={...params,resources:[{...input.resources[0],text:JSON.stringify(document)},input.resources[1]]};
 plan=planOperationMove(params);moved=new SourceDocument(apply(params,plan)[0].text,input.root);
 assert.equal(moved.node(plan.to.pointer+'/servers/0/url').value,'file:///');
 assert.equal(moved.nodes.has('/servers'),false,'The original absent root declaration remains absent');
 assert(plan.overrides.includes('servers'));
});
test('shared Path Item impacts are reviewed and incompatible entry Server contexts cannot be silently collapsed',()=>{
 const input=fixture('3.2.1',true),document=JSON.parse(input.resources[0].text),other='file:///project/entry.json';
 delete document.paths['/old/{id}'].servers;document.servers=[{url:'https://one.invalid/base'}];
 const entry={openapi:'3.2.1',info:{title:'Other entry',version:'1'},servers:[{url:'https://two.invalid/base'}],paths:{'/shared/{id}':{$ref:'root.json#/paths/~1old~1{id}'}}};
 const resources=[{...input.resources[0],text:JSON.stringify(document)},input.resources[1],{id:other,text:JSON.stringify(entry),generation:3}];
 const params={...input,resources,contexts:[{root:input.root,resources:resources.map(value=>value.id)},{root:other,resources:resources.map(value=>value.id)}]};
 assert.throws(()=>planOperationMove(params),error=>error.code==='edit.path.servers');
 const plan=planOperationMove({...params,context:'destination'});
 assert(plan.usages.some(usage=>usage.resource===other&&usage.effect==='containing-definition-changes'&&usage.roots.includes(other)));
 const after=apply(params,plan);
 assert.equal(createGraph({root:other,resources:after}).graph.issues.length,0);
 assert.equal(JSON.parse(after[2].text).paths['/shared/{id}'].$ref,entry.paths['/shared/{id}'].$ref);
});
for(const role of ['webhook','callback'])test(`additional method relocation keeps a ${role}'s actual Path Item identity`,()=>{
 const root='file:///project/owned.json';
 const pathItem={additionalOperations:{COPY:{operationId:'copy',responses:{204:{description:'None'}}}}};
 const value={openapi:'3.2.1',info:{title:'Owned',version:'1'},paths:{}};
 let parent;
 if(role==='webhook'){value.webhooks={event:pathItem};parent='/webhooks/event';}
 else{value.paths['/subscribe']={post:{callbacks:{event:{'{$request.body#/callback}':pathItem}}}};parent='/paths/~1subscribe/post/callbacks/event/{$request.body#~1callback}';}
 const text=JSON.stringify(value),input={root,snapshot:role,resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,pointer:parent+'/additionalOperations/COPY',generation:1},destinationPointer:parent,method:'query',additional:false,context:'preserve'};
 const plan=planOperationMove(input),after=new SourceDocument(apply(input,plan)[0].text,root);
 assert.equal(after.node(parent+'/query/operationId').value,'copy');assert.equal(after.nodes.has(input.target.pointer),false);
 assert.equal(createGraph({root,resources:apply(input,plan)}).graph.issues.length,0);
});
test('native relocation metadata follows the actual typed owner, not a matching component key',()=>{
 const root='file:///project/metadata.json';
 const operation=()=>({responses:{204:{description:'Bodyless'}}});
 const value={openapi:'3.2.1',info:{title:'Metadata',version:'1'},paths:{'/standard':{get:operation(),additionalOperations:{get:operation()}}},
  components:{pathItems:{additionalOperations:{get:operation(),additionalOperations:{COPY:operation()}}}}};
 const input={root,snapshot:'metadata',resources:[{id:root,text:JSON.stringify(value),generation:1}]};
 for(const [pointer,owner,method,additional,canRelocatePath]of [
  ['/paths/~1standard/get','/paths/~1standard','get',false,true],
  ['/paths/~1standard/additionalOperations/get','/paths/~1standard','get',true,true],
  ['/components/pathItems/additionalOperations/get','/components/pathItems/additionalOperations','get',false,false],
  ['/components/pathItems/additionalOperations/additionalOperations/COPY','/components/pathItems/additionalOperations','COPY',true,false],
 ]){
  const descriptor=inspect({...input,resource:root,pointer});
  assert.equal(descriptor.family,'3.2');assert(descriptor.operationMethods.includes('query'));
  assert.deepEqual(descriptor.operationContext,{pathItemPointer:owner,method,additional,canRelocatePath,path:owner.split('/').at(-1).replaceAll('~1','/')});
 }
});
test('relocation retains YAML entry comments, literal comment-looking data and unrelated sibling bytes',()=>{
 const root='file:///project/comments.yaml';
 const text="openapi: 3.2.1\r\ninfo: {title: Comments, version: '1'}\r\npaths:\r\n  /old:\r\n    # selected leading remains authored\r\n    get: # selected key\r\n      # selected body 雪😀\r\n      summary: |-\r\n        # literal data, not a comment\r\n        multi 雪😀\r\n      responses: {204: {description: None}} # selected end\r\n    # sibling leading\r\n    post: {responses: {204: {description: Sibling}}}\r\n  /new: {}";
 const input={root,snapshot:'comments',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}],target:{root,resource:root,pointer:'/paths/~1old/get',generation:1},method:'COPY',additional:true,path:'/new',context:'preserve'};
 const plan=planOperationMove(input),after=apply(input,plan)[0].text;
 for(const comment of ['# selected leading remains authored','# selected key','# selected body 雪😀','# selected end','# sibling leading','# literal data, not a comment'])
  assert.equal(after.split(comment).length,2,comment+' must be retained exactly once');
 assert(after.includes('    # sibling leading\r\n    post: {responses: {204: {description: Sibling}}}'));
 assert.equal(new SourceDocument(after,root).node(plan.to.pointer+'/summary').value,'# literal data, not a comment\nmulti 雪😀');
 assert(!/(?<!\r)\n/.test(after));assert(!/[\r\n]$/.test(after));
});
