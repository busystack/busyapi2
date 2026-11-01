const assert = require('node:assert/strict');
const {test} = require('node:test');
const YAML = require('yaml');
const {analyse} = require('./dist/model.cjs');

for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`containing document owns feature family and default dialect ${version} ${json?'JSON':'YAML'}`,()=>{
 const {createGraph,inspect}=require('./dist/model.cjs'),family=version.slice(0,3),entry=family==='3.1'?'3.2.1':'3.1.2';
 const suffix=json?'json':'yaml',root='file:///approved/entry.'+suffix,part='file:///approved/part.'+suffix;
 const make=(id,value)=>({id,text:json?JSON.stringify(value):YAML.stringify(value),generation:1,identity:id});
 const operation={operationId:'ownedGet',responses:{'204':{description:'No content'}}};
 const shared={get:operation,...(family==='3.2'?{query:{...operation,operationId:'ownedQuery'},additionalOperations:{COPY:{...operation,operationId:'ownedCopy'}}}:{})};
 const resources=[make(root,{openapi:entry,info:{title:'Entry',version:'1'},paths:{'/owned':{$ref:'part.'+suffix+'#/components/pathItems/Shared'}}}),make(part,{openapi:version,info:{title:'Part',version:'1'},paths:{},components:{pathItems:{Shared:shared},schemas:{Model:{type:'integer'}}}})];
 const input={root,resources,snapshot:'own-version'},graph=createGraph(input).graph;
 assert.equal(graph.scope(root,'').family,entry.slice(0,3));
 assert.equal(graph.scope(part,'/components/schemas/Model').family,family);
 assert.equal(graph.scope(part,'/components/schemas/Model').dialect,`https://spec.openapis.org/oas/${family}/dialect/base`);
 assert.equal(graph.issues.length,0,JSON.stringify(graph.issues));
 const result=analyse(input);
 assert.equal(result.status,'complete',JSON.stringify(result.findings));
 assert.deepEqual(result.operations.map(op=>op.method),family==='3.2'?['get','query','COPY']:['get']);
 assert(result.operations.every(op=>op.resource===part&&op.shared));
 const page=inspect({...input,resource:part,pointer:'/components/pathItems/Shared'});
 assert.equal(page.family,family);
 assert.equal(page.fields.some(field=>field.name==='additionalOperations'),family==='3.2');
 // A containing document's explicit dialect takes precedence over both
 // families' defaults, without changing its authored OpenAPI version.
 const explicit=JSON.parse(JSON.stringify(resources));
 const value=json?JSON.parse(explicit[1].text):YAML.parse(explicit[1].text);
 value.jsonSchemaDialect='https://json-schema.org/draft/2020-12/schema';
 explicit[1].text=json?JSON.stringify(value):YAML.stringify(value);
 assert.equal(createGraph({...input,resources:explicit}).graph.scope(part,'/components/schemas/Model').dialect,value.jsonSchemaDialect);
 assert.equal(value.openapi,version);
});

test('unknown containing versions are incomplete, not interpreted as an approved family',()=>{
 const {createGraph}=require('./dist/model.cjs'),root='file:///approved/root.json',part='file:///approved/part.json';
 const resources=[{id:root,text:JSON.stringify({openapi:'3.2.1',info:{title:'Entry',version:'1'},paths:{},components:{schemas:{Use:{$ref:'part.json#/components/schemas/Model'}}}}),generation:1},{id:part,text:JSON.stringify({openapi:'3.3.0',info:{title:'Unsupported',version:'1'},paths:{},components:{schemas:{Model:{type:'integer'}}}}),generation:1}];
 const graph=createGraph({root,resources}).graph;
 assert(graph.issues.some(issue=>issue.resource===part&&issue.pointer==='/openapi'&&issue.code==='version.unsupported'&&issue.incomplete));
 assert.equal(graph.scope(part,'').family,'3.3');
 assert(!graph.scopes.has(part+'#/components/schemas/Model'));
 assert.throws(()=>require('./dist/model.cjs').inspect({root,resources,resource:part,pointer:'/components/schemas/Model'}),error=>error.code==='version.unsupported');
 assert.throws(()=>require('./dist/source_assistance.cjs').assistSource({root,resources,resource:part,caret:0}),error=>error.code==='version.unsupported');
 assert.equal(analyse({root,resources}).complete,false);
});

test('the entry family cannot activate 3.2 reference positions in a containing 3.1 document',()=>{
 const {createGraph}=require('./dist/model.cjs'),root='file:///approved/root.json',part='file:///approved/part.json';
 const document={openapi:'3.1.2',info:{title:'Part',version:'1'},paths:{'/p':{query:{responses:{'200':{$ref:'not-an-operation'}}},additionalOperations:{COPY:{responses:{'200':{$ref:'not-an-operation'}}}}}},components:{mediaTypes:{No:{$ref:'not-a-media-reference'}}}};
 const resources=[{id:root,text:JSON.stringify({openapi:'3.2.1',info:{title:'Entry',version:'1'},paths:{}}),generation:1},{id:part,text:JSON.stringify(document),generation:1}];
 const graph=createGraph({root,resources}).graph;
 assert.equal(graph.references.length,0);
 assert(![...graph.scopes.values()].some(scope=>scope.kind==='operation'||scope.kind==='media'));
 assert.equal(resources[1].text,JSON.stringify(document));
});

for(const version of ['3.1.2','3.2.1'])test(`a fragment's arbitrary jsonSchemaDialect key does not establish OpenAPI document metadata ${version}`,()=>{
 const {createGraph}=require('./dist/model.cjs'),root='file:///approved/root.json',part='file:///approved/part.json';
 const document={jsonSchemaDialect:'https://not-a-dialect.invalid/data',Model:{type:'integer'}};
 const resources=[{id:root,text:JSON.stringify({openapi:version,info:{title:'Entry',version:'1'},paths:{},components:{schemas:{Use:{$ref:'part.json#/Model'}}}}),generation:1},{id:part,text:JSON.stringify(document),generation:1}];
 const graph=createGraph({root,resources}).graph;
 assert.equal(graph.scope(part,'/Model').dialect,`https://spec.openapis.org/oas/${version.slice(0,3)}/dialect/base`);
 assert.equal(graph.issues.length,0);
 assert.equal(resources[1].text,JSON.stringify(document));
});

test('URI normalization keeps reserved boundaries distinct and exposes conflicting unreserved identities',()=>{
 const {createGraph}=require('./dist/model.cjs');
 const root='file:///approved/root.json';
 const document={openapi:'3.2.1',info:{title:'URI identities',version:'1'},paths:{},components:{schemas:{First:{$id:'https://schemas.invalid/%61',type:'string'},Second:{$id:'https://schemas.invalid/a',type:'integer'}}}};
 let graph=createGraph({root,resources:[{id:root,text:JSON.stringify(document),generation:1,identity:'duplicate'}]}).graph;
 assert(graph.issues.some(issue=>issue.code==='reference.identity.duplicate'));
 document.components.schemas.Second.$id='https://schemas.invalid/a%2Fb';document.components.schemas.First.$id='https://schemas.invalid/a/b';
 graph=createGraph({root,resources:[{id:root,text:JSON.stringify(document),generation:2,identity:'distinct'}]}).graph;
 assert.equal(graph.issues.length,0);assert(graph.identities.has('https://schemas.invalid/a%2Fb'));assert(graph.identities.has('https://schemas.invalid/a/b'));
});

test('structural schema feedback respects resource boundaries and does not reject rounded numeric projections',()=>{
 const root='file:///tmp/meta-boundaries.json';
 const value={openapi:'3.2.1',info:{title:'Meta',version:'1'},paths:{},components:{schemas:{Parent:{$id:'https://schemas.invalid/parent',type:'string',$defs:{Opaque:{$id:'opaque',$schema:'https://custom.invalid/dialect',type:'not-standard'}}},Bad:{minItems:-1},Large:{minimum:1,multipleOf:1}}}};
 const text=JSON.stringify(value).replace('"minimum":1','"minimum":1e1000').replace('"multipleOf":1','"multipleOf":1e-1000');
 const result=analyse({root,snapshot:'boundaries',resources:[{id:root,text,generation:1,identity:'source'}]});
 assert.equal(result.complete,false);
 assert(!result.findings.some(f=>f.code.startsWith('schema.')&&f.pointer.includes('/Opaque')));
 assert(!result.findings.some(f=>f.code.startsWith('schema.')&&f.pointer.includes('/Large')));
 assert(result.findings.some(f=>f.code.startsWith('schema.')&&f.pointer==='/components/schemas/Bad/minItems'));
});

for (const openapi of ['3.1.2', '3.2.1']) for (const format of ['yaml', 'json']) {
 const resource = (name, value) => ({id:`file:///tmp/${name}.${format}`, text:format==='json'?JSON.stringify(value):YAML.stringify(value), generation:3, identity:name});
 const run = (schemas, extras=[], rest={}) => {
  const root=resource('root', {openapi,info:{title:'Graph',version:'1'},paths:{},components:{schemas},...rest});
  return {root,result:analyse({root:root.id,snapshot:'graph',resources:[root,...extras]})};
 };
 const label=`${openapi} ${format}`;
 test(`dialect declarations are legal at OAS schema roots and identified resources, not arbitrary subschemas ${label}`,()=>{
  const {result}=run({Good:{$schema:'https://json-schema.org/draft/2020-12/schema',type:'object',properties:{nested:{$id:'nested',$schema:'https://json-schema.org/draft/2020-12/schema',type:'integer'}}},Bad:{type:'object',properties:{nested:{$schema:'https://json-schema.org/draft/2020-12/schema',type:'string'}}}});
  const issues=result.findings.filter(f=>f.code==='schema.dialect.location');
  assert.equal(issues.length,1,JSON.stringify(result.findings));
  assert.equal(issues[0].pointer,'/components/schemas/Bad/properties/nested/$schema');
  assert.equal(result.status,'invalid');
 });
 test(`empty schema-id fragments retain one canonical resource and working static/dynamic anchors ${label}`,()=>{
  const {root,result}=run({Tree:{$id:'https://contracts.example/tree#',$dynamicAnchor:'node',type:'object',$defs:{Leaf:{$anchor:'leaf',type:'string'}},properties:{value:{$ref:'#leaf'},child:{$dynamicRef:'#node'}}},Use:{$ref:'https://contracts.example/tree'}});
  assert.equal(result.complete,true,JSON.stringify(result.findings));
  assert.equal(result.status,'complete');
  const {createGraph}=require('./dist/model.cjs'),graph=createGraph({root:root.id,resources:[root]}).graph;
  assert.equal(graph.scopes.get(root.id+'#/components/schemas/Tree').base,'https://contracts.example/tree');
  assert(!graph.identities.has('https://contracts.example/tree#'));
  const anchor=result.references.find(r=>r.keyword==='$ref'&&r.value==='#leaf');
  assert.equal(anchor.targetPointer,'/components/schemas/Tree/$defs/Leaf');
  const dynamic=result.references.find(r=>r.keyword==='$dynamicRef');
  assert.equal(dynamic.resolution,'resolved');
  assert.equal(dynamic.dynamic.anchor,'node');
  assert.equal(dynamic.targetPointer,'/components/schemas/Tree');
  assert(root.text.includes('https://contracts.example/tree#'),'The canonical projection must not rewrite authored source');
 });
 test(`empty and absent schema-id fragments collide; a nonempty id fragment is invalid ${label}`,()=>{
  const {root,result:duplicate}=run({A:{$id:'https://contracts.example/same#'},B:{$id:'https://contracts.example/same'},Use:{$ref:'https://contracts.example/same'}});
  assert.equal(duplicate.complete,false);
  const graph=require('./dist/model.cjs').createGraph({root:root.id,resources:[root]}).graph;
  assert.equal(graph.references.find(r=>r.pointer==='/components/schemas/Use').resolution,'ambiguous');
  assert(duplicate.findings.some(f=>f.code==='reference.identity.duplicate'));
  const invalid=run({A:{$id:'https://contracts.example/resource#named'}}).result;
  assert(invalid.findings.some(f=>f.code==='reference.uri'&&f.pointer==='/components/schemas/A/$id'));
  assert.equal(invalid.status,'invalid');
 });
 test(`implicit security, Link and discriminator connections retain exact identity ${label}`,()=>{
  const source=resource('connections',{openapi,info:{title:'Connections',version:'1'},security:[{Key:[],Combined:[]},{}],components:{securitySchemes:{Key:{type:'apiKey',name:'x-key',in:'header'},Combined:{type:'http',scheme:'bearer'}},schemas:{Pet:{type:'object'},Choice:{oneOf:[{$ref:'#/components/schemas/Pet'}],discriminator:{propertyName:'kind',mapping:{pet:'Pet'}}}}},paths:{'/pets':{get:{operationId:'getPet',responses:{'200':{description:'Success',links:{again:{operationId:'getPet'}}}}}}},'x-payload':{security:[{Unknown:[]}],operationId:'getPet'}});
  const result=analyse({root:source.id,snapshot:'connections',resources:[source]});
  assert.equal(result.status,'complete',JSON.stringify(result.findings));
  const connections=result.references.filter(r=>r.connection);
  assert.equal(connections.length,4);
  assert.deepEqual(connections.filter(r=>r.connection==='security').map(r=>r.targetPointer),['/components/securitySchemes/Key','/components/securitySchemes/Combined']);
  assert.equal(connections.find(r=>r.connection==='operationId').targetPointer,'/paths/~1pets/get');
  assert.equal(connections.find(r=>r.connection==='discriminator').targetPointer,'/components/schemas/Pet');
  const key=connections.find(r=>r.connection==='security');
  assert(source.text.slice(...key.range).includes('Key'));
 });
 test(`ambiguous Link ids cannot choose a first operation ${label}`,()=>{
  const {result}=run({},[],{paths:{'/one':{get:{operationId:'same',responses:{'200':{description:'ok',links:{again:{operationId:'same'}}}}}},'/two':{post:{operationId:'same'}}}});
  const ref=result.references.find(r=>r.connection==='operationId');
  assert.equal(ref.resolution,'ambiguous');assert.equal(ref.candidateTargets.length,2);
  assert.equal(result.complete,false);assert(result.findings.some(f=>f.code==='reference.ambiguous'));
 });
 test(`security URI requirements are version-aware and public alternatives stay valid ${label}`,()=>{
  const part=resource('scheme',{Scheme:{type:'http',scheme:'basic'}});
  const name=`scheme.${format}#/Scheme`;
  const {result}=run({},[part],{security:[{[name]:[]},{}]});
  const ref=result.references.find(r=>r.connection==='security');
  assert.equal(ref.resolution,openapi.startsWith('3.2')?'resolved':'missing');
  if(openapi.startsWith('3.2')){assert.equal(result.status,'complete',JSON.stringify(result.findings));assert.equal(ref.targetResource,part.id);}
  else assert.equal(result.status,'invalid');
  const publicResult=run({},[],{security:[]}).result;
  assert.equal(publicResult.status,'complete');
 });
 test(`a schema anchor needs no explicit id or dialect ${label}`,()=>{
  const part=resource('anchor',{$anchor:'leaf',type:'string'});
  const {result}=run({Leaf:{$ref:`anchor.${format}#leaf`}},[part]);
  assert.equal(result.status,'complete',JSON.stringify(result.findings));
  assert.equal(result.references[0].targetResource,part.id);
  assert.equal(result.references[0].targetPointer,'');
 });
 test(`webhook and callback operations retain source and occurrence identity ${label}`,()=>{
  const callback=resource('callbacks',{Event:{'{$request.body#/callback}':{post:{operationId:'event',responses:{'204':{description:'No body'}}}},'x-metadata':{$ref:'never-fetch'}}});
  const {root,result}=run({},[callback],{
   paths:{'/subscribe':{post:{operationId:'subscribe',callbacks:{event:{$ref:`callbacks.${format}#/Event`}}}},'x-metadata':{$ref:'never-fetch'}},
   webhooks:{'x-event':{post:{operationId:'webhook'}}},
   components:{schemas:{},pathItems:{'x-shared':{get:{responses:{'200':{$ref:'#/components/responses/x-response'}}}}},responses:{'x-response':{description:'Shared'}}},
  });
  assert.equal(result.status,'complete',JSON.stringify(result.findings));
  assert.deepEqual(result.operations.map(op=>op.role),['operation','callback','webhook']);
  assert.equal(result.operations[1].resource,callback.id);
  assert.equal(result.operations[1].pointer,'/Event/{$request.body#~1callback}/post');
  assert.equal(result.operations[1].shared,true);
  assert(result.operations[1].occurrence.startsWith(root.id+'#/paths/'));
  assert(result.references.some(ref=>ref.value==='#/components/responses/x-response'));
  assert(!result.references.some(ref=>ref.value==='never-fetch'));
 });
 test(`nested resource identity, escaped pointers and anchors ${label}`,()=>{
  const {root,result}=run({Tree:{$id:'https://contracts.example/tree', $defs:{'a/b':{$anchor:'leaf',type:'string'},Nested:{$id:'nested',properties:{leaf:{$ref:'tree#leaf'}}}},properties:{p:{$ref:'#/$defs/a~1b'},n:{$ref:'nested'}}}});
  assert.equal(result.status,'complete',JSON.stringify(result.findings));
  assert.equal(result.references.length,3);
  assert(result.references.every(r=>r.targetResource===root.id));
  const leaf=result.references.find(r=>r.value==='tree#leaf');
  assert.equal(leaf.targetPointer,'/components/schemas/Tree/$defs/a~1b');
  assert.equal(leaf.base,'https://contracts.example/nested');
 });
 test(`dynamic scope remains contextual across recursive resources ${label}`,()=>{
  const {root,result}=run({Tree:{$id:'https://contracts.example/tree',$dynamicAnchor:'node',type:'object',properties:{children:{type:'array',items:{$dynamicRef:'#node'}}}},Strict:{$id:'https://contracts.example/strict',$dynamicAnchor:'node',$ref:'tree',unevaluatedProperties:false}});
  assert.equal(result.status,'complete',JSON.stringify(result.findings));
  const edge=result.references.find(r=>r.keyword==='$dynamicRef');
  assert.equal(edge.targetResource,root.id);
  assert.equal(edge.targetPointer,'/components/schemas/Tree');
  assert.equal(edge.dynamic.anchor,'node');
  assert.deepEqual(edge.dynamic.candidates.map(t=>t.pointer).sort(),['/components/schemas/Strict','/components/schemas/Tree']);
 });
 test(`duplicate resource identifiers cannot choose the first definition ${label}`,()=>{
  const {result}=run({A:{$id:'https://contracts.example/shared',type:'string'},B:{$id:'https://contracts.example/shared',type:'number'},Consumer:{$ref:'https://contracts.example/shared'}});
  assert.equal(result.complete,false);
  assert.equal(result.references[0].resolution,'ambiguous');
  assert.equal(result.references[0].targetResource,undefined);
  assert.equal(result.findings.filter(f=>f.code==='reference.identity.duplicate').length,2);
 });
 test(`duplicate anchors and invalid fragments have located findings ${label}`,()=>{
  const {result}=run({A:{$id:'https://contracts.example/a',$defs:{A:{$anchor:'same'},B:{$anchor:'same'}},allOf:[{$ref:'#same'},{$ref:'#/bad~2escape'},{$ref:'#%FF'}]}});
  assert.equal(result.complete,false);
  assert.equal(result.references[0].resolution,'ambiguous');
  assert.deepEqual(result.references.slice(1).map(r=>r.resolution),['invalid','invalid']);
  assert(result.findings.some(f=>f.pointer.endsWith('/allOf/0/$ref')));
 });
 test(`payload keys, schema annotations and extensions stay data ${label}`,()=>{
  const {result}=run({A:{type:'object',default:{$id:'https://bad.example/id',$ref:'never-fetch'},examples:[{$dynamicRef:'never-fetch'}],'x-payload':{properties:{X:{$ref:'never-fetch'}}},properties:{example:{type:'string'}}}},[],{'x-callback':{'{$request.body}':{$ref:'never-fetch'}}});
  assert.equal(result.status,'complete',JSON.stringify(result.findings));
  assert.equal(result.references.length,0);
 });
 test(`fragment schema keywords are checked at their physical source ${label}`,()=>{
  const part=resource('part',{Value:{type:12}});
  const {result}=run({X:{$ref:`part.${format}#/Value`}},[part]);
  assert.equal(result.status,'invalid');
  assert(result.findings.some(f=>f.code.startsWith('schema.')&&f.resource===part.id&&f.pointer.startsWith('/Value')));
 });
 test(`unsupported dialect preserves occurrences without invented targets ${label}`,()=>{
  const {result}=run({X:{$schema:'https://custom.example/dialect',$id:'https://custom.example/schema',$ref:'#/unknown',properties:{name:{type:'string'}}}});
  assert.equal(result.status,'incomplete');
  assert.equal(result.references[0].resolution,'unsupported');
  assert.equal(result.references[0].targetResource,undefined);
  assert(result.findings.some(f=>f.code==='dialect.unsupported'));
 });
 if(openapi.startsWith('3.2')) test(`self identities resolve across physical resources ${label}`,()=>{
  const part=resource('physical', {openapi,$self:'https://contracts.example/api/shared',info:{title:'Shared',version:'1'},components:{schemas:{Result:{$id:'../schemas/result',type:'boolean'}}}});
  const {root,result}=run({A:{$ref:'shared#/components/schemas/Result'},B:{$ref:'../schemas/result'}},[part],{$self:'https://contracts.example/api/root'});
  assert.equal(result.status,'complete',JSON.stringify(result.findings));
  assert(result.references.every(r=>r.targetResource===part.id));
  assert(result.references.every(r=>r.targetPointer==='/components/schemas/Result'));
  assert.equal(result.references[0].resource,root.id);
 });
}
