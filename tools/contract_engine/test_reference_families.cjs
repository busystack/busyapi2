const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse,createGraph}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const versions=['2.0','3.0.4','3.1.2','3.2.1'];
const modern=version=>version==='3.1.2'||version==='3.2.1';
const pointer=version=>version==='2.0'?'/definitions/Value':'/components/schemas/Value';
const schemas=(version,value)=>version==='2.0'?{definitions:{Value:value}}:{components:{schemas:{Value:value}}};
const document=(version,extra)=>({...version==='2.0'?{swagger:version}:{openapi:version},info:{title:'Family context',version:'api-version'},paths:{},...extra});
const capture=(format,root,part)=>({root:'file:///family/root.'+format,snapshot:'family-context',resources:[
 {id:'file:///family/root.'+format,generation:1,text:format==='json'?JSON.stringify(root):YAML.stringify(root)},
 {id:'file:///family/part.'+format,generation:1,text:format==='json'?JSON.stringify(part):YAML.stringify(part)},
]});

for(const from of versions)for(const to of versions)for(const format of ['json','yaml'])test(`${from} to ${to} ${format} reference context preserves owning families`,async()=>{
 const input=capture(format,document(from,schemas(from,{$ref:'part.'+format+'#'+pointer(to)})),document(to,schemas(to,{type:'string',enum:['雪']})));
 const original=input.resources.map(resource=>resource.text),compatible=from===to||modern(from)&&modern(to),source=pointer(from)+'/$ref';
 const structural=analyse(input),graph=createGraph(input).graph,edge=graph.references.find(edge=>edge.resource===input.root&&edge.pointer===pointer(from));
 assert.equal(structural.complete,compatible,JSON.stringify(structural.findings));
 assert.equal(edge.targetResource,input.resources[1].id);assert.equal(edge.targetPointer,pointer(to));
 assert.equal(graph.scope(input.resources[1].id,pointer(to)).family,to==='2.0'?'2.0':to.slice(0,3));
 if(!compatible){
  assert.equal(edge.resolution,'incompatible-family');
  assert(structural.findings.some(f=>f.code==='reference.family.unsupported'&&f.resource===input.root&&f.pointer===source&&f.range[1]>f.range[0]));
 }else assert.equal(edge.resolution,'resolved');
 for(const text of ['"雪"','"wrong"']){
  const evaluated=await evaluateSchemas({...input,runtimeInstances:[{subject:'request-body',location:'application/json',text,schema:{resource:input.root,pointer:pointer(from)}}]});
  assert.equal(evaluated.complete,compatible,JSON.stringify(evaluated.findings));
  assert.equal(evaluated.runtimeEvaluations[0].complete,compatible);
  assert.equal(evaluated.runtimeEvaluations[0].valid,compatible&&text==='"雪"');
 }
 assert.deepEqual(input.resources.map(resource=>resource.text),original);
});

for(const format of ['json','yaml'])for(const value of [false,{type:['string','null']},{type:'string',nullable:true}])test(`3.0 cannot acquire modern schema rules through a ${format} Reference Object ${JSON.stringify(value)}`,async()=>{
 const input=capture(format,document('3.0.4',schemas('3.0.4',{$ref:'part.'+format+'#/components/schemas/Value'})),document('3.1.2',schemas('3.1.2',value)));
 const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'request-body',location:'application/json',text:'null',schema:{resource:input.root,pointer:pointer('3.0.4')}}]});
 assert.equal(result.complete,false);assert.equal(result.runtimeEvaluations[0].complete,false);assert.equal(result.runtimeEvaluations[0].valid,false);
 assert(result.findings.some(f=>f.code==='reference.family.unsupported'&&f.resource===input.root&&f.pointer.endsWith('/$ref')));
});

for(const version of versions)for(const format of ['json','yaml'])test(`${version} ${format} unversioned shared schemas retain the referring context`,async()=>{
 const input=capture(format,document(version,schemas(version,{$ref:'part.'+format+'#/Value'})),{Value:{type:'integer',minimum:0}});
 assert.equal(analyse(input).complete,true);
 const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'request-body',location:'application/json',text:'0',schema:{resource:input.root,pointer:pointer(version)}}]});
 assert.equal(result.complete,true);assert.equal(result.runtimeEvaluations[0].valid,true);
});

for(const kind of ['parameter','response','path-item'])for(const format of ['json','yaml'])test(`legacy ${format} ${kind} references cannot change object family`,()=>{
 const target={parameter:{name:'n',in:'query',schema:{type:'integer'}},response:{description:'Empty'},'path-item':{get:{responses:{204:{description:'Empty'}}}}}[kind];
 const source=kind==='parameter'?{parameters:[{$ref:'part.'+format+'#/paths/~1part/get/parameters/0'}],responses:{204:{description:'Empty'}}}:kind==='response'?{responses:{204:{$ref:'part.'+format+'#/paths/~1part/get/responses/204'}}}:undefined;
 const part=document('3.1.2',{paths:{'/part':kind==='path-item'?target:{get:{parameters:kind==='parameter'?[target]:[],responses:{204:kind==='response'?target:{description:'Empty'}}}}}});
 const input=capture(format,document('3.0.4',{paths:{'/use':source?{get:source}:{$ref:'part.'+format+'#/paths/~1part'}}}),part),result=analyse(input);
 assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='reference.family.unsupported'&&f.resource===input.root));
});

test('chained cross-family references retain the physical failing owner and do not affect payload lookalikes',async()=>{
 const input=capture('json',document('3.0.4',schemas('3.0.4',{$ref:'part.json#/Value'})),{Value:{$ref:'modern.json#/components/schemas/Value'}});
 input.resources.push({id:'file:///family/modern.json',generation:1,text:JSON.stringify(document('3.2.1',schemas('3.2.1',{type:'integer'})))});
 let result=analyse(input);assert.equal(result.complete,false);
 assert(result.findings.some(f=>f.code==='reference.family.unsupported'&&f.resource===input.resources[1].id&&f.pointer==='/Value/$ref'));
 input.resources[0].text=JSON.stringify(document('3.0.4',schemas('3.0.4',{type:'object',example:{$ref:'modern.json#/components/schemas/Value'}})));
 result=analyse(input);assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(createGraph(input).graph.references.length,0);
});

test('repeated root-family changes rebind an unversioned nullable schema without stale dialects',async()=>{
 for(const version of ['3.0.4','3.1.2','3.2.1','3.0.4','3.2.1','3.1.2']){
  const input=capture('json',document(version,schemas(version,{$ref:'part.json#/Value'})),{Value:{type:'string',nullable:true}});
  const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'request-body',location:'application/json',text:'null',schema:{resource:input.root,pointer:pointer(version)}}]});
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.runtimeEvaluations[0].valid,version==='3.0.4');
 }
});

for(const from of versions)for(const to of versions)for(const format of ['json','yaml'])test(`${from} to ${to} ${format} typed choices exclude incompatible family substitutions`,()=>{
 const input=capture(format,document(from,schemas(from,{$ref:'part.'+format+'#'+pointer(to)})),document(to,schemas(to,{type:'string'})));
 const result=require('./dist/reference_choices.cjs').referenceChoices({...input,resource:input.root,pointer:pointer(from),query:'Value'});
 assert.equal(result.entries.some(entry=>entry.target.resource===input.resources[1].id),from===to||modern(from)&&modern(to));
});

for(const [from,to]of [['3.0.4','2.0'],['3.1.2','3.0.4']])test(`${from} operationRef can identify a ${to} operation without substituting its object context`,()=>{
 const input=capture('json',document(from,{paths:{'/use':{get:{responses:{204:{description:'Empty',links:{next:{operationRef:'part.json#/paths/~1part/get'}}}}}}}}),document(to,{paths:{'/part':{get:{responses:{204:{description:'Empty'}}}}}}));
 const result=analyse(input);assert.equal(result.complete,true,JSON.stringify(result.findings));
 const choices=require('./dist/reference_choices.cjs').referenceChoices({...input,resource:input.root,pointer:'/paths/~1use/get/responses/204/links/next',keyword:'operationRef',query:'/part'});
 assert(choices.entries.some(entry=>entry.target.resource===input.resources[1].id&&entry.target.pointer==='/paths/~1part/get'));
});
