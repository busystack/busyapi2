const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {analyse,createGraph,inspect,propose}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {referenceDocument}=require('./dist/reference_projection.cjs');
const {deriveBundle}=require('./dist/derived_bundle.cjs');
const {requestOperation}=require('./dist/execution.cjs');
const {planRename}=require('./dist/refactoring.cjs');
const {planExtract,planInline}=require('./dist/refactoring_copy.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const api=()=>({swagger:'2.0',info:{title:'Native 雪😀',version:'3.2.1'},host:'api.invalid:8443',basePath:'/v1',schemes:['https'],consumes:['application/json'],produces:['application/json'],
 paths:{'/pets/{id}':{parameters:[{$ref:'#/parameters/Id'}],post:{operationId:'create',parameters:[{name:'tags',in:'query',type:'array',collectionFormat:'multi',items:{type:'string'}},{name:'body',in:'body',required:true,schema:{$ref:'#/definitions/Pet'}}],responses:{200:{$ref:'#/responses/Pet'}}}}},
 definitions:{Pet:{type:'object',properties:{id:{type:'integer',minimum:111},name:{type:'string'}}}},parameters:{Id:{name:'id',in:'path',required:true,type:'integer'}},responses:{Pet:{description:'Pet',schema:{$ref:'#/definitions/Pet'},headers:{'X-Values':{type:'array',items:{type:'integer'},collectionFormat:'ssv'}},examples:{'application/json':{name:'雪😀',id:111,$ref:'literal'}}}},securityDefinitions:{Basic:{type:'basic'},OAuth:{type:'oauth2',flow:'application',tokenUrl:'https://api.invalid/token',scopes:{read:'Read'}}},security:[{Basic:[]}],'x-preserved':{zero:0,empty:'',false:false}});
function capture(value,json=true,extra=[]){const root='file:///approved/swagger.'+(json?'json':'yaml');return{root,resource:root,snapshot:'native20',resources:[{id:root,text:(json?JSON.stringify(value):'# preserved\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll('111','9007199254740993.00'),generation:1,identity:'original'},...extra]};}
function target(input,pointer){const doc=new SourceDocument(input.resources[0].text,input.root),node=doc.node(pointer);return{root:input.root,resource:input.root,pointer,generation:1,range:node.range,expected:doc.text.slice(...node.range)};}
for(const json of [true,false])test(`Swagger schema fields have one reference editor ${json?'JSON':'YAML'}`,()=>{
 for(const schema of [{},{type:'object'},{$ref:'#/definitions/Other'}]){
  const value=api();value.definitions.Pet=schema;value.definitions.Other={type:'string'};
  const input=capture(value,json),fields=inspect({...input,pointer:'/definitions/Pet'}).fields;
  assert.equal(fields.filter(field=>field.name==='$ref').length,1);
  assert.equal(new Set(fields.map(field=>field.name)).size,fields.length);
 }
});
for(const json of [true,false])test(`Swagger media lists expose array metadata before creation ${json?'JSON':'YAML'}`,()=>{
 const value=api(),operation=value.paths['/pets/{id}'].post;
 for(const field of ['schemes','consumes','produces']){delete value[field];delete operation[field];}
 const input=capture(value,json);
 for(const pointer of ['', '/paths/~1pets~1{id}/post']){
  const page=inspect({...input,pointer});
  for(const name of ['schemes','consumes','produces']){
   const field=page.fields.find(field=>field.name===name);
   assert.equal(field.present,false);assert.equal(field.type,'array',pointer+'/'+name);assert.equal(field.childKind,'string-array');
   const plan=propose({...input,target:target(input,pointer),actions:[{kind:'create',pointer:pointer+'/'+name,value:[]}]}),source=input.resources[0].text;
   let text=source;for(const edit of [...plan.edits].reverse())text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);
   const changed={...input,resources:[{...input.resources[0],text}]};
   const list=inspect({...changed,pointer:pointer+'/'+name});assert.equal(list.kind,'string-array');assert.equal(list.count,0);
   assert.equal(analyse(changed).status,'complete',JSON.stringify(analyse(changed).findings));
  }
 }
});
for(const json of [true,false])test(`Swagger native ${json?'JSON':'YAML'} owners, editing, documentation, request and bundle`,async()=>{
 const input=capture(api(),json),before=input.resources[0].text,result=analyse(input);
 assert.equal(result.status,'complete',JSON.stringify(result.findings));assert.equal(result.specification.family,'2.0');assert.equal(result.operations.length,1);
 assert(!result.info.fields.some(field=>field.name==='summary'));assert(!Object.hasOwn(result.componentLocations,'callbacks'));
 assert.deepEqual(result.componentLocations,{schemas:'/definitions',parameters:'/parameters',responses:'/responses',securitySchemes:'/securityDefinitions'});
 assert(result.components.some(c=>c.pointer==='/definitions/Pet'));assert(result.components.some(c=>c.pointer==='/securityDefinitions/Basic'));
 const page=inspect({...input,pointer:'/parameters/Id'});assert(page.fields.some(f=>f.name==='type'));assert(!page.fields.some(f=>['schema','style','content'].includes(f.name)));
 const schema=inspect({...input,pointer:'/definitions/Pet'});assert(schema.fields.some(f=>f.name==='discriminator'&&f.type==='string'));assert(!schema.fields.some(f=>['nullable','writeOnly','oneOf','$schema','$id'].includes(f.name)));
 const plan=propose({...input,target:target(input,'/parameters/Id'),actions:[{kind:'set',pointer:'/parameters/Id/description',value:'Native parameter'}]});assert(plan.edits.length);
 const projection=referenceDocument(input);assert.equal(projection.complete,true);assert(projection.sections.some(s=>s.kind==='schema'&&s.source.pointer==='/definitions/Pet'));
 const operation=result.operations[0],request=requestOperation({...input,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(request.servers[0].url,'https://api.invalid:8443/v1');assert.equal(request.parameters.length,2);assert.equal(request.parameters[1].collectionFormat,'multi');assert.equal(request.parameters[0].schema.pointer,'/parameters/Id');
 assert.equal(request.requestBody.content[0].schema.pointer,'/paths/~1pets~1{id}/post/parameters/1/schema');assert.equal(request.responses[0].content[0].schema.pointer,'/responses/Pet/schema');assert(request.responses[0].content[0].example.raw.includes('9007199254740993.00'));
 assert.equal(request.security.schemes.Basic.scheme,'basic');
 const evaluation=await evaluateSchemas(input);assert.equal(evaluation.complete,true,JSON.stringify(evaluation.findings));assert(!evaluation.findings.some(f=>f.severity==='error'));
 const bundle=deriveBundle({...input,outputId:'https://output.invalid/swagger.json'}),value=JSON.parse(bundle.output.text);assert.equal(value.swagger,'2.0');assert(!value.openapi);assert(!value.components);assert(!value.servers);assert(bundle.output.text.includes('9007199254740993.00'));
 assert.equal(input.resources[0].text,before);
});
test('Swagger restricted schema and flat parameter models do not accept 3.x or modern dialect fields',async()=>{
 for(const schema of [false,{nullable:true},{oneOf:[{type:'string'}]},{writeOnly:true},{type:'number',exclusiveMinimum:1},{$schema:'https://json-schema.org/draft/2020-12/schema'}]){
  const value=api();value.definitions.Pet=schema;const input=capture(value),a=analyse(input),b=await evaluateSchemas(input);assert(a.findings.some(f=>f.severity==='error')||b.findings.some(f=>f.severity==='error'),JSON.stringify(schema));
 }
 for(const parameter of [{name:'q',in:'query',type:'object'},{name:'q',in:'query',type:'file'},{name:'q',in:'header',type:'array',items:{type:'string'},collectionFormat:'multi'},{name:'q',in:'query',type:'array'},{name:'q',in:'cookie',type:'string'}]){
  const value=api();value.paths['/pets/{id}'].post.parameters=[parameter];assert.equal(analyse(capture(value)).status,'invalid',JSON.stringify(parameter));
 }
});
test('Swagger inherited restricted Draft 4 type unions, tuple items and boolean exclusive bounds execute exactly',async()=>{
 const value=api();value.definitions.Pet={type:['integer','null'],minimum:111,exclusiveMinimum:true};const input=capture(value),result=await evaluateSchemas({...input,runtimeInstances:['null','9007199254740993','9007199254740994','9007199254740993.1'].map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer:'/definitions/Pet'}}))});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.runtimeEvaluations.map(e=>e.valid),[true,false,true,false]);
 value.definitions.Pet={type:'array',items:[{type:'integer'},{type:'string'}]};const tuple=capture(value),t=await evaluateSchemas({...tuple,runtimeInstances:['[1,"x"]','["x",1]'].map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:tuple.root,pointer:'/definitions/Pet'}}))});assert.equal(t.complete,true,JSON.stringify(t.findings));assert.deepEqual(t.runtimeEvaluations.map(e=>e.valid),[true,false]);
});
test('Swagger Reference Object siblings and response example payload keys never acquire semantics',()=>{
 const value=api();value.definitions.Alias={$ref:'#/definitions/Pet',properties:{ignored:{$ref:'unavailable.yaml'}}};const input=capture(value),graph=createGraph(input).graph;
 assert(!graph.references.some(r=>r.value==='unavailable.yaml'||r.value==='literal'));assert.equal(analyse(input).status,'complete');
 assert.throws(()=>planInline({...input,contexts:[{root:input.root,resources:[input.root]}],target:target(input,'/definitions/Alias')}),e=>e.code==='refactor.inline.ignored');
});
test('Swagger recursion, escaped pointers and shared external Path Items bundle without 3.x structures',()=>{
 const value=api();value.paths={'/one':{$ref:'paths.yaml#/Shared'},'/two':{$ref:'paths.yaml#/Shared'}};value.definitions.Pet={$ref:'models.yaml#/a~1b'};
 const input=capture(value,false,[{id:'file:///approved/paths.yaml',text:'Shared: {get: {responses: {200: {description: OK, schema: {$ref: "models.yaml#/a~1b"}}}}}',generation:2},{id:'file:///approved/models.yaml',text:'a/b: {type: object, properties: {next: {$ref: "#/a~1b"}}}',generation:3}]);
 assert.equal(analyse(input).status,'complete');const bundle=deriveBundle({...input,outputId:'https://output.invalid/swagger.json'}),out={root:bundle.output.id,snapshot:'after',resources:[{...bundle.output,generation:0}]};
 const a=analyse(out);assert.equal(a.status,'complete',JSON.stringify(a.findings));assert.equal(a.operations.length,2);assert.equal(a.operations[0].pointer,a.operations[1].pointer);assert(!JSON.parse(bundle.output.text).components);
});
test('Swagger semantic rename repairs graph consumers and keeps native source structure',()=>{
 const input=capture(api(),false),plan=planRename({...input,contexts:[{root:input.root,resources:[input.root]}],target:target(input,'/definitions/Pet'),name:'Renamed'});
 assert(plan.changes[0].after.includes('#/definitions/Renamed'));assert(!plan.changes[0].after.includes('components:'));assert(plan.changes[0].after.includes('$ref: literal'));
});
test('Swagger discriminator selects named allOf models and enforces child constraints',async()=>{
 const value=api();value.definitions={Pet:{type:'object',required:['kind'],properties:{kind:{type:'string'}},discriminator:'kind'},Cat:{allOf:[{$ref:'#/definitions/Pet'},{type:'object',required:['lives'],properties:{lives:{type:'integer',minimum:1}}}]}};
 const input=capture(value),result=await evaluateSchemas({...input,runtimeInstances:['{"kind":"Cat","lives":9}','{"kind":"Cat"}','{"kind":"Pet"}','{"kind":"Unknown"}','{}'].map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer:'/definitions/Pet'}}))});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.runtimeEvaluations.map(e=>e.valid),[true,false,true,false,false]);
});
test('Swagger readOnly properties are excluded from request payloads without changing required semantics',async()=>{
 const value=api();value.definitions.Pet={type:'object',properties:{id:{type:'integer',readOnly:true},name:{type:'string'}}};const input=capture(value),result=await evaluateSchemas({...input,runtimeInstances:[['request-body','{"id":1}'],['request-body','{"name":"n"}'],['response-body','{"id":1}']].map(([subject,text])=>({subject,location:'application/json',text,schema:{resource:input.root,pointer:'/definitions/Pet'}}))});
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.runtimeEvaluations.map(e=>e.valid),[false,true,true]);
});
test('Swagger body/form exclusivity, media inheritance, OAuth flows and parameter overrides',()=>{
 const value=api(),operation=value.paths['/pets/{id}'].post;operation.parameters=[{name:'id',in:'path',required:true,type:'string'},{name:'file',in:'formData',type:'file'}];operation.consumes=['multipart/form-data'];operation.schemes=['http'];operation.security=[{OAuth:['read']}];
 const input=capture(value),a=analyse(input);assert.equal(a.status,'complete',JSON.stringify(a.findings));const request=requestOperation({...input,pointer:a.operations[0].pointer,occurrence:a.operations[0].occurrence});assert.equal(request.parameters.length,1);assert.equal(request.parameters[0].type,'string');assert.equal(request.servers[0].url,'http://api.invalid:8443/v1');assert.equal(request.requestBody.content[0].swaggerForm[0].type,'file');assert(request.security.schemes.OAuth.flows.clientCredentials.tokenUrl);
 operation.parameters.push({name:'body',in:'body',schema:{type:'string'}});assert(analyse(capture(value)).findings.some(f=>f.code==='parameter.body.form-data'));
});
test('Swagger extraction and inlining keep the original reusable namespace and native parameter owner',()=>{
 const input=capture(api(),false),pointer='/paths/~1pets~1{id}/post/parameters/1/schema';
 const value=api();value.paths['/pets/{id}'].post.parameters[1].schema={type:'string',description:'Inline'};
 const source=capture(value,false),plan=planExtract({...source,contexts:[{root:source.root,resources:[source.root]}],target:target(source,pointer),name:'Extracted'});
 assert.equal(plan.to.pointer,'/definitions/Extracted');assert(plan.changes[0].after.includes('#/definitions/Extracted'));assert(!plan.changes[0].after.includes('components:'));
 const after={...source,resources:[{...source.resources[0],text:plan.changes[0].after}]};
 const inline=planInline({...after,contexts:[{root:source.root,resources:[source.root]}],target:target(after,pointer)});
 assert.equal(analyse({...source,resources:[{...source.resources[0],text:inline.changes[0].after}]}).status,'complete');
});
test('Swagger named discriminator models do not require a 3.x adjacent composition keyword',async()=>{
 const value=api();value.definitions={Pet:{type:'object',required:['kind'],properties:{kind:{type:'string'}},discriminator:'kind'}};
 const input=capture(value),structural=analyse(input);assert.equal(structural.status,'complete',JSON.stringify(structural.findings));const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'response-body',location:'application/json',text:'{"kind":"Pet"}',schema:{resource:input.root,pointer:'/definitions/Pet'}}]});assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.runtimeEvaluations[0].valid,true);
});
test('Swagger file parameters use Parameter metadata while response files use native file Schema metadata',async()=>{
 const value=api();value.consumes=['multipart/form-data'];value.paths['/pets/{id}'].post.parameters=[{name:'upload',in:'formData',type:'file',required:true}];value.responses.Pet.schema={type:'file'};delete value.responses.Pet.examples;
 const input=capture(value),result=await evaluateSchemas(input);assert.equal(result.complete,true,JSON.stringify(result.findings));assert(!result.findings.some(f=>f.severity==='error'),JSON.stringify(result.findings));
});
