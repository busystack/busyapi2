const assert=require('node:assert/strict');
const {test}=require('node:test');
const {evaluateSchemas,standardResource}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const YAML=require('yaml');
const fs=require('node:fs');
const path=require('node:path');
const {createGraph}=require('./dist/model.cjs');
const root='file:///approved/root.json';
const snapshot=(value,extra=[])=>({root,snapshot:'evaluation-fixture',resources:[{id:root,text:typeof value==='string'?value:JSON.stringify(value),generation:1,identity:'root'},...extra]});
const api=(version,schema,examples)=>{
 const media={schema,examples:Object.fromEntries(examples.map((value,i)=>['case'+i,{value}]))};
 return {openapi:version,info:{title:'Evaluation',version:'1'},paths:{'/p':{get:{responses:{'200':{description:'Read',content:{'application/json':media}}}}}}};
};
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`referenced documents evaluate their own dialect and example representation ${version} ${json?'JSON':'YAML'}`,async()=>{
 const family=version.slice(0,3),entry=family==='3.1'?'3.2.1':'3.1.2',suffix=json?'json':'yaml';
 const id=root.replace('.json','.'+suffix),part='file:///approved/part.'+suffix;
 const field=family==='3.2'?'dataValue':'value';
 const value={openapi:version,info:{title:'Part',version:'1'},paths:{},components:{responses:{Result:{description:'Read',content:{'application/json':{schema:{type:'integer'},examples:{Good:{[field]:1},Bad:{[field]:'not an integer'}}}}}},schemas:{Model:{type:'integer',examples:[1,'not an integer']}}}};
 const source=api(entry,{$ref:'part.'+suffix+'#/components/schemas/Model'},[1,'wrong']);
 source.paths['/p'].get.responses['201']={$ref:'part.'+suffix+'#/components/responses/Result'};
 const render=value=>json?JSON.stringify(value):YAML.stringify(value);
 const input={root:id,snapshot:'owning-dialect',resources:[{id,text:render(source),generation:1},{id:part,text:render(value),generation:2}]};
 const context=createGraph(input);
 assert.equal(context.graph.scope(part,'/components/schemas/Model').dialect,`https://spec.openapis.org/oas/${family}/dialect/base`);
 const result=await evaluateSchemas(input,undefined,context);
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.equal(result.evaluations.length,6);
 assert.equal(result.evaluations.filter(e=>e.valid).length,3);
 assert(result.evaluations.some(e=>e.resource===part&&e.pointer.endsWith('/examples/Bad/'+field)&&!e.valid));
 assert(result.findings.some(f=>f.resource===part&&f.pointer.endsWith('/examples/Bad/'+field)));
 assert.deepEqual(input.resources.map(resource=>resource.text),[render(source),render(value)]);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`empty id fragments preserve exact recursive instance evaluation ${version} ${json?'JSON':'YAML'}`,async()=>{
 const document=api(version,{$ref:'https://schemas.invalid/tree#node'},[{value:42,child:{value:7}},{value:42,child:{value:'wrong'}},{value:42,unexpected:true}]);
 document.components={schemas:{Tree:{$id:'https://schemas.invalid/tree#',$dynamicAnchor:'node',type:'object',properties:{value:{type:'integer'},child:{$dynamicRef:'#node'}},required:['value'],unevaluatedProperties:false}}};
 const text=json?JSON.stringify(document):YAML.stringify(document),id=root.replace('.json',json?'.json':'.yaml'),input={root:id,snapshot:'empty-id',resources:[{id,text,generation:1}]},result=await evaluateSchemas(input);
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false,false]);
 assert.equal(input.resources[0].text,text);
 assert(result.findings.filter(f=>f.code==='example.schema.incompatible').every(f=>f.resource===id&&f.pointer.includes('/examples/case')));
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`an invalid nested dialect cannot produce an evaluated-valid example while independent roots remain usable ${version} ${json?'JSON':'YAML'}`,async()=>{
 const document=api(version,{type:'object',properties:{value:{$schema:'https://json-schema.org/draft/2020-12/schema',type:'integer'}}},[{value:1}]);
 document.components={schemas:{Good:{$schema:'https://json-schema.org/draft/2020-12/schema',type:'integer',examples:[1,'wrong']},Identified:{$id:'identified',$schema:'https://json-schema.org/draft/2020-12/schema',type:'string',examples:['good',2]}}};
 const id=root.replace('.json',json?'.json':'.yaml'),text=json?JSON.stringify(document):YAML.stringify(document);
 const result=await evaluateSchemas({root:id,snapshot:'dialect-positions',resources:[{id,text,generation:1}]});
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert(result.findings.some(f=>f.code==='schema.dialect.location'&&f.pointer.endsWith('/properties/value/$schema')));
 assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false,true,false]);
 assert(result.skipped.some(e=>e.reason==='associated-schema-invalid-or-incomplete'));
 assert(!result.evaluations.some(e=>e.pointer.includes('/paths/')));
});
for(const version of ['3.1.2','3.2.1'])test(`YAML alias semantic scopes evaluate from actual CST provenance ${version}`,async()=>{
 const id='file:///approved/alias.yaml',text=`openapi: ${version}\ninfo: {title: Aliases, version: "1"}\nx-definition: &parameter\n  name: id\n  in: path\n  required: true\n  schema: {type: integer, minimum: 9007199254740993}\n  examples:\n    valid: {value: 9007199254740993}\n    invalid: {value: 9007199254740992}\npaths:\n  /p/{id}:\n    get: {parameters: [*parameter], responses: {204: {description: None}}}\n`;
 const input={root:id,snapshot:'alias',resources:[{id,text,generation:1,identity:'alias'}]};
 const graph=createGraph(input).graph;
 assert.equal(graph.scope(id,'/paths/~1p~1{id}/get/parameters/0/schema').kind,'schema');
 assert.equal(graph.docs.get(id).nodes.has('/paths/~1p~1{id}/get/parameters/0/schema'),false);
 assert.equal(graph.docs.get(id).dataNode('/paths/~1p~1{id}/get/parameters/0/schema/minimum').pointer,'/x-definition/schema/minimum');
 const result=await evaluateSchemas(input);
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);
 assert.equal(result.findings.find(f=>f.code==='example.schema.incompatible').range[0],text.indexOf('9007199254740992'));
 assert.equal(result.evaluations[1].pointer,'/x-definition/examples/invalid/value');
 assert.equal(input.resources[0].text,text);
});
test('URI / IRI representation preserves exact source and scope in non-ASCII space-containing resources',async()=>{
 for(const version of ['3.1.2','3.2.1'])for(const json of [true,false]) {
  const id='file:///approved/space%20%E9%9B%AA/root.'+(json?'json':'yaml');
  const model='file:///approved/space%20%E9%9B%AA/model.json';
  const value=api(version,{$ref:'model.json#/$defs/Value'},[9007199254740992,9007199254740991]);
  const source=(json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0})).replaceAll('9007199254740992','9007199254740993').replaceAll('9007199254740991','9007199254740992');
  const text='{"$id":"https://schemas.invalid/%76alue雪","$defs":{"Value":{"type":"integer","minimum":9007199254740993}}}';
  const result=await evaluateSchemas({root:id,snapshot:'uri-representation',resources:[{id,text:source,generation:1,identity:'root'},{id:model,text,generation:1,identity:'model'}]});
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);
 }
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`physical pointers crossing nested ids evaluate the canonical schema, not a resource placeholder ${version} ${json?'JSON':'YAML'}`,async()=>{
 const id='file:///approved/physical.'+(json?'json':'yaml'),part='file:///approved/forward.json',name='n/~#?';
 const pointer='/components/schemas/Model/$defs/'+name.replaceAll('~','~0').replaceAll('/','~1');
 const fragment='#'+encodeURI(pointer).replaceAll('#','%23').replaceAll('?','%3F');
 const value=api(version,{$ref:'forward.json#/Forward'},[9007199254740992,9007199254740991,'not integer']);
 value.components={schemas:{Model:{$id:'nested/model',$defs:{[name]:{type:'integer',minimum:9007199254740992},'n/~%23%3F':{type:'string',minLength:3}}}}};
 const text=(json?JSON.stringify(value,null,2):YAML.stringify(value)).replaceAll('9007199254740992','9007199254740993').replaceAll('9007199254740991','9007199254740992');
 const external=JSON.stringify({Forward:{$ref:'physical.'+(json?'json':'yaml')+fragment}}),input={root:id,snapshot:'physical-id',resources:[{id,text,generation:1},{id:part,text:external,generation:2}]};
 const errors=[],result=await evaluateSchemas(input,error=>errors.push(String(error)));
 assert.equal(result.complete,true,JSON.stringify({findings:result.findings,errors}));
 assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false,false]);
 const literalPointer='/components/schemas/Model/$defs/n~1~0%23%3F';
 const literalFragment='#'+encodeURI(literalPointer).replaceAll('#','%23').replaceAll('?','%3F');
 const literalSource=JSON.stringify({Forward:{$ref:'physical.'+(json?'json':'yaml')+literalFragment}});
 const literal=await evaluateSchemas({...input,resources:[input.resources[0],{...input.resources[1],text:literalSource}]});
 assert.equal(literal.complete,true,JSON.stringify(literal.findings));assert.deepEqual(literal.evaluations.map(e=>e.valid),[false,false,true]);
 assert.equal(input.resources[0].text,text);assert.equal(input.resources[1].text,external);
 assert(result.findings.filter(f=>f.code==='example.schema.incompatible').every(f=>f.resource===id));
});
test('bundled resource service exposes only selected shipped standards and refuses forged contents',async()=>{
 const catalogue=await standardResource({list:true});
 assert(catalogue.identities.includes('https://json-schema.org/draft/2020-12/schema'));
 assert(!catalogue.identities.some(uri=>uri.includes('draft-07')));
 assert(catalogue.identities.includes('https://spec.openapis.org/oas/3.0/dialect'));
 assert.deepEqual(await standardResource({uri:'https://unapproved.invalid/schema'}),{version:1,found:false});
 const supplied=await standardResource({uri:'https://json-schema.org/draft/2020-12/schema'});
 const input=snapshot(api('3.2.1',{$ref:supplied.source.id},[{minLength:1},{minLength:-1}]),[supplied.source]);
 const evaluated=await evaluateSchemas(input);assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));
 assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,false]);
 await assert.rejects(evaluateSchemas(snapshot(api('3.2.1',{type:'string'},['a']),[{...supplied.source,text:'false'}])),e=>e.code==='schema.identity.conflict');
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true]) {
 test(`canonical schema evaluation ${version} ${json} has exact numbers, recursive dynamic scope and original example locations`,async()=>{
  const modelId='file:///approved/models.'+(json?'json':'yaml'),rootId=root.replace('.json',json?'.json':'.yaml');
  const model={$schema:'https://json-schema.org/draft/2020-12/schema',$defs:{Base:{$id:'https://schemas.invalid/base',$dynamicAnchor:'node',type:'object',properties:{value:{type:'integer',minimum:9007199254740992},marker:{const:{$ref:'literal payload'}},child:{$dynamicRef:'#node'}},required:['value']},Strict:{$id:'https://schemas.invalid/strict',$dynamicAnchor:'node',$ref:'https://schemas.invalid/base',unevaluatedProperties:false}}};
  const accepted={value:9007199254740992,marker:{$ref:'literal payload'},child:{value:9007199254740992}};
  const value=api(version,{$ref:'https://approved.invalid/models#/$defs/Strict'},[accepted,{...accepted,value:9007199254740991},{...accepted,child:{value:9007199254740992,unexpected:true}}]);
  const render=value=>json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0});
  const exact=text=>text.replaceAll('9007199254740992','9007199254740993').replaceAll('9007199254740991','9007199254740992');
  const text=exact(render(value)),models=exact(render(model));
  const input={root:rootId,snapshot:'recursive',resources:[{id:rootId,text,generation:1,identity:'root'},{id:modelId,text:models,generation:2,identity:'models',aliases:['https://approved.invalid/models']}]};
  const errors=[];
  const result=await evaluateSchemas(input,error=>{let at=error;const chain=[];while(at){chain.push(String(at));at=at.cause;}errors.push(chain);});
  assert.equal(result.complete,true,JSON.stringify({findings:result.findings,errors}));
  assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false,false]);
  const findings=result.findings.filter(f=>f.code==='example.schema.incompatible');
  assert(findings.some(f=>f.pointer.endsWith('/examples/case1/value/value')));
  assert(findings.some(f=>f.pointer.includes('/examples/case2/value/child')));
  for(const finding of findings){assert.equal(finding.resource,rootId);assert.equal(finding.snapshot,'recursive');assert(finding.range[1]>=finding.range[0]);assert(finding.configuration);}
  assert.equal(input.resources[0].text,text);assert.equal(input.resources[1].text,models);
  assert(!JSON.stringify(result.findings).includes('literal payload'));
 });
}
test('schema meta evaluation distinguishes invalid keyword values from invalid supplied examples',async()=>{
 const value=api('3.2.1',{type:'object',properties:{count:{minItems:1.00001}}},[{}]);
 value.components={schemas:{Bad:{type:'invented'},Valid:{type:'string',format:'email',examples:['not an email']}}};
 const result=await evaluateSchemas(snapshot(value));
 assert.equal(result.complete,true);assert(result.findings.some(f=>f.code==='schema.keyword.invalid'&&f.pointer==='/components/schemas/Bad/type'));
 assert(result.findings.some(f=>f.code==='schema.keyword.invalid'&&f.pointer.includes('/properties/count/minItems')));
 assert.equal(result.evaluations.find(e=>e.interpretation==='schema-annotation').valid,true,'format is deliberately annotation-only');
 assert(result.skipped.some(e=>e.reason==='associated-schema-invalid-or-incomplete'));
});
test('large decimal equality and number syntax stay exact in schema and instance projections',async()=>{
 const text=JSON.stringify(api('3.2.1',{type:'number',multipleOf:0.1},[0.3,0.31])).replace('0.31','0.30000000000000000001');
 const result=await evaluateSchemas(snapshot(text));assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);assert.equal(result.complete,true);
 const schema={oneOf:[{const:9007199254740992},{const:9007199254740991}]};
 const distinct=JSON.stringify(api('3.2.1',schema,[9007199254740991,9007199254740992])).replaceAll('9007199254740992','9007199254740993').replaceAll('9007199254740991','9007199254740992');
 assert.deepEqual((await evaluateSchemas(snapshot(distinct))).evaluations.map(e=>e.valid),[true,true]);
 const yaml=new SourceDocument('n: 9007199254740993.\nf: +000000.0000000000000000001\nz: -.0\n','file:///data.yaml');
 assert.equal(yaml.dataJson('/n'),'9007199254740993.0');assert.equal(yaml.dataJson('/f'),'0.0000000000000000001');assert.equal(yaml.dataJson('/z'),'-0.0');
 assert.equal(yaml.text,'n: 9007199254740993.\nf: +000000.0000000000000000001\nz: -.0\n');
 const rebound=new SourceDocument('first: &n 9007199254740993\nbefore: *n\nsecond: &n 9007199254740995\nafter: *n\n','file:///rebound.yaml');
 assert.equal(rebound.dataJson('/before'),'9007199254740993');assert.equal(rebound.dataJson('/after'),'9007199254740995');
 assert.throws(()=>new SourceDocument('root: &node {self: *node}\n','file:///cycle.yaml'),e=>e.code==='yaml.value');
 assert.throws(()=>new SourceDocument('number: .inf\n','file:///non-json.yaml'),e=>e.code==='yaml.value');
 assert.equal(new SourceDocument('huge: 1e1000\n','file:///huge.yaml').dataJson(''),'{"huge":1e1000}');
});
test('finite mathematical decimals beyond machine range evaluate identically in YAML and JSON',async()=>{
 for(const version of ['3.1.2','3.2.1'])for(const json of [true,false]) {
  const value=api(version,{type:'number',minimum:111},[111,110]);
  const text=(json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0})).replaceAll('111','1e1000').replaceAll('110','9e999');
  const id='file:///approved/huge.'+(json?'json':'yaml');
  const result=await evaluateSchemas({root:id,snapshot:'huge',resources:[{id,text,generation:1,identity:'huge'}]});
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);
 }
});
test('unknown required vocabularies and unapproved resources fail closed without fetching payload data',async()=>{
 const resource={$id:'https://schemas.invalid/custom-meta',type:'object',$vocabulary:{'https://unapproved.invalid/vocabulary':true}};
 const ordinary=await evaluateSchemas(snapshot(api('3.2.1',resource,[{}])));
 assert.equal(ordinary.complete,true,'$vocabulary must not be activated for an ordinary schema instance');assert.equal(ordinary.evaluations[0].valid,true);
 const custom=api('3.2.1',{$schema:resource.$id,type:'object'},[{}]);custom.components={schemas:{CustomMeta:resource,Independent:{type:'string',examples:['accepted',42]}}};
 const result=await evaluateSchemas(snapshot(custom));
 assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='schema.dialect.incomplete'));
 assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false],'An unavailable required dialect cannot suppress independent supported scopes');
 const missing=await evaluateSchemas(snapshot(api('3.2.1',{$ref:'https://unapproved.invalid/schema'},[{}])));
 assert.equal(missing.complete,false);assert(missing.findings.some(f=>f.code==='reference.unavailable'&&f.pointer.endsWith('/schema/$ref')));
 const literal=await evaluateSchemas(snapshot(api('3.2.1',{const:{$ref:'https://must-not-fetch.invalid/payload'}},[{$ref:'https://must-not-fetch.invalid/payload'}])));
 assert.equal(literal.complete,true);assert.equal(literal.evaluations[0].valid,true);
 const conflict=api('3.2.1',{$id:'https://json-schema.org/draft/2020-12/schema',type:'string'},['a']);
 await assert.rejects(evaluateSchemas(snapshot(conflict)),e=>e.code==='schema.identity.conflict');
});
test('reused evaluator does not retain a previous source at the same URI',async()=>{
 for(let generation=1;generation<=20;generation++) {
  const input=snapshot(api('3.2.1',{const:generation},[generation,generation-1]));input.resources[0].generation=generation;input.snapshot='generation-'+generation;
  const result=await evaluateSchemas(input);assert.equal(result.complete,true);assert.equal(result.snapshot,input.snapshot);assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);
 }
});
test('a literal const or enum value retains its data identity when explicitly referenced as a schema too',async()=>{
 for(const keyword of ['const','enum']) {
  const literal={$id:'https://schemas.invalid/dual-role',type:'string',$anchor:'literal',description:'Literal annotations remain present'};
  const value=api('3.2.1',{$ref:'#/components/schemas/Data'},[literal,{type:'string'}]);
  value.components={schemas:{Data:{[keyword]:keyword==='const'?literal:[literal]},Consumer:{$ref:'#/components/schemas/Data/'+keyword+(keyword==='enum'?'/0':'')}}};
  const result=await evaluateSchemas(snapshot(value));
  assert.equal(result.complete,true,JSON.stringify(result.findings));
  assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);
 }
});
test('known invalid local references do not become unavailable execution or suppress independent examples',async()=>{
 const value=api('3.2.1',{$ref:'#/components/schemas/Bad'},[{}]);
 value.components={schemas:{Bad:{$ref:'#/components/schemas/Absent'},Good:{type:'string',examples:['valid',42]}}};
 let result=await evaluateSchemas(snapshot(value));
 assert.equal(result.complete,true,JSON.stringify(result.findings));
 assert(!result.findings.some(f=>f.code==='schema.execution.incomplete'));
 assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);
 assert(result.skipped.some(e=>e.pointer.endsWith('/case0/value')));
 value.components.schemas.Bad.$ref='https://unapproved.invalid/absent';
 result=await evaluateSchemas(snapshot(value));
 assert.equal(result.complete,false);assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);
});
test('compound resources receive separate meta boundaries, including an unfamiliar nested dialect',async()=>{
 const schema={$id:'https://schemas.invalid/parent',type:'string',$defs:{Opaque:{$id:'opaque',$schema:'https://unapproved.invalid/custom',type:'not-a-standard-type',minItems:'unknown-semantics'},Independent:{$id:'independent',$schema:'https://json-schema.org/draft/2020-12/schema',type:'integer',examples:[1,'bad']}}};
 const result=await evaluateSchemas(snapshot(api('3.2.1',schema,['good',false])));
 assert.equal(result.complete,false);
 assert(result.findings.some(f=>f.code==='schema.dialect.incomplete'&&f.pointer.endsWith('/$defs/Opaque')));
 assert(!result.findings.some(f=>f.code==='schema.keyword.invalid'&&f.pointer.includes('/$defs/Opaque')),'The parent meta-schema must not invent keyword semantics for a different embedded dialect');
 assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false,true,false]);
 schema.allOf=[{$ref:'opaque'}];
 const dependent=await evaluateSchemas(snapshot(api('3.2.1',schema,['good',false])));
 assert.equal(dependent.complete,false);
 assert.deepEqual(dependent.evaluations.map(e=>e.valid),[true,false],'An applicable unknown schema must block its consumers, never validate them through the compile-only placeholder');
 assert(dependent.skipped.some(e=>e.pointer.includes('/examples/case0/')));
});
test('explicit supported schema-root dialects need no invented id and survive an unfamiliar document default',async()=>{
 for(const version of ['3.1.2','3.2.1'])for(const jsonSchemaDialect of [undefined,'https://unapproved.invalid/default']) {
  const value=api(version,{$schema:'https://json-schema.org/draft/2020-12/schema',type:'integer'},[1,false]);
  if(jsonSchemaDialect)value.jsonSchemaDialect=jsonSchemaDialect;
  const result=await evaluateSchemas(snapshot(value));
  assert.equal(result.complete,true,JSON.stringify(result.findings));
  assert.deepEqual(result.evaluations.map(e=>e.valid),[true,false]);
  assert(!Object.hasOwn(value.paths['/p'].get.responses['200'].content['application/json'].schema,'$id'));
 }
});
for(const version of ['3.1.2','3.2.1'])test(`production evaluator preserves all selected upstream 2020-12 expectations through ${version} snapshots`,async()=>{
 const directory=path.join(__dirname,'../../fixtures/json_schema_2020_12');
 const remotes=new Map(['tree.json','extendible-dynamic-ref.json','detached-dynamicref.json'].map(name=>{
  const uri='http://localhost:1234/draft2020-12/'+name;
  return [uri,{id:'file:///approved/remotes/'+name,text:fs.readFileSync(path.join(directory,'remotes',name),'utf8'),generation:1,identity:'oracle',aliases:[uri]}];
 }));
 let checked=0;
 for(const name of ['boolean_schema','if-then-else','ref','dynamicRef','unevaluatedProperties']) {
  const text=fs.readFileSync(path.join(directory,name+'.json'),'utf8'),oracle=new SourceDocument(text,'file:///oracles/'+name+'.json');
  const groups=JSON.parse(text);
  for(const [index,group]of groups.entries()) {
   const schemaId=`file:///approved/oracles/${name}-${index}.json`;
   const value=api(version,{$ref:schemaId},[]);
   const cases=group.tests.map((item,i)=>JSON.stringify('case'+i)+':{"value":'+oracle.dataJson('/'+index+'/tests/'+i+'/data')+'}').join(',');
   const rootText=JSON.stringify(value).replace('"examples":{}','"examples":{'+cases+'}');
   const input=snapshot(rootText,[{id:schemaId,text:oracle.dataJson('/'+index+'/schema'),generation:1,identity:'oracle'}]);
   // Reuse the real graph to establish exactly the supplied dependency set;
   // unused registered remote fixtures must not introduce duplicate identities.
   for(let pass=0;pass<5;pass++) {
    const {graph}=createGraph(input);let added=false;
    for(const ref of graph.references)if(ref.resolution==='unavailable'&&remotes.has(ref.targetUri)) {
     const resource=remotes.get(ref.targetUri);
     if(!input.resources.some(r=>r.id===resource.id)){input.resources.push(resource);added=true;}
    }
    if(!added)break;
   }
   const failures=[];
   const result=await evaluateSchemas(input,error=>failures.push(String(error)));
   assert.equal(result.complete,true,JSON.stringify({version,name,case:group.description,findings:result.findings,failures}));
   const actual=result.evaluations.filter(e=>e.resource===root&&/\/examples\/case\d+\/value$/.test(e.pointer));
   assert.equal(actual.length,group.tests.length,group.description);
   for(const [i,item]of group.tests.entries()) {
    const evaluated=actual.find(e=>e.pointer.endsWith('/examples/case'+i+'/value'));
    assert.equal(evaluated.valid,item.valid,`${version} ${name}: ${group.description} — ${item.description}`);checked++;
   }
  }
 }
 assert.equal(checked,300);
});

test('F03 JSON media syntax is checked canonically without adding schema constraints',async()=>{
 const input=snapshot({openapi:'3.2.1',info:{title:'JSON syntax',version:'1'},paths:{'/p':{post:{requestBody:{content:{'application/json':{}}},responses:{200:{description:'ok',content:{'application/json':{}}}}}}}});
 for(const text of ['{"n":9007199254740993,"d":1.0000000000000000001}','42','"scalar"','null','not json','{} trailing','', '[1,]']){
  const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'response-body',location:'application/json',text}]});
  const valid=!['not json','{} trailing','','[1,]'].includes(text);
  assert.equal(result.complete,true,text);assert.equal(result.runtimeEvaluations[0].valid,valid,text);
  assert.equal(result.runtimeFindings.some(f=>f.code==='runtime.body.syntax'),!valid,text);
 }
 const result=await evaluateSchemas({...input,runtimeInstances:[{subject:'request-body',location:'application/json',text:'['.repeat(600)+'0'+']'.repeat(600)}]});
 assert.equal(result.complete,false);assert.equal(result.runtimeEvaluations[0].reason,'instance-limit');
});
