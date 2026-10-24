const assert=require('node:assert/strict'),{test}=require('node:test'),fs=require('node:fs');
const {planMigration}=require('./dist/migration.cjs'),{analyse}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const versions={'2.0':'2.0','3.0':'3.0.4','3.1':'3.1.2','3.2':'3.2.1'};
function capture(text,format='yaml',extras=[]){const root='file:///approved/api.'+format;return{root,snapshot:'migration',targetVersion:'3.2.1',destination:'file:///output/review/',resources:[{id:root,text,generation:1,identity:'source'},...extras]};}
for(const family of Object.keys(versions))for(const format of ['yaml','json'])for(const targetVersion of Object.values(versions))test(`migration ${family} ${format} → ${targetVersion} uses native target rules and preserves source`,async()=>{
 const text=fs.readFileSync(`${__dirname}/fixtures/native-families/${family}-valid.${format}`,'utf8'),input={...capture(text,format),targetVersion},result=await planMigration(input);
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.status,'faithfully-convertible');assert(result.identity);assert.equal(result.target.declaredVersion,targetVersion);
 assert.equal(input.resources[0].text,text);assert(result.outputs[0].text.includes('9007199254740993.00'));assert(result.invariants.requests);
 const resources=result.outputs.map(output=>({id:output.id,text:output.text,generation:0,aliases:Object.entries(result.manifest.resourceMappings).filter(([,path])=>path===output.path).map(([uri])=>uri)}));
 const after={root:result.outputRoot,snapshot:'after',resources};assert.equal(analyse(after).status,'complete');assert.equal((await evaluateSchemas(after)).complete,true);
});
test('3.0 nullable/composition and exact boolean bounds migrate with behavior-sensitive runtime comparisons and comments',async()=>{
 const input=capture('# Top\r\nopenapi: 3.0.4\r\ninfo: {title: Exact, version: "1"}\r\npaths: {}\r\ncomponents:\r\n  schemas:\r\n    N:\r\n      type: integer\r\n      minimum: 9007199254740993 # bound\r\n      exclusiveMinimum: true # strict\r\n    S: {type: string, nullable: true, enum: [text]}\r\n    F: {type: integer, exclusiveMaximum: false} # keep\r\nx-number: 9007199254740993.00\r\n');
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));const text=result.outputs[0].text;assert(text.includes('# bound'));assert(text.includes('# strict'));assert(text.includes('# keep'));assert(text.startsWith('# Top\r\n'));
 for(const [pointer,samples]of [['/components/schemas/N',['9007199254740993','9007199254740994','9007199254740993.1']],['/components/schemas/S',['null','"text"','"other"']]]){
  const instances=samples.map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer}})),before=await evaluateSchemas({...input,runtimeInstances:instances}),after=await evaluateSchemas({root:result.outputRoot,snapshot:'after',resources:[{id:result.outputs[0].id,text,generation:0}],runtimeInstances:instances.map(instance=>({...instance,schema:{...instance.schema,resource:result.outputRoot}}))});
  assert.equal(after.complete,true);assert.deepEqual(before.runtimeEvaluations.map(e=>e.valid),after.runtimeEvaluations.map(e=>e.valid));
 }
});
test('migration rewrites recursive cross-file references and escaped pointers without rewriting literal payload refs',async()=>{
 const input=capture('openapi: 3.0.4\ninfo: {title: External, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Model: {$ref: "model.yaml#/a~1b"}\nx-data: {$ref: "model.yaml#/a~1b"}\n','yaml',[{id:'file:///approved/model.yaml',generation:2,text:'# Keep model\na/b: {type: object, properties: {next: {$ref: "#/a~1b"}}}\n'}]);
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.outputs.length,2);assert(result.outputs[0].text.includes('model.yaml#/a~1b'));assert(result.outputs[1].text.includes('# Keep model'));assert(result.outputs.some(output=>output.text.includes('resources/')));
});
test('ignored reference siblings require a bound explicit decision, never silent activation or source loss',async()=>{
 const input=capture('openapi: 3.0.4\ninfo: {title: Reference, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Value: {type: string}\n    Use: {$ref: "#/components/schemas/Value", type: integer}\n');
 const review=await planMigration(input);assert.equal(review.status,'requires-decision');assert.equal(review.complete,false);assert.deepEqual(review.outputs,[]);assert.equal(review.problems[0].pointer,'/components/schemas/Use');
 const accepted=await planMigration({...input,decisions:{[review.problems[0].id]:'discard-ignored-siblings'}});assert.equal(accepted.complete,true,JSON.stringify(accepted.problems));assert.equal(input.resources[0].text.includes('type: integer'),true);
 await assert.rejects(planMigration({...input,decisions:{unrelated:'discard-ignored-siblings'}}),e=>e.code==='migration.decisions.stale');
});
test('modern nullable annotation is never activated by a downgrade without a decision',async()=>{
 const input={...capture('openapi: 3.1.2\ninfo: {title: Annotation, version: "1"}\npaths: {}\ncomponents: {schemas: {Value: {type: string, nullable: true}}}\n'),targetVersion:'3.0.4'};
 const result=await planMigration(input);assert.equal(result.status,'requires-decision');assert(result.problems.some(p=>p.code==='migration.schema.annotation-activation'));
});
test('genuine target incompatibilities and incomplete converter mappings remain located blockers with no output',async()=>{
 for(const [text,targetVersion,code]of [
  ['swagger: "2.0"\ninfo: {title: Model, version: "1"}\npaths: {}\ndefinitions: {Base: {type: object, required: [kind], properties: {kind: {type: string}}, discriminator: kind}}\n','3.0.4','migration.discriminator.dispatch'],
  ['openapi: 3.2.1\ninfo: {title: Query, version: "1"}\npaths: {/x: {query: {responses: {204: {description: Empty}}}}}\n','3.1.2','migration.feature.newer'],
  ['openapi: 3.1.2\ninfo: {title: Resource, version: "1"}\npaths: {}\ncomponents: {schemas: {Value: {$id: value, $dynamicAnchor: tree, type: object, properties: {child: {$dynamicRef: "#tree"}}}}}\n','3.0.4','migration.schema.keyword'],
 ]){const input={...capture(text),targetVersion},result=await planMigration(input);assert.equal(result.status,'blocked');assert.equal(result.outputs.length,0);assert(result.problems.some(p=>p.code===code&&p.resource===input.root&&p.pointer&&p.range[1]>p.range[0]),JSON.stringify(result.problems));assert.equal(input.resources[0].text,text);}
});
test('Swagger body inheritance, media, primitive parameters, security and response examples migrate structurally',async()=>{
 const input=capture('swagger: "2.0"\ninfo: {title: Body, version: "1"}\nhost: api.invalid\nbasePath: /v1\nschemes: [https]\nconsumes: [application/json]\nproduces: [application/json]\nsecurityDefinitions:\n  Basic: {type: basic}\n  OAuth: {type: oauth2, flow: application, tokenUrl: https://api.invalid/token, scopes: {write: Write}}\nsecurity: [{Basic: []}]\nparameters:\n  Body:\n    name: payload\n    in: body\n    required: true\n    description: Body\n    schema: {$ref: "#/definitions/Pet"}\npaths:\n  /pets:\n    parameters: [{$ref: "#/parameters/Body"}]\n    post:\n      parameters: [{name: q, in: query, type: array, items: {type: string}, collectionFormat: multi}]\n      responses:\n        "200":\n          description: Created\n          schema: {$ref: "#/definitions/Pet"}\n          examples: {application/json: {id: 9007199254740993.00, $ref: literal}}\ndefinitions:\n  Pet: {type: object, properties: {id: {type: integer}}}\n');
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));const out=new SourceDocument(result.outputs[0].text,result.outputRoot);
 assert(out.dataNode('/paths/~1pets/post/requestBody'));assert(!out.dataNode('/paths/~1pets/parameters/0'));assert(out.dataNode('/components/requestBodies'));assert.equal(out.dataNode('/components/securitySchemes/Basic/type').value,'http');assert(out.dataNode('/components/securitySchemes/OAuth/flows/clientCredentials/tokenUrl'));
 assert(result.outputs[0].text.includes('9007199254740993.00'));assert(result.outputs[0].text.includes('$ref: literal'));
});
test('Swagger formData becomes a media-specific request schema and encoding, including file properties',async()=>{
 const input={...capture('swagger: "2.0"\ninfo: {title: Form, version: "1"}\nhost: api.invalid\nschemes: [https]\nconsumes: [multipart/form-data]\nproduces: [application/json]\npaths:\n  /upload:\n    post:\n      parameters:\n        - {name: file, in: formData, required: true, type: file}\n        - {name: tags, in: formData, type: array, items: {type: string}, collectionFormat: multi}\n      responses: {204: {description: Empty}}\n'),targetVersion:'3.0.4'};
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));const doc=new SourceDocument(result.outputs[0].text,result.outputRoot),base='/paths/~1upload/post/requestBody/content/multipart~1form-data';
 assert.equal(doc.dataNode(base+'/schema/properties/file/format').value,'binary');assert.equal(doc.dataNode(base+'/encoding/tags/explode').value,true);assert.deepEqual(doc.dataNode(base+'/schema/required').value,['file']);
});
test('a changed source graph cannot reuse a previous decision identity',async()=>{
 const input=capture('openapi: 3.0.4\ninfo: {title: Bound, version: "1"}\npaths: {}\ncomponents: {schemas: {A: {type: string}, B: {$ref: "#/components/schemas/A", type: integer}}}\n');
 const review=await planMigration(input),changed={...input,resources:input.resources.map(resource=>({...resource,text:resource.text.replace('type: integer','type: number')})),decisions:{[review.problems[0].id]:'discard-ignored-siblings'}};
 await assert.rejects(planMigration(changed),error=>error.code==='migration.decisions.stale');
});
for(const targetVersion of ['3.0.4','2.0'])test(`static resource identities, anchors, nested definitions and const intersections migrate faithfully to ${targetVersion}`,async()=>{
 const input={...capture('openapi: 3.2.1\ninfo: {title: Static resource, version: "1"}\npaths: {}\ncomponents: {schemas: {Model: {$ref: "models.json"}}}\n','yaml',[{id:'file:///approved/models.json',generation:2,text:'{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://schemas.invalid/tree","type":"object","properties":{"value":{"$ref":"#needle"}},"$defs":{"a/b":{"$anchor":"needle","type":"integer","enum":[9007199254740992,9007199254740993],"const":9007199254740993}}}'}]),targetVersion};
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.outputs.length,2);
 const pointer=targetVersion==='2.0'?'/definitions/Model':'/components/schemas/Model',samples=['{"value":9007199254740993}','{"value":9007199254740992}','{"value":9007199254740994}'];
 const before=await evaluateSchemas({...input,runtimeInstances:samples.map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer:'/components/schemas/Model'}}))});
 const resources=result.outputs.map(output=>({id:output.id,text:output.text,generation:0}));
 const after=await evaluateSchemas({root:result.outputRoot,snapshot:'target',resources,runtimeInstances:samples.map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:result.outputRoot,pointer}}))});
 assert.equal(before.complete,true,JSON.stringify(before.findings));assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.runtimeEvaluations.map(e=>e.valid),[true,false,false]);assert.deepEqual(after.runtimeEvaluations.map(e=>e.valid),before.runtimeEvaluations.map(e=>e.valid));
 assert.equal(analyse({root:result.outputRoot,snapshot:'cold',resources}).status,'complete');assert(result.outputs.some(output=>output.text.includes('9007199254740993')));
});
test('Swagger downgrade represents a closed positional tuple by exact maxItems and native tuple items',async()=>{
 const input={...capture('{"openapi":"3.2.1","info":{"title":"Tuple","version":"1"},"paths":{},"components":{"schemas":{"Tuple":{"type":"array","prefixItems":[{"type":"integer"},{"type":"string"}],"items":false,"maxItems":1e999}}}}','json'),targetVersion:'2.0'};
 const result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));
 const samples=['[]','[1]','[1,"x"]','[1,"x",3]','["x"]'];
 const before=await evaluateSchemas({...input,runtimeInstances:samples.map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer:'/components/schemas/Tuple'}}))});
 const after=await evaluateSchemas({root:result.outputRoot,snapshot:'target',resources:result.outputs.map(output=>({id:output.id,text:output.text,generation:0})),runtimeInstances:samples.map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:result.outputRoot,pointer:'/definitions/Tuple'}}))});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.runtimeEvaluations.map(e=>e.valid),[true,true,true,false,false]);assert.deepEqual(before.runtimeEvaluations.map(e=>e.valid),after.runtimeEvaluations.map(e=>e.valid));
});
