const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {govern}=require('./dist/governance.cjs');
const {createGraph}=require('./dist/model.cjs');
const {governanceProjection}=require('./dist/governance_projection.cjs');
const root='file:///p/root.json',fragment='file:///p/objects.json',rules='file:///p/.spectral.yaml';
function snapshot(value,policy,extra=[]) {
 return {root,snapshot:'captured',resources:[{id:root,generation:3,identity:'one',text:JSON.stringify(value)},...extra],...(policy?{policy}:{})};
}
const minimal=version=>({openapi:version,info:{title:'Policy',version:'1'},paths:{'/p':{get:{responses:{204:{description:'No body'}}}}}});
for(const version of ['3.1.2','3.2.1'])test(`callback Reference Object siblings cannot introduce governance operations ${version}`,async()=>{
 const value=minimal(version);value.paths['/p'].get.summary='Read';
 value.components={callbacks:{Shared:{'{$request.body#/real}':{post:{summary:'Real callback',responses:{204:{description:'None'}}}}}}};
 value.paths['/p'].get.callbacks={Use:{$ref:'#/components/callbacks/Shared',summary:'Reference annotation',
  '{$request.body#/ignored}':{post:{responses:{204:{description:'Ignored sibling'}}}}}};
 const input=snapshot(value),{graph}=createGraph(input),at='/paths/~1p/get/callbacks/Use';
 for(const resolved of [false,true]){
  const projection=governanceProjection(graph,resolved);
  assert(![...projection.kinds].some(([pointer,kind])=>pointer.startsWith(at+'/{$request.body#~1ignored}')&&kind!=='data'));
  assert(!projection.aliases().OperationObject.some(path=>path.includes('ignored')));
 }
 const result=await govern(input);assert.equal(result.complete,true,JSON.stringify(result));
 assert.equal(result.findings.length,0,JSON.stringify(result.findings));
 assert.equal(input.resources[0].text,JSON.stringify(value));
});
test('bounded Server policy failures cannot produce green governance',async()=>{
 const value=minimal('3.2.1');value.paths['/p'].get.summary='Read';value.servers=[{url:'https://example.test/'+'a'.repeat(65536)}];
 const result=await govern(snapshot(value));assert.equal(result.complete,false);assert.equal(result.status,'incomplete');assert(result.findings.length>0);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`Server variable advice is configured policy, not normative invalidity or payload traversal ${version} ${json?'JSON':'YAML'}`,async()=>{
 const value=minimal(version);value.paths['/p'].get.summary='Read';
 value.servers=[{url:'https://{missing}.example.test',variables:{unused:{default:'not a credential'}}}];
 value.paths['/p'].servers=[{url:'../{region}',variables:{region:{default:'east'},extra:{default:'data'}}}];
 value['x-data']={servers:[{url:'https://{unknown}',variables:{unused:{default:'data'}}}]};
 const id=root.replace('.json',json?'.json':'.yaml'),text=json?JSON.stringify(value):YAML.stringify(value),input={root:id,snapshot:'server-policy',resources:[{id,text,generation:1}]};
 const validity=require('./dist/model.cjs').analyse(input);
 assert.equal(validity.status,'complete',JSON.stringify(validity.findings));assert.equal(validity.complete,true);
 const result=await govern(input),findings=result.findings.filter(f=>f.code==='policy.rule.server-variable-declarations');
 assert.equal(result.complete,true,JSON.stringify(result));assert.equal(findings.length,3);assert(findings.every(f=>f.resource===id&&f.severity==='warning'&&!f.pointer.startsWith('/x-data')));
 assert(result.effectiveRules.find(r=>r.name==='server-variable-declarations').provenance.some(p=>p.resource==='busyapi:recommended'));
 const resources=[{id:rules,text:'extends: busyapi:recommended\nrules: {server-variable-declarations: off}\n'}];
 const disabled=await govern({...input,policy:{source:rules,entries:[rules],resources}});
 assert.equal(disabled.complete,true);assert(!disabled.findings.some(f=>f.code==='policy.rule.server-variable-declarations'));
 const error=await govern({...input,policy:{source:rules,entries:[rules],resources:[{...resources[0],text:resources[0].text.replace(': off',': error')}]}});
 assert.equal(error.findings.filter(f=>f.code==='policy.rule.server-variable-declarations'&&f.severity==='error').length,3);
 assert.equal(input.resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`canonical policy locations and versioned operation inventory ${version} ${json?'JSON':'YAML'}`,async()=>{
 const value=minimal(version);
 if(version==='3.2.1') {
  value.paths['/p'].query={responses:{204:{description:'No body'}}};
  value.paths['/p'].additionalOperations={PURGE:{responses:{204:{description:'No body'}}}};
 }
 value.webhooks={event:{post:{responses:{200:{description:'Received'}}}}};
 value.paths['/p'].get.callbacks={reply:{'{$request.body#/url}':{post:{responses:{200:{description:'Reply'}}}}}};
 value['x-data']={paths:{'/fake':{get:{}}},$ref:'not a dependency'};
 const input=snapshot(value);
 input.root=input.resources[0].id='file:///p/root.'+(json?'json':'yaml');
 input.resources[0].text=json?JSON.stringify(value):YAML.stringify(value);
 const result=await govern(input);
 assert.equal(result.complete,true,JSON.stringify(result));
 assert.equal(result.findings.length,version==='3.2.1'?5:3,JSON.stringify(result));
 assert(result.findings.every(f=>f.category==='policy'&&f.resource===input.root&&f.range[1]>f.range[0]&&!f.pointer.includes('x-data')));
 assert(result.findings.some(f=>f.pointer.includes('callbacks')));
 assert(result.findings.some(f=>f.pointer.startsWith('/webhooks')));
 assert(result.effectiveRules[0].provenance.some(p=>p.resource==='busyapi:recommended'));
});
test('resolved shared Path Items attribute all operation findings to the supplied fragment',async()=>{
 const value=minimal('3.2.1');value.paths={'/a':{$ref:'objects.json#/Item'},'/b':{$ref:'objects.json#/Item'}};
 const result=await govern(snapshot(value,undefined,[{id:fragment,generation:2,text:JSON.stringify({Item:{get:{responses:{204:{description:'None'}}}}})}]));
 assert.equal(result.complete,true,JSON.stringify(result));
 assert.equal(result.findings.length,2);
 for(const finding of result.findings){assert.equal(finding.resource,fragment);assert.equal(finding.pointer,'/Item/get');assert.deepEqual(finding.range,[15,59]);}
});
test('Reference Object annotations retain source ownership without schema applicator merging or payload lookup',()=>{
 const value=minimal('3.2.1');value.components={responses:{Shared:{description:'Definition',content:{'application/json':{schema:{$ref:'objects.json#/Model',description:'Local'},example:{$ref:'literal payload'},examples:{remote:{externalValue:'https://must-not-read.invalid'}}}}}}};
 value.paths['/p'].get.responses[200]={$ref:'#/components/responses/Shared',description:'Occurrence'};
 const input=snapshot(value,undefined,[{id:fragment,generation:2,text:'{"Model":{"type":"object","properties":{"n":{"type":"integer"}}}}'}]);
 const {graph}=createGraph(input),view=governanceProjection(graph,true);
 const response=view.value.paths['/p'].get.responses[200];
 assert.equal(response.description,'Occurrence');
 assert.deepEqual(response.content['application/json'].schema,{$ref:'objects.json#/Model',description:'Local'});
 assert.deepEqual(response.content['application/json'].example,{$ref:'literal payload'});
 assert.equal(view.origin(['paths','/p','get','responses',200,'description']).pointer,'/paths/~1p/get/responses/200/description');
 assert.equal(view.origin(['paths','/p','get','responses',200,'content']).pointer,'/components/responses/Shared/content');
 assert.equal(view.problems.length,0);assert.equal(graph.references.length,2);
});
test('project declarative rules, extends, severity, applicability and file overrides retain deterministic provenance',async()=>{
 const value=minimal('3.2.1');value.info.description='Documented';
 const parent='file:///p/base.yaml';
 const policy={source:rules,entries:[rules],resources:[{id:parent,text:'rules:\n  title-rule:\n    given: $.info\n    then: {field: summary, function: truthy}\n    severity: error\n'},{id:rules,text:'extends: [busyapi:recommended, ./base.yaml]\nrules:\n  operation-summary: off\n  title-rule: warn\n  only-31:\n    formats: [oas3_1]\n    given: $.info\n    then: {field: missing, function: truthy}\noverrides:\n  - files: ["root.json"]\n    rules: {title-rule: error}\n'}]};
 const one=await govern(snapshot(value,policy)),two=await govern(snapshot(value,{...policy,resources:[...policy.resources].reverse()}));
 assert.equal(one.complete,true,JSON.stringify(one));assert.equal(one.configuration,two.configuration);
 assert.deepEqual(one.findings,two.findings);
 assert.equal(one.findings.length,1,JSON.stringify(one));assert.equal(one.findings[0].severity,'error');
 assert.equal(one.findings[0].pointer,'/info');
 assert.deepEqual(one.effectiveRules.find(r=>r.name==='title-rule').provenance.map(p=>p.action),['definition','severity','severity']);
 assert.equal(one.effectiveRules.find(r=>r.name==='only-31').applicable,false);
 assert.equal(one.effectiveRules.find(r=>r.name==='operation-summary').enabled,false);
});
test('unavailable extends, cycles and executable functions fail closed while safe declarative rules remain useful',async()=>{
 const value=minimal('3.1.2');
 const policy={source:rules,entries:[rules],resources:[{id:rules,text:'extends: [./missing.yaml, ./.spectral.yaml, busyapi:recommended]\nfunctions: [danger]\nrules:\n  danger:\n    given: $\n    then: {function: danger}\n'}]};
 const result=await govern(snapshot(value,policy));
 assert.equal(result.complete,false);assert.equal(result.status,'incomplete');
 for(const code of ['policy.ruleset.cycle','policy.resource.unapproved','policy.code.approval-required','policy.rule.operation-summary'])assert(result.findings.some(f=>f.code===code),JSON.stringify(result));
 assert(!result.effectiveRules.some(r=>r.name==='danger'));
});
test('ordinary governance never evaluates secondary, escaped, aliased or field project expressions without approval',async()=>{
 for(const [given,aliases,field]of [
  [['$.info','$.tags[?(@.name)]'],undefined,'summary'],
  ['$["constr\\u0075ctor"]',undefined,'summary'],
  ['#Selected',{Selected:['$.info','$.tags[?(@.name)]']},'summary'],
  ['$.info',undefined,'$[?(@.title)]'],
 ]) {
  const policy={source:rules,entries:[rules],resources:[{id:rules,text:JSON.stringify({aliases,
   rules:{unsafe:{given,then:{field,function:'truthy'}}}})}]};
  const result=await govern(snapshot(minimal('3.2.1'),policy));
  assert.equal(result.complete,false,JSON.stringify(result));
  assert(result.findings.some(value=>value.code==='policy.expression.isolation'),JSON.stringify(result));
  assert(!result.findings.some(value=>value.code==='policy.rule.unsafe'));
 }
});
test('inherited override globs retain their declaring directory and local declarations have deterministic precedence',async()=>{
 const parent='file:///p/policies/base.yaml';
 const policy={source:rules,entries:[rules],resources:[
  {id:parent,text:'extends: busyapi:recommended\noverrides:\n  - files: ["../root.json"]\n    rules: {operation-summary: error}\n  - files: ["../other.json"]\n    rules: {operation-summary: off}\n'},
  {id:rules,text:'extends: ./policies/base.yaml\nrules: {operation-summary: info}\n'},
 ]};
 const result=await govern(snapshot(minimal('3.2.1'),policy));
 assert.equal(result.complete,true,JSON.stringify(result));
 assert.equal(result.findings.length,1);assert.equal(result.findings[0].severity,'information');
 const chain=result.effectiveRules.find(rule=>rule.name==='operation-summary').provenance;
 assert(chain.some(item=>item.resource===parent&&item.pointer==='/overrides/0/rules/operation-summary'));
 assert(!chain.some(item=>item.pointer.startsWith('/overrides/1')));
 assert.equal(chain.at(-1).resource,rules);
 policy.resources[1].text='extends: ./policies/base.yaml\n';
 const inherited=await govern(snapshot(minimal('3.2.1'),policy));
 assert.equal(inherited.complete,true,JSON.stringify(inherited));assert.equal(inherited.findings[0].severity,'error');
});
test('inherited pointer severity can enable an otherwise disabled rule without rebasing its source',async()=>{
 const parent='file:///p/policies/base.yaml';
 const value=minimal('3.2.1');value.paths['/second']={get:{responses:{204:{description:'None'}}}};
 const policy={source:rules,entries:[rules],resources:[
  {id:parent,text:'extends: busyapi:recommended\nrules: {operation-summary: off}\noverrides:\n  - files: ["../root.json#/paths/~1p/get"]\n    rules: {operation-summary: error}\n'},
  {id:rules,text:'extends: ./policies/base.yaml\n'},
 ]};
 const result=await govern(snapshot(value,policy));assert.equal(result.complete,true,JSON.stringify(result));
 assert.equal(result.findings.length,1,JSON.stringify(result.findings));
 assert.equal(result.findings[0].severity,'error');assert.equal(result.findings[0].pointer,'/paths/~1p/get');
});
test('an inactive override cannot replace preset provenance or route exact examples through an upstream numeric validator',async()=>{
 const value=minimal('3.2.1');value.components={schemas:{Value:{type:'integer',minimum:'$EXACT',examples:['$EXACT']}}};
 const input=snapshot(value,{source:rules,entries:[rules],resources:[{id:rules,text:'extends: spectral:oas\noverrides:\n  - files: ["other.json"]\n    rules:\n      oas3-valid-schema-example:\n        given: $.info\n        then: {function: falsy}\n'}]});
 input.resources[0].text=input.resources[0].text.replaceAll('"$EXACT"','9007199254740993');
 const result=await govern(input);assert.equal(result.complete,true,JSON.stringify(result));
 assert(!result.findings.some(f=>f.code==='policy.numeric.incomplete'||f.code==='policy.rule.oas3-valid-schema-example'));
 const provenance=result.effectiveRules.find(rule=>rule.name==='oas3-valid-schema-example').provenance;
 assert(provenance.every(item=>item.resource==='spectral:oas'));
});
test('malicious and executable project selectors do not enter the worker evaluator',async()=>{
 const policy={source:rules,entries:[rules],resources:[{id:rules,text:JSON.stringify({rules:{escape:{given:'$..[?(@.constructor.constructor("return process")())]',then:{function:'truthy'}}}})}]};
 const result=await govern(snapshot(minimal('3.2.1'),policy));assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='policy.expression.isolation'));
});
test('an inactive override cannot import pointer layers or provenance from its conditional extension',async()=>{
 const parent='file:///p/conditional.yaml';
 const policy={source:rules,entries:[rules],resources:[
  {id:parent,text:'extends: busyapi:recommended\noverrides:\n  - files: ["root.json#/paths/~1p/get"]\n    rules: {operation-summary: error}\n'},
  {id:rules,text:'extends: busyapi:recommended\noverrides:\n  - files: ["other.json"]\n    extends: ./conditional.yaml\n    rules: {operation-summary: off}\n'},
 ]};
 const result=await govern(snapshot(minimal('3.2.1'),policy));
 assert.equal(result.complete,true,JSON.stringify(result));assert.equal(result.findings.length,1);
 assert.equal(result.findings[0].severity,'warning');
 assert(result.effectiveRules[0].provenance.every(item=>item.resource==='busyapi:recommended'));
});
test('rounded numeric comparisons and broken adapters cannot return a clean category',async()=>{
 const policy={source:rules,entries:[rules],resources:[{id:rules,text:JSON.stringify({rules:{numeric:{given:'$.x-number',then:{function:'schema',functionOptions:{schema:{type:'integer',minimum:1}}}}}})}]};
 const input=snapshot({...minimal('3.2.1'),'x-number':1},policy);
 input.resources[0].text=input.resources[0].text.replace('"x-number":1','"x-number":9007199254740993');
 const result=await govern(input);assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='policy.numeric.incomplete'),JSON.stringify(result));
});
test('rule messages do not echo suspicious source values or interpolated payloads',async()=>{
 const secret='ghp_'+'A9b'.repeat(12);
 const policy={source:rules,entries:[rules],resources:[{id:rules,text:JSON.stringify({rules:{token:{given:'$.x-token',message:'Unsafe {{value}}',then:{function:'falsy'}}}})}]};
 const result=await govern(snapshot({...minimal('3.2.1'),'x-token':secret},policy));
 assert.equal(result.complete,true);assert.equal(result.findings.length,1);assert(!JSON.stringify(result).includes(secret));
 const named={source:rules,entries:[rules],resources:[{id:rules,text:JSON.stringify({rules:{[secret]:{given:'$.x-token',then:{function:'falsy'}}}})}]};
 const masked=await govern(snapshot({...minimal('3.2.1'),'x-token':secret},named));
 assert.equal(masked.complete,true);assert(!JSON.stringify(masked).includes(secret));
 assert(masked.effectiveRules[0].name.startsWith('masked-'));
 assert.equal(masked.findings[0].rule,masked.effectiveRules[0].name);
});
test('undefined Path Item siblings, Reference Object cycles and denied resources remain incomplete',async()=>{
 const value=minimal('3.2.1');value.paths['/p']={$ref:'#/components/pathItems/Item',summary:'Undefined sibling'};
 value.components={pathItems:{Item:{$ref:'#/components/pathItems/Item',summary:'Conflicting definition'}}};
 const result=await govern(snapshot(value));assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='policy.path-item.ambiguous'));
 value.paths['/p']={$ref:'#/components/pathItems/Item'};
 const cycle=await govern(snapshot(value));assert.equal(cycle.complete,false);assert(cycle.findings.some(f=>f.code==='policy.reference.cycle'));
});
test('the pinned OAS preset executes real rules through supplied canonical values',async()=>{
 const result=await govern(snapshot(minimal('3.2.1'),{entries:['spectral:oas']}));
 assert.equal(result.complete,true,JSON.stringify(result));
 assert(result.findings.some(f=>f.code==='policy.rule.info-description'),JSON.stringify(result));
 assert(!result.findings.some(f=>f.code==='policy.execution.failed'));
});
test('preset component usages come only from the canonical graph, including implicit names and new families',async()=>{
 const value=minimal('3.2.1');
 value.security=[{Auth:[]}];
 value.components={schemas:{Used:{type:'string'},Unused:{type:'string'}},securitySchemes:{Auth:{type:'http',scheme:'basic'},UnusedAuth:{type:'http',scheme:'basic'}},pathItems:{UnusedPath:{get:{summary:'Spare',responses:{204:{description:'None'}}}}}};
 value.paths['/p'].get.responses[200]={description:'OK',content:{'application/json':{schema:{$ref:'#/components/schemas/Used'},example:{$ref:'#/components/schemas/Unused'}}}};
 const result=await govern(snapshot(value,{entries:['spectral:oas']}));
 assert.equal(result.complete,true,JSON.stringify(result));
 const unused=result.findings.filter(f=>f.code==='policy.rule.oas3-unused-component').map(f=>f.pointer).sort();
 assert.deepEqual(unused,['/components/pathItems/UnusedPath','/components/schemas/Unused','/components/securitySchemes/UnusedAuth']);
 assert(!result.findings.some(f=>f.code==='policy.execution.failed'));
});
test('preset schema-looking payloads and descriptions remain data, including literal references',async()=>{
 const value=minimal('3.2.1');
 value['x-payload']={enum:[1,1],type:'integer',xml:{attribute:true},description:'<script>literal text</script>',$ref:'literal payload'};
 value.paths['/p'].get.responses[200]={description:'Data',content:{'application/json':{schema:true,example:{content:{'application/json':{schema:{type:'integer'},example:'not an API example'}},enum:[1,1],type:'integer',$ref:'literal payload'}}}};
 const input=snapshot(value,{entries:['spectral:oas']}),before=input.resources[0].text,failures=[],result=await govern(input,error=>failures.push(error));
 assert.equal(result.complete,true,failures.map(error=>error.stack+'\n'+error.cause?.stack).join('\n')||JSON.stringify(result.findings));
 assert(!result.findings.some(f=>f.pointer.startsWith('/x-payload')||f.pointer.includes('/example/')),JSON.stringify(result.findings));
 assert.equal(input.resources[0].text,before);
});
test('reserved identifiers fail closed rather than changing a ruleset prototype or disappearing',async()=>{
 const text='{"rules":{"__proto__":{"given":"$","then":{"function":"truthy"}}}}';
 const result=await govern(snapshot(minimal('3.2.1'),{source:rules,entries:[rules],resources:[{id:rules,text}]}));
 assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='policy.rule.identifier'));
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`preset example checks share exact schema evaluation, nested identities and recursion ${version} ${json?'JSON':'YAML'}`,async()=>{
 const id='file:///p/root.'+(json?'json':'yaml'),model='file:///p/model.'+(json?'json':'yaml');
 const value=minimal(version);
 value.components={schemas:{Count:{type:'integer',enum:['$EXACT_A','$EXACT_B'],examples:['$EXACT_A']},Never:false}};
 value.paths['/p'].get.responses[200]={description:'OK',content:{'application/json':{schema:{$ref:model+'#/Model'},examples:{good:{value:{value:'$EXACT_A',next:{value:'$EXACT_A'},$ref:'literal payload'}},bad:{value:{value:'$EXACT_B'}},remote:{externalValue:'https://must-not-load.invalid/example'}}}}};
 const definition={Model:{$id:'https://schemas.example/Model',$dynamicAnchor:'node',type:'object',properties:{value:{type:'integer',minimum:'$EXACT_A'},next:{$dynamicRef:'#node'}},required:['value']}};
 const text=value=>(json?JSON.stringify(value):YAML.stringify(value)).replaceAll('"$EXACT_A"','9007199254740993').replaceAll('"$EXACT_B"','9007199254740992').replaceAll('$EXACT_A','9007199254740993').replaceAll('$EXACT_B','9007199254740992');
 const input={root:id,snapshot:'exact-policy',resources:[{id,generation:2,text:text(value)},{id:model,generation:4,text:text(definition)}],policy:{entries:['spectral:oas']}};
 const before=input.resources.map(r=>r.text),result=await govern(input);
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert(!result.findings.some(f=>f.code==='policy.numeric.incomplete'||f.code==='policy.rule.duplicated-entry-in-enum'||f.code==='policy.rule.typed-enum'),JSON.stringify(result.findings));
 const examples=result.findings.filter(f=>f.code==='policy.rule.oas3-valid-media-example');
 assert.equal(examples.length,1,JSON.stringify(examples));assert.equal(examples[0].resource,id);assert(examples[0].pointer.includes('/examples/bad/value/value'));
 assert(!result.findings.some(f=>f.pointer.includes('/examples/good')));
 assert.deepEqual(input.resources.map(r=>r.text),before);
});
test('global preset rules include 3.2 additional methods, webhooks and implicit scheme identities',async()=>{
 const value=minimal('3.2.1');value.tags=[{name:'Declared'}];
 value.paths['/p'].get.operationId='same';
 value.paths['/p'].additionalOperations={PURGE:{operationId:'same',tags:['Unknown'],security:[{'#/components/securitySchemes/MissingAuth':[]}],responses:{204:{description:'None'}}}};
 value.webhooks={event:{query:{operationId:'another',tags:['Missing'],responses:{204:{description:'None'}}}}};
 const input=snapshot(value,{entries:['spectral:oas']});
 const result=await govern(input);assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert(result.findings.some(f=>f.code==='policy.rule.operation-operationId-unique'&&f.pointer.includes('/additionalOperations/PURGE/operationId')));
 assert(result.findings.some(f=>f.code==='policy.rule.operation-tag-defined'&&f.pointer.startsWith('/webhooks/')));
 assert(result.findings.some(f=>f.code==='policy.rule.operation-tag-defined'&&f.pointer.includes('/additionalOperations/')));
 assert(result.findings.some(f=>f.code==='policy.rule.oas3-operation-security-defined'));
 value.paths['/p'].additionalOperations.PURGE.security=[{'https://schemes.example/Auth':[]}];
 const unavailable=await govern(snapshot(value,{entries:['spectral:oas']}));
 assert.equal(unavailable.complete,false,'an unavailable implicit URI cannot be reported as complete');
 assert(unavailable.findings.some(f=>f.code==='policy.rule.oas3-operation-security-defined'));
});
