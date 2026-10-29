const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {inspect,propose}=require('./dist/engine.cjs');
const {assistSource}=require('./dist/source_assistance.cjs');
const {analyse}=require('./dist/model.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const jsonTypes=['object','array','string','number','integer','boolean','null'];
const render=(value,json)=>json?JSON.stringify(value,null,2)+'\r\n':'# Keep 雪😀 and CRLF\r\n'+YAML.stringify(value).replace(/\n/g,'\r\n');
function fixture(version,json){
 const root='file:///approved/api.'+(json?'json':'yaml'),swagger=version==='2.0';
 const schema={type:'string',description:'Keep 雪😀',example:'keep', 'x-opaque':{$ref:'literal.json'}};
 const document={...(swagger?{swagger:version}:{openapi:version}),info:{title:'Keep',version:'unrelated'},paths:{'/value':{get:{responses:{200:{description:'Keep',...(swagger?{schema}:{content:{'application/json':{schema}}})}}}}}};
 const pointer='/paths/~1value/get/responses/200/'+(swagger?'schema':'content/application~1json/schema');
 return {document,pointer,input:{root,resource:root,pointer,snapshot:'type-choices',resources:[{id:root,text:render(document,json),generation:7,identity:root}]}};
}
const choices=input=>inspect(input).fields.find(field=>field.name==='type').schemaTypeChoices;
function proposal(input,value,capabilities=choices(input),remove=false){
 const target=inspect(input);
 return propose({...input,target,actions:[{kind:remove?'remove':'set',pointer:input.pointer+'/type',...(remove?{}:{value}),schemaTypeChoices:capabilities}]});
}
function apply(input,result){
 const resource=input.resources.find(entry=>entry.id===input.resource);let text=resource.text;
 for(const edit of [...result.edits].reverse()){
  assert.equal(edit.buffer,resource.id);assert.equal(edit.generation,7);
  assert.equal(text.slice(edit.start,edit.end),edit.expected);
  text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
 }
 return {...input,resources:input.resources.map(entry=>entry.id===resource.id?{...entry,text,generation:8}:entry)};
}
for(const version of versions)for(const json of [false,true])test(`${version} ${json?'JSON':'YAML'} native type metadata, Source and exact targeted edits`,()=>{
 const {input,pointer}=fixture(version,json),original=input.resources[0].text,metadata=choices(input);
 assert.equal(metadata.revision,'1');assert.equal(metadata.supported,true);
 assert.equal(metadata.context.rootVersion,version);assert.equal(metadata.context.pointer,pointer);
 assert.equal(assistSource({...input,caret:0,action:'help'}).help.standard,
  'https://spec.openapis.org/oas/v'+(version==='2.0'?'2.0':version.startsWith('3.0.')?'3.0.4':version.startsWith('3.1.')?'3.1.2':'3.2.1')+'.html#'+(version==='2.0'?'swagger':'openapi')+'-object');
 const standard=version.startsWith('3.0.')?jsonTypes.filter(type=>type!=='null'):jsonTypes;
 assert.deepEqual(metadata.scalarTypes,[...standard,...(version==='2.0'?['file']:[])]);
 assert.deepEqual(metadata.unionTypes,version.startsWith('3.0.')?[]:jsonTypes);
 assert.throws(()=>proposal(input,['file']),error=>error.code==='edit.schema-type.value');
 assert.throws(()=>proposal(input,false),error=>error.code==='edit.schema-type.value');
 const tampered=structuredClone(metadata);tampered.revision='unsupported';
 assert.throws(()=>proposal(input,'string',tampered),error=>error.code==='edit.schema-type.stale');
 const node=new SourceDocument(original,input.root).dataNode(pointer+'/type');
 const source=assistSource({...input,caret:node.range[0]+1});
 assert.deepEqual(source.completions.map(choice=>choice.label),metadata.scalarTypes);
 const value=version==='2.0'?'file':version.startsWith('3.0.')?'integer':['string','null'];
 const changed=apply(input,proposal(input,value));
 const parsed=new SourceDocument(changed.resources[0].text,input.root);
 assert.deepEqual(parsed.dataNode(pointer+'/type').value,value);
 assert.equal(parsed.dataNode(pointer+'/description').value,'Keep 雪😀');
 assert.equal(parsed.dataNode(pointer+'/x-opaque/$ref').value,'literal.json');
 assert.equal(changed.resources[0].text,original.slice(0,node.range[0])+parsed.text.slice(...parsed.dataNode(pointer+'/type').range)+original.slice(node.range[1]));
 assert.deepEqual(proposal(input,'string').edits,[]);
 const removed=apply(input,proposal(input,undefined,metadata,true));
 assert.equal(new SourceDocument(removed.resources[0].text,input.root).dataNode(pointer).children.has('type'),false);
 assert.equal(input.resources[0].text,original);
});
for(const kind of ['direct','reusable-response','fragment','chained-fragment','shared-body','chained-shared-body','nested','definition','body-only'])for(const json of [false,true])test(`Swagger ${kind} ${json?'JSON':'YAML'} native file scalar follows the shared Source owner`,()=>{
 const {input,document}=fixture('2.0',json),suffix=json?'json':'yaml',part='file:///approved/types.'+suffix,last='file:///approved/last.'+suffix;
 const operation=document.paths['/value'].get,fragments=[];
 if(kind==='reusable-response'){
  document.responses={Reusable:operation.responses[200]};operation.responses[200]={$ref:'#/responses/Reusable'};input.pointer='/responses/Reusable/schema';
 }else if(['fragment','chained-fragment','shared-body','chained-shared-body','body-only'].includes(kind)){
  operation.responses[200].schema={$ref:'./types.'+suffix+'#/File'};
  fragments.push([part,{File:kind.startsWith('chained-')?{$ref:'./last.'+suffix+'#/Final'}:{type:'string'}}]);
  input.resource=part;input.pointer='/File';
  if(kind.startsWith('chained-')){fragments.push([last,{Final:{type:'string'}}]);input.resource=last;input.pointer='/Final';}
  if(['shared-body','chained-shared-body','body-only'].includes(kind))operation.parameters=[{name:'body',in:'body',schema:{$ref:'./types.'+suffix+'#/File'}}];
  if(kind==='body-only')delete operation.responses[200].schema;
 }else if(kind==='nested'){
  operation.responses[200].schema={type:'object',properties:{value:{type:'string'}}};input.pointer+='/properties/value';
 }else if(kind==='definition'){
  document.definitions={Value:{type:'string'}};operation.responses[200].schema={$ref:'#/definitions/Value'};input.pointer='/definitions/Value';
 }
 input.resources=[[input.root,document],...fragments].map(([id,value])=>({id,text:render(value,json),generation:7,identity:id}));
 const original=input.resources.map(resource=>resource.text),metadata=choices(input),allowed=['direct','reusable-response','fragment','chained-fragment'].includes(kind);
 assert.equal(metadata.scalarTypes.includes('file'),allowed);assert(!metadata.unionTypes.includes('file'));
 const resource=input.resources.find(resource=>resource.id===input.resource),node=new SourceDocument(resource.text,resource.id).dataNode(input.pointer+'/type');
 assert.equal(assistSource({...input,caret:node.range[0]+1}).completions.some(choice=>choice.label==='file'),allowed);
 if(allowed){
  const result=apply(input,proposal(input,'file'));
  assert.equal(new SourceDocument(result.resources.find(resource=>resource.id===input.resource).text,input.resource).dataNode(input.pointer+'/type').value,'file');
  assert(!analyse(result).findings.some(finding=>finding.severity==='error'));
 }else assert.throws(()=>proposal(input,'file'),error=>error.code==='edit.schema-type.value');
 assert.throws(()=>proposal(input,['file']),error=>error.code==='edit.schema-type.value');
 assert.deepEqual(input.resources.map(resource=>resource.text),original);
});
for(const json of [false,true])for(const [before,after] of [['3.0.0','3.0.4'],['3.1.2','3.2.1'],['3.1.2','3.0.4']])test(`${before}→${after} ${json?'JSON':'YAML'} captured type choice is stale even when legal scalar lists match`,()=>{
 const {input,document}=fixture(before,json),captured=choices(input),original=input.resources[0].text;
 document.openapi=after;input.resources[0].text=render(document,json);
 assert.throws(()=>proposal(input,'string',captured),error=>error.code==='edit.schema-type.stale');
 assert.equal(input.resources[0].text,render(document,json));assert.notEqual(input.resources[0].text,original);
});
for(const json of [false,true])test(`Swagger ${json?'JSON':'YAML'} new body consumer invalidates an unsaved fragment type choice`,()=>{
 const {input,document}=fixture('2.0',json),part='file:///approved/part.'+(json?'json':'yaml');
 document.paths['/value'].get.responses[200].schema={$ref:part+'#/Shared'};
 input.resources[0].text=render(document,json);input.resources.push({id:part,text:render({Shared:{type:'string'}},json),generation:7,identity:part});
 input.resource=part;input.pointer='/Shared';const captured=choices(input),original=input.resources[1].text;
 assert(captured.scalarTypes.includes('file'));
 document.paths['/value'].get.parameters=[{name:'body',in:'body',schema:{$ref:part+'#/Shared'}}];
 input.resources[0].text=render(document,json);input.resources[0].generation++;
 assert.throws(()=>proposal(input,'file',captured),error=>error.code==='edit.schema-type.stale');
 assert.equal(input.resources[1].text,original);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`${version} ${json?'JSON':'YAML'} unknown schema dialect has no fallback type editor`,()=>{
 const {input,document}=fixture(version,json);document.jsonSchemaDialect='https://unsupported.invalid/dialect';input.resources[0].text=render(document,json);
 const metadata=choices(input);assert.equal(metadata.supported,false);assert.deepEqual(metadata.scalarTypes,[]);assert.deepEqual(metadata.unionTypes,[]);
 assert.throws(()=>proposal(input,'string'),error=>error.code==='edit.schema-type.unsupported'&&error.kind==='unsupported');
});
for(const value of [null,false,0,{},[],['string','string'],['file'],['null']])for(const json of [false,true])test(`3.0 ${json?'JSON':'YAML'} bound Design refuses ${JSON.stringify(value)} without changing source`,()=>{
 const {input}=fixture('3.0.4',json),original=input.resources[0].text;
 assert.throws(()=>proposal(input,value),error=>error.code==='edit.schema-type.value'&&error.kind==='specification'&&error.source.resource===input.resource&&error.source.pointer===input.pointer);assert.equal(input.resources[0].text,original);
});
for(const json of [false,true])test(`3.2 ${json?'JSON':'YAML'} document identity invalidates captured type context`,()=>{
 const {input,document}=fixture('3.2.1',json),captured=choices(input);
 document.$self='https://identity.invalid/v2';input.resources[0].text=render(document,json);
 assert.throws(()=>proposal(input,'string',captured),error=>error.code==='edit.schema-type.stale');
});
for(const json of [false,true])test(`${json?'JSON':'YAML'} preceding declaration action cannot bypass the captured schema type rules`,()=>{
 const {input}=fixture('3.1.2',json),captured=choices(input),original=input.resources[0].text;
 assert.throws(()=>propose({...input,target:inspect(input),actions:[
  {kind:'set',pointer:'/openapi',value:'3.0.4'},
  {kind:'set',pointer:input.pointer+'/type',value:['string','null'],schemaTypeChoices:captured},
 ]}),error=>error.code==='edit.schema-type.stale');
 assert.equal(input.resources[0].text,original);
});
for(const version of versions)for(const json of [false,true])test(`${version} ${json?'JSON':'YAML'} complete and partial Source type keys use native scalar capabilities`,()=>{
 const {input,document,pointer}=fixture(version,json),response=document.paths['/value'].get.responses[200];
 const schema=version==='2.0'?response.schema:response.content['application/json'].schema;
 delete schema.type;input.resources[0].text=render(document,json);
 const parsed=new SourceDocument(input.resources[0].text,input.root);
 let caret;
 if(json)caret=parsed.dataNode(pointer).range[0]+1;
 else{
  const key=parsed.dataNode(pointer+'/example').keyRange[0],start=parsed.lineStart(key),indent=parsed.text.slice(start,key);
  input.resources[0].text=parsed.text.slice(0,start)+indent+'\r\n'+parsed.text.slice(start);caret=start+indent.length;
 }
 const metadata=choices(input),original=input.resources[0].text;
 for(const partial of [false,true]){
  const marker=json?'"ty':'ty';
  const captured={...input,resources:input.resources.map(entry=>({...entry,text:partial?entry.text.slice(0,caret)+marker+entry.text.slice(caret):entry.text}))};
  const completions=assistSource({...captured,caret:caret+(partial?marker.length:0)}).completions.filter(entry=>entry.label.startsWith('type = '));
  assert.deepEqual(completions.map(entry=>JSON.parse(entry.label.slice('type = '.length))),metadata.scalarTypes);
  for(const completion of completions){
   const changed=apply(captured,{edits:completion.edits}),text=changed.resources[0].text;
   assert(metadata.scalarTypes.includes(new SourceDocument(text,input.root).dataNode(pointer+'/type').value));
   assert.equal(new SourceDocument(text,input.root).dataNode(pointer+'/description').value,'Keep 雪😀');
  }
 }
 assert.equal(input.resources[0].text,original);
});
