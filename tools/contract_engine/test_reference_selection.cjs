const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {planReference}=require('./dist/reference_selection.cjs');
const {referenceChoices}=require('./dist/reference_choices.cjs');
const {createGraph}=require('./dist/model.cjs');
const apply=(input,plan)=>input.resources.map(r=>{let text=r.text;for(const edit of plan.edits.filter(e=>e.buffer===r.id).sort((a,b)=>b.start-a.start)){assert.equal(text.slice(edit.start,edit.end),edit.expected);text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);}return {...r,text};});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`new reusable reference positions retain typed ownership ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///project/new.'+(json?'json':'yaml');
 const definitions={parameters:{name:'id',in:'query',schema:{type:'string'}},responses:{description:'Target',content:{'application/json':{schema:true}}},headers:{schema:{type:'string'}},requestBodies:{content:{'application/json':{schema:true}}},examples:{value:{$ref:'literal payload'}},links:{operationId:'known'},callbacks:{'{$request.query.callbackUrl}':{post:{responses:{204:{description:'Empty'}}}}},securitySchemes:{type:'http',scheme:'bearer'},pathItems:{get:{responses:{204:{description:'Empty'}}}},...(version.startsWith('3.2')?{mediaTypes:{schema:false}}:{})};
 const value={openapi:version,info:{title:'New references',version:'1'},paths:{'/a':{get:{operationId:'known',responses:{204:{description:'Empty'}}}}},components:Object.fromEntries(Object.entries(definitions).map(([family,target])=>[family,{Use:family==='responses'?{description:'Local override'}:{},Target:target}])), 'x-data':{$ref:'literal'}};
 const text=json?JSON.stringify(value):'# kept 😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n').trimEnd();
 const input={root,snapshot:'new-reference',resources:[{id:root,text,generation:1}],contexts:[{root,resources:[root]}]};
 const {docs}=createGraph(input),doc=docs.get(root);
 const capture=pointer=>({root,resource:root,pointer,generation:1,range:doc.node(pointer).range,expected:text.slice(...doc.node(pointer).range)});
 for(const family of Object.keys(definitions)){
  const pointer='/components/'+family+'/Use',target='/components/'+family+'/Target';
  const choices=referenceChoices({...input,resource:root,pointer,query:'Target',keyword:'$ref'});
  assert(choices.entries.some(choice=>choice.target.pointer===target),family+' must offer its legal typed definition');
  const plan=planReference({...input,target:capture(pointer),choice:capture(target),keyword:'$ref'}),changed=apply(input,plan),actual=(json?JSON.parse:YAML.parse)(changed[0].text);
  assert.equal(actual.components[family].Use.$ref,'#/components/'+family+'/Target');
  if(family==='responses')assert.equal(actual.components[family].Use.description,'Local override');
  assert.deepEqual(actual.components[family].Target,definitions[family]);
  assert.equal(actual['x-data'].$ref,'literal');
  const reference=createGraph({...input,resources:changed}).graph.references.find(ref=>ref.pointer===pointer&&ref.keyword==='$ref');
  assert.equal(reference.resolution,'resolved');assert.equal(reference.targetPointer,target);
 }
 assert.throws(()=>referenceChoices({...input,resource:root,pointer:'/info',query:'',keyword:'$ref'}),error=>error.code==='reference.choice.context');
 const payload={...value,info:{...value.info,$ref:'not a reference'}};
 assert.throws(()=>referenceChoices({...input,resources:[{id:root,text:JSON.stringify(payload),generation:1}],resource:root,pointer:'/info',query:'',keyword:'$ref'}),error=>error.code==='reference.choice.context');
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`reviewed typed reference selection ${version} ${json?'JSON':'YAML'}`,()=>{
 const root='file:///project/root.'+(json?'json':'yaml'),part='file:///project/part.json';
 const value={openapi:version,info:{title:'Select',version:'1'},paths:{'/a':{get:{operationId:'repeated',responses:{204:{description:'Empty'}}}},'/b':{get:{operationId:'repeated',responses:{204:{description:'Empty'}}}}},components:{
  schemas:{Use:{$ref:'#/components/schemas/Old',description:'Local annotation'},Old:{type:'string'},New:false,External:{$ref:'part.json#/Model'},Dependent:{$ref:'#/components/schemas/Use'},Dynamic:{$dynamicAnchor:'node',type:'object'},DynamicUse:{$dynamicRef:'#node'}},
  parameters:{Inline:{name:'id',in:'query',schema:{type:'string'}}},links:{Next:{operationRef:'#/paths/~1a/get'},ById:{operationId:'repeated'}},
 },'x-kept':{$ref:'literal'}};
 const text=json?JSON.stringify(value,null,2):'# comment 😀\r\n'+YAML.stringify(value).replaceAll('\n','\r\n').trimEnd();
 const input={snapshot:'captured',resources:[{id:root,text,generation:3},{id:part,text:'{"Model":{"type":"number","x-exact":9007199254740993.00}}',generation:5}],contexts:[{root,resources:[root,part]}]};
 const {graph,docs}=createGraph({...input,root});
 const capture=(resource,pointer)=>({root,resource,pointer,generation:input.resources.find(r=>r.id===resource).generation,range:docs.get(resource).node(pointer).range,expected:docs.get(resource).text.slice(...docs.get(resource).node(pointer).range)});
 const target=capture(root,'/components/schemas/Use'),choice=capture(root,'/components/schemas/New');
 const plan=planReference({...input,target,choice,keyword:'$ref'}),changed=apply(input,plan),actual=(json?JSON.parse:YAML.parse)(changed[0].text);
 assert.equal(plan.kind,'reference-selection');assert.equal(plan.edits.length,1);assert(plan.usages.some(u=>u.pointer==='/components/schemas/Dependent/$ref'));
 assert.equal(actual.components.schemas.Use.$ref,'#/components/schemas/New');assert.equal(actual.components.schemas.Use.description,'Local annotation');
 assert.equal(actual['x-kept'].$ref,'literal');assert.equal(changed[1].text,input.resources[1].text);
 if(!json){assert(changed[0].text.startsWith('# comment 😀\r\n'));assert(!/(?<!\r)\n/.test(changed[0].text));assert(!changed[0].text.endsWith('\n'));}
 const noOp=planReference({...input,target,choice:capture(root,'/components/schemas/Old'),keyword:'$ref'});assert.deepEqual(noOp.edits,[]);
 const external=planReference({...input,target,choice:capture(part,'/Model'),keyword:'$ref'});assert.equal(external.value,'part.json#/Model');assert.equal(createGraph({...input,root,resources:apply(input,external)}).graph.references.find(r=>r.pointer===target.pointer).targetResource,part);
 assert.throws(()=>planReference({...input,target,choice:capture(root,'/components/parameters/Inline'),keyword:'$ref'}),e=>e.code==='reference.choice.context');
 assert.throws(()=>planReference({...input,target,choice:{...choice,expected:'changed'},keyword:'$ref'}),e=>e.code==='edit.stale');
 assert.throws(()=>planReference({...input,target:capture(root,'/components/parameters/Inline'),choice:capture(root,'/components/parameters/Inline'),keyword:'$ref'}),e=>e.code==='reference.choice.context');
 const link=planReference({...input,target:capture(root,'/components/links/Next'),choice:capture(root,'/paths/~1b/get'),keyword:'operationRef'});
 assert.equal(link.value,'#/paths/~1b/get');assert.equal((json?JSON.parse:YAML.parse)(apply(input,link)[0].text).components.links.Next.operationRef,link.value);
 assert.throws(()=>planReference({...input,target:capture(root,'/components/links/ById'),choice:capture(root,'/paths/~1b/get'),keyword:'operationRef'}),e=>e.code==='reference.choice.context');
 assert.equal(planReference({...input,target:capture(root,'/components/schemas/DynamicUse'),choice:capture(root,'/components/schemas/Dynamic'),keyword:'$dynamicRef'}).edits.length,0);
 assert.equal(input.resources[0].text,text);
});
test('a shared occurrence must select the same target from both approved root contexts',()=>{
 const a='file:///project/a.json',b='file:///project/b.json',part='file:///project/shared.json';
 const root=title=>JSON.stringify({openapi:'3.2.1',info:{title,version:'1'},paths:{},components:{schemas:{Use:{$ref:'shared.json#/Use'},New:{$id:'https://models.invalid/ambiguous',type:'string'}}}});
 const resources=[{id:a,text:root('A'),generation:1},{id:b,text:root('B'),generation:2},{id:part,text:'{"Use":{"$ref":"a.json#/components/schemas/New"}}',generation:3}];
 const input={root:a,snapshot:'both',resources,contexts:[{root:a,resources:[a,part]},{root:b,resources:[b,part,a]}]}, {docs}=createGraph(input);
 const capture=(resource,pointer)=>({root:a,resource,pointer,generation:resources.find(r=>r.id===resource).generation,range:docs.get(resource).node(pointer).range,expected:docs.get(resource).text.slice(...docs.get(resource).node(pointer).range)});
 // The current spelling is retained even though a canonical id would collide.
 const noop=planReference({...input,target:capture(part,'/Use'),choice:capture(a,'/components/schemas/New'),keyword:'$ref'});assert.deepEqual(noop.edits,[]);
});
test('reference selection preserves YAML aliases and rejects undefined Path Item siblings',()=>{
 const root='file:///project/root.yaml';
 const text=`# original\nopenapi: 3.2.1\ninfo: {title: Alias, version: "1"}\npaths:\n  /a: {summary: Local}\ncomponents:\n  schemas:\n    Use: {$ref: '#/components/schemas/Old'}\n    Old: true\n    Definition: &shared {type: number, x-kept: 9007199254740993.00}\n    Alias: *shared\n  pathItems:\n    Overlap: {summary: Target, get: {responses: {'204': {description: Empty}}}}\n`;
 const input={root,snapshot:'aliases',resources:[{id:root,generation:1,text}],contexts:[{root,resources:[root]}]}, {docs}=createGraph(input);
 const capture=pointer=>({root,resource:root,pointer,generation:1,range:docs.get(root).node(pointer).range,expected:text.slice(...docs.get(root).node(pointer).range)});
 const result=planReference({...input,target:capture('/components/schemas/Use'),choice:capture('/components/schemas/Alias'),keyword:'$ref'});
 assert.equal(apply(input,result)[0].text,text.replace('#/components/schemas/Old','#/components/schemas/Alias'));
 assert.throws(()=>planReference({...input,target:capture('/paths/~1a'),choice:capture('/components/pathItems/Overlap'),keyword:'$ref'}),e=>e.code==='reference.choice.pathItem');
 assert.throws(()=>planReference({...input,target:capture('/components/schemas/Definition'),choice:capture('/components/schemas/Old'),keyword:'$ref'}),e=>e.code==='reference.choice.context');
});
test('canonical document and nested dynamic choices cannot rely on a warm dependency cache',()=>{
 const root='file:///project/root.json',external='file:///project/models.json',identity='https://contracts.invalid/models';
 const input={root,snapshot:'cold',resources:[
  {id:root,generation:1,text:JSON.stringify({openapi:'3.2.1',info:{title:'Cold',version:'1'},paths:{},components:{schemas:{Use:{$ref:'models.json#/components/schemas/Old'}}}})},
  {id:external,generation:1,text:JSON.stringify({openapi:'3.2.1',$self:identity,info:{title:'Model',version:'1'},paths:{},components:{schemas:{Old:{type:'string'},New:false,Nested:{$id:'urn:busyapi:dynamic',$dynamicAnchor:'node',type:'integer'}}}})},
 ],contexts:[{root,resources:[root,external]}]};
 const capture=(input,resource,pointer)=>{const {docs}=createGraph(input),doc=docs.get(resource);return {root,resource,pointer,generation:1,range:doc.node(pointer).range,expected:doc.text.slice(...doc.node(pointer).range)};};
 const target=capture(input,root,'/components/schemas/Use'),choice=capture(input,external,'/components/schemas/New');
 assert.throws(()=>planReference({...input,target,choice,keyword:'$ref'}),e=>e.code==='reference.choice.retrieval');
 const approved={...input,resources:[input.resources[0],{...input.resources[1],aliases:[identity]}]};
 const plan=planReference({...approved,target,choice,keyword:'$ref'});
 assert.equal(plan.value,identity+'#/components/schemas/New');
 assert.equal(apply(approved,plan)[1].text,input.resources[1].text);
 const dynamicSource={...input,resources:[{...input.resources[0],text:input.resources[0].text.replace('"$ref":"models.json#/components/schemas/Old"','"$dynamicRef":"models.json#/components/schemas/Old"')},input.resources[1]]};
 assert.throws(()=>planReference({...dynamicSource,target:capture(dynamicSource,root,target.pointer),choice:capture(dynamicSource,external,'/components/schemas/Nested'),keyword:'$dynamicRef'}),e=>e.code==='reference.choice.retrieval');
 // An independent file reference deliberately retaining that resource makes
 // its nested declared identity discoverable without a separate mapping.
 const retained={...dynamicSource,resources:[{...dynamicSource.resources[0],text:dynamicSource.resources[0].text.replace('"schemas":{','"schemas":{"Retained":{"$ref":"models.json#/components/schemas/Old"},')},dynamicSource.resources[1]]};
 const dynamic=planReference({...retained,target:capture(retained,root,target.pointer),choice:capture(retained,external,'/components/schemas/Nested'),keyword:'$dynamicRef'});
 assert.equal(dynamic.value,'urn:busyapi:dynamic#node');
 const after=createGraph({...retained,resources:apply(retained,dynamic)}).graph;
 assert.equal(after.references.find(ref=>ref.pointer===target.pointer).dynamic.anchor,'node');
});
