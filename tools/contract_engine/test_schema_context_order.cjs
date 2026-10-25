const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {createGraph,analyse}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');

for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])
for(const chained of [false,true])for(const relative of [false,true])
test(`complete schema context precedes descendant resolution ${version} ${format} chain=${chained} relative=${relative}`,async()=>{
 const root='file:///scope-order/api.'+format,model='file:///scope-order/model.'+format,alias='file:///scope-order/alias.'+format;
 const canonical=relative?'https://schemas.invalid/leaf':'https://schemas.invalid/envelope';
 const node={...(relative?{$id:'leaf'}:{}),$anchor:'node',$dynamicAnchor:'dynamic',type:'object',required:['n'],
  properties:{n:{type:'integer',enum:['EXACT']},next:{$ref:relative?'#node':'#/$defs/Old'}},additionalProperties:false};
 const description={openapi:version,info:{title:'Complete scope order 雪😀',version:'1'},
  paths:{'/items':{get:{responses:{200:{description:'Captured',content:{'application/json':{schema:{$ref:'model.'+format+'#/Envelope/$defs/Old'}}}}}}}},
  components:{schemas:{Envelope:{$ref:chained?'alias.'+format+'#/Entry':'model.'+format+'#/Envelope'},
   Anchored:{$ref:canonical+'#node'}}},'x-payload':{$id:'https://literal.invalid/', $ref:'literal-only'}};
 const encode=value=>(format==='json'?JSON.stringify(value):'# retain source order\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'))
  .replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 const resources=[{id:root,text:encode(description),generation:1},
  {id:model,text:encode({Envelope:{$id:'https://schemas.invalid/envelope',type:'object',$defs:{Old:node}}}),generation:2},
  ...(chained?[{id:alias,text:encode({Entry:{$ref:'model.'+format+'#/Envelope'}}),generation:3}]:[])];
 const input={root,snapshot:version+format+chained+relative,resources},before=resources.map(resource=>resource.text);
 const context=createGraph(input),graph=context.graph;
 assert.deepEqual(graph.issues,[]);assert.equal(analyse(input).status,'complete');
 const next=graph.references.find(reference=>reference.resource===model&&reference.pointer==='/Envelope/$defs/Old/properties/next');
 assert.equal(next.base,canonical);assert.equal(next.resolution,'resolved');assert.equal(next.targetPointer,'/Envelope/$defs/Old');
 assert.equal(graph.anchors.get(canonical+'#node').length,1);
 assert.equal(graph.anchors.has('file:///scope-order/model.'+format+'#node'),false);
 assert.equal(graph.identities.has('file:///scope-order/leaf'),false);
 assert(!graph.references.some(reference=>reference.pointer.startsWith('/x-payload')));
 const result=await evaluateSchemas({...input,runtimeInstances:['9007199254740993.00','9007199254740992.00'].map((number,index)=>({
  subject:'response-body',location:'captured-'+index,schema:{resource:model,pointer:'/Envelope/$defs/Old'},text:'{"n":'+number+'}'}))},undefined,context);
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.deepEqual(result.runtimeEvaluations.map(value=>[value.complete,value.valid]),[[true,true],[true,false]]);
 const again=createGraph(input).graph;
 assert.deepEqual(again.references.map(reference=>[reference.resource,reference.pointer,reference.base,reference.targetResource,reference.targetPointer]),
  graph.references.map(reference=>[reference.resource,reference.pointer,reference.base,reference.targetResource,reference.targetPointer]));
 assert.deepEqual(resources.map(resource=>resource.text),before);
});
