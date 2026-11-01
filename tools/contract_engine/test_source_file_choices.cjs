const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {assistSource}=require('./dist/source_assistance.cjs');
const {analyse}=require('./dist/model.cjs');
const {SourceDocument}=require('./dist/document.cjs');

for(const kind of ['direct','reusable-response','fragment','chained-fragment','shared-body','chained-shared-body','nested','definition','body-only'])for(const json of [false,true]){
 test(`Swagger ${kind} ${json?'JSON':'YAML'} Source file choice follows captured response ownership`,()=>{
  const suffix=json?'json':'yaml',root='file:///approved/api.'+suffix,part='file:///approved/types.'+suffix,last='file:///approved/last.'+suffix;
  const document={swagger:'2.0',info:{title:'Keep 雪',version:'unrelated'},paths:{'/value':{get:{responses:{200:{description:'Keep',schema:{type:'string'}}}}}}};
  const operation=document.paths['/value'].get;
  let selected=root,pointer='/paths/~1value/get/responses/200/schema';
  const fragments=[];
  if(kind==='reusable-response'){
   document.responses={Reusable:operation.responses[200]};operation.responses[200]={$ref:'#/responses/Reusable'};pointer='/responses/Reusable/schema';
  }else if(['fragment','chained-fragment','shared-body','chained-shared-body','body-only'].includes(kind)){
   operation.responses[200].schema={$ref:'./types.'+suffix+'#/File'};
   fragments.push([part,{File:kind.startsWith('chained-')?{$ref:'./last.'+suffix+'#/Final'}:{type:'string'}}]);
   selected=part;pointer='/File';
   if(kind.startsWith('chained-')){fragments.push([last,{Final:{type:'string'}}]);selected=last;pointer='/Final';}
   if(['shared-body','chained-shared-body','body-only'].includes(kind))operation.parameters=[{name:'body',in:'body',schema:{$ref:'./types.'+suffix+'#/File'}}];
   if(kind==='body-only')delete operation.responses[200].schema;
  }else if(kind==='nested'){
   operation.responses[200].schema={type:'object',properties:{value:{type:'string'}}};pointer+='/properties/value';
  }else if(kind==='definition'){
   document.definitions={Value:{type:'string'}};operation.responses[200].schema={$ref:'#/definitions/Value'};pointer='/definitions/Value';
  }
  const render=value=>json?JSON.stringify(value,null,2):'# Keep comment\r\n'+YAML.stringify(value).replace(/\n/g,'\r\n');
  const resources=[[root,document],...fragments].map(([id,value])=>({id,text:render(value),generation:7,identity:id}));
  const source=resources.find(value=>value.id===selected),parsed=new SourceDocument(source.text,selected);
  const input={root,resource:selected,caret:parsed.dataNode(pointer+'/type').range[0]+2,snapshot:'file-choices',resources};
  const result=assistSource(input),file=result.completions.find(value=>value.label==='file');
  const allowed=['direct','reusable-response','fragment','chained-fragment'].includes(kind);
  assert.equal(Boolean(file),allowed,JSON.stringify(result.completions.map(value=>value.label)));
  if(file){
   const original=resources.map(value=>value.text);let changed=source.text;
   for(const edit of [...file.edits].reverse()){
    assert.equal(edit.buffer,selected);assert.equal(edit.generation,7);assert.equal(changed.slice(edit.start,edit.end),edit.expected);
    changed=changed.slice(0,edit.start)+edit.replacement+changed.slice(edit.end);
   }
   const report=analyse({...input,resources:resources.map(value=>value.id===selected?{...value,text:changed,generation:8}:value)});
   assert(!report.findings.some(value=>value.severity==='error'),JSON.stringify(report.findings));
   assert.equal(new SourceDocument(changed,selected).dataNode(pointer+'/type').value,'file');
   if(!json)assert(changed.startsWith('# Keep comment\r\n')&&!/(?<!\r)\n/.test(changed));
   assert.deepEqual(resources.map(value=>value.text),original);
  }
 });
}
