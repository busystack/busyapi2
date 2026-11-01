const {test}=require('node:test');
const assert=require('node:assert/strict');
const {analyse}=require('./dist/model.cjs');
const {requestOperation,requestParameterValues,planResponseExample,semanticDiffCoverage,executionCaseValues,planExecutionEnvironment}=require('./dist/execution.cjs');
const {deriveBundle}=require('./dist/derived_bundle.cjs');
const {requestFormDataValues}=require('./dist/execution.cjs');
const {requestFormMediaTypes}=require('./dist/execution.cjs');

test('structured form data preserves scalar kinds, exact JSON and literal reference-looking payloads',()=>{
 const text=' {"number":900719925474099312345678901234567890,"string":"\\u0030","false":false,"null":null,"empty":"","array":[],"nested":[{"$ref":"literal","n":1e-999}],"__proto__":"ordinary"} ';
 const result=requestFormDataValues({text}),fields=Object.fromEntries(result.fields.map(field=>[field.name,field]));
 assert.equal(fields.number.kind,'number');assert.equal(fields.number.value,'900719925474099312345678901234567890');
 assert.equal(fields.string.kind,'string');assert.equal(fields.string.raw,'"\\u0030"');assert.equal(fields.string.value,'0');
 assert.equal(fields.false.value,false);assert.equal(fields.null.value,null);assert.equal(fields.empty.value,'');
 assert.deepEqual(fields.array.items,[]);assert.equal(fields.nested.items[0].raw,'{"$ref":"literal","n":1e-999}');
 assert.equal(fields.nested.value[0].$ref,'literal');assert.equal(fields.nested.value[0].n,'1e-999');assert.equal(fields.__proto__.value,'ordinary');
 assert.equal(result.raw,text.trim());assert.equal(result.input,require('node:crypto').createHash('sha256').update(text).digest('hex'));
});
for(const text of ['null','false','[]','{"duplicate":1,"duplicate":2}','{"n":NaN}'])test(`invalid structured form input cannot produce successful fields: ${text}`,()=>{
 assert.throws(()=>requestFormDataValues({text}),error=>['request.form.shape','json.duplicate','json.syntax','syntax.json'].includes(error.code)||error.code.includes('duplicate'));
});
test('structured form fields retain the production transport bound',()=>{
 assert.throws(()=>requestFormDataValues({text:JSON.stringify({values:Array(2049).fill(0)})}),error=>error.code==='limit.request.fields');
});

for(const version of ['3.0.0','3.0.4','3.1.2','3.2.1'])test(`form transport metadata retains ${version} schema owners and multipart rules`,()=>{
 const value={openapi:version,info:{title:'Native form',version:'1'},paths:{'/form':{post:{requestBody:{content:{'multipart/form-data':{schema:{$ref:'#/components/schemas/Form'},encoding:{metadata:{style:'form',explode:false,contentType:'application/json'}}}}},responses:{204:{description:'OK'}}}}},components:{schemas:{Form:{allOf:[{type:'object',properties:{metadata:{$ref:'model.json#/Metadata'},ids:{type:'array',items:{type:'integer'}}}}]}}}};
 const text=JSON.stringify(value),packet={root:id,snapshot:version,resources:[{id,text,generation:1},{id:'file:///execution/model.json',text:'{"Metadata":{"type":"object","properties":{"id":{"type":"integer"}}}}',generation:2}]};
 const op=analyse(packet).operations[0],plan=requestOperation({...packet,resource:id,pointer:op.pointer,occurrence:op.occurrence});
 const media=plan.requestBody.content[0];assert.equal(media.family,version.slice(0,3));
 assert.equal(media.form.multipartStyle,!version.startsWith('3.0.'));
 assert.equal(media.form.legacyBinary,version.startsWith('3.0.'));
 assert.equal(media.form.defaultContentType,version.startsWith('3.0.')?'text/plain':'application/octet-stream');
 assert.equal(media.form.shape.defaultContentType,'application/json');
 assert.deepEqual(media.form.shape.types,['object']);
 assert.deepEqual(media.form.shape.properties.metadata.types,['object']);
 assert.deepEqual(media.form.shape.properties.metadata.properties.id.types,['integer']);
 assert.deepEqual(media.form.shape.properties.ids.items.types,['integer']);
 assert.deepEqual({...media.encoding.metadata},{style:'form',explode:false,contentType:'application/json'});
 assert.equal(packet.resources[0].text,text);
});

const id='file:///execution/openapi.json';
for(const version of ['3.0.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} execution follows canonical Security Scheme references`,()=>{
 const serialize=value=>format==='json'?JSON.stringify(value):require('yaml').stringify(value);
 const root=`file:///execution/security-api.${format}`,fragment=`file:///execution/security-fragment.${format}`;
 const declarations={
  Key:{type:'apiKey',in:'header',name:'X-Key'},
  Basic:{type:'http',scheme:'basic'},
  Bearer:{type:'http',scheme:'bearer',bearerFormat:'JWT'},
  OAuth:{type:'oauth2',flows:{clientCredentials:{tokenUrl:'https://identity.example.invalid/token',scopes:{read:'Read'}}}},
  OpenID:{type:'openIdConnect',openIdConnectUrl:'https://identity.example.invalid/.well-known/openid-configuration'},
  ...(!version.startsWith('3.0.')?{Client:{type:'mutualTLS'}}:{})
 };
 const schemes=Object.fromEntries(Object.keys(declarations).map(name=>[name,{$ref:`security-fragment.${format}#/${name}Alias`}]));
 const security=Object.keys(declarations).map(name=>({[name]:['OAuth','OpenID'].includes(name)?['read']:[]}));
 const value={openapi:version,info:{title:'Referenced security 雪',version:'1'},security,components:{securitySchemes:schemes},paths:{'/items':{get:{responses:{204:{description:'Empty'}}}}}};
 const fragments=Object.fromEntries(Object.entries(declarations).flatMap(([name,value])=>[[name+'Alias',{$ref:'#/'+name+'~1~0provider'}],[name+'/~provider',{...value,'x-payload':{$ref:'literal.json'}}]]));
 const resources=[{id:root,text:serialize(value),generation:1},{id:fragment,text:serialize(fragments),generation:2}];
 const packet={root,snapshot:'security-reference',resources};
 const checked=analyse(packet);assert.equal(checked.complete,true);assert.deepEqual(checked.findings,[]);
 const operation=checked.operations[0],plan=requestOperation({...packet,resource:root,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.deepEqual(plan.security.requirements.map(requirement=>requirement.scopes),security);
 for(const [name,declaration]of Object.entries(declarations)){
  const projected=plan.security.schemes[name];assert.equal(projected.type,declaration.type);
  assert.equal(projected.source.resource,root);assert.equal(projected.source.pointer,'/components/securitySchemes/'+name);
  assert.equal(projected.definition.resource,fragment);assert.equal(projected.definition.pointer,'/'+name+'~1~0provider');
  assert.ok(projected.definition.range[1]>projected.definition.range[0]);
  if(declaration.type==='apiKey'){assert.equal(projected.in,'header');assert.equal(projected.parameterName,'X-Key');}
  if(declaration.type==='http')assert.equal(projected.scheme,declaration.scheme);
  if(declaration.type==='oauth2')assert.equal(projected.flows.clientCredentials.tokenUrl,declaration.flows.clientCredentials.tokenUrl);
  if(declaration.type==='openIdConnect')assert.equal(projected.openIdConnectUrl,declaration.openIdConnectUrl);
  if(declaration.type==='mutualTLS')assert.equal(projected.mutualTLS,true);
 }
 assert.deepEqual(resources.map(resource=>resource.text),[serialize(value),serialize(fragments)]);
});
for(const cycle of [false,true])test(`unavailable Security Scheme reference cannot become executable cycle=${cycle}`,()=>{
 const value={openapi:'3.0.4',info:{title:'Unavailable security',version:'1'},security:[{Access:[]}],components:{securitySchemes:{Access:{$ref:'#/components/securitySchemes/'+(cycle?'Access':'Missing')}}},paths:{'/items':{get:{responses:{204:{description:'Empty'}}}}}};
 const packet={root:id,snapshot:'unavailable-security',resources:[{id,text:JSON.stringify(value),generation:1}]};
 assert.throws(()=>requestOperation({...packet,resource:id,pointer:'/paths/~1items/get'}),error=>error.code===(cycle?'request.reference.cycle':'request.reference'));
});
for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} valid security names retain ordinary own-property identity`,()=>{
 const serialize=value=>format==='json'?JSON.stringify(value):require('yaml').stringify(value);
 const root='file:///execution/security-names.'+format;
 const names=['__proto__','constructor','toString'];
 const definitions=Object.fromEntries(names.map((name,index)=>[name,{type:'apiKey',in:'header',name:'X-Key-'+index}]));
 const value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Names',version:'1'},security:[Object.fromEntries(names.map(name=>[name,[]]))],paths:{'/items':{get:{responses:{204:{description:'Empty'}}}}},...(version==='2.0'?{securityDefinitions:definitions}:{components:{securitySchemes:definitions}})};
 const text=serialize(value),packet={root,snapshot:'ordinary-security-names',resources:[{id:root,text,generation:1}]};
 const checked=analyse(packet);assert.equal(checked.complete,true);assert.deepEqual(checked.findings,[]);
 const plan=requestOperation({...packet,resource:root,pointer:'/paths/~1items/get'});
 assert.deepEqual(Object.keys(plan.security.schemes),names);
 for(const [index,name]of names.entries()){
  assert.ok(Object.hasOwn(plan.security.schemes,name));
  assert.equal(plan.security.schemes[name].parameterName,'X-Key-'+index);
  assert.equal(JSON.parse(JSON.stringify(plan.security)).schemes[name].parameterName,'X-Key-'+index);
 }
 assert.equal(Object.getPrototypeOf(plan.security.schemes),Object.prototype);
 assert.equal(packet.resources[0].text,text);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} URI security follows graph bindings and component-name precedence`,()=>{
 const serialize=value=>format==='json'?JSON.stringify(value):require('yaml').stringify(value);
 const root='file:///execution/security-uri/api.'+format,fragment='file:///execution/security-uri/Provider';
 const uri='./Provider#/Alias';
 const value={openapi:version,info:{title:'URI security',version:'1'},components:{securitySchemes:{Provider:{type:'apiKey',in:'header',name:'X-Local'}}},security:[{Provider:[]},{[uri]:['reader']},{'./Provider#/Other':[]}],paths:{'/items':{get:{responses:{204:{description:'Empty'}}}}}};
 const resources=[{id:root,text:serialize(value),generation:1},{id:fragment,text:serialize({Alias:{$ref:'#/Remote~1~0'},'Remote/~':{type:'apiKey',in:'header',name:'X-Remote'},Other:{type:'http',scheme:'basic'}}),generation:2}];
 const packet={root,snapshot:'uri-security',resources},checked=analyse(packet);
 assert.equal(checked.complete,true);assert.deepEqual(checked.findings,[]);
 const plan=requestOperation({...packet,resource:root,pointer:'/paths/~1items/get'});
 assert.deepEqual(plan.security.requirements.map(value=>value.scopes),value.security);
 assert.equal(plan.security.schemes.Provider.parameterName,'X-Local');
 assert.equal(plan.security.schemes.Provider.source.resource,root);
 assert.equal(plan.security.schemes.Provider.source.pointer,'/components/securitySchemes/Provider');
 assert.equal(plan.security.schemes[uri].parameterName,'X-Remote');
 assert.equal(plan.security.schemes[uri].definition.resource,fragment);
 assert.equal(plan.security.schemes[uri].definition.pointer,'/Remote~1~0');
 assert.equal(plan.security.schemes[uri].source.resource,root);
 assert.equal(plan.security.schemes[uri].source.pointer,'/security/1/.~1Provider#~1Alias');
 assert.equal(plan.security.schemes['./Provider#/Other'].scheme,'basic');
 assert.deepEqual(resources.map(resource=>resource.text),[serialize(value),serialize({Alias:{$ref:'#/Remote~1~0'},'Remote/~':{type:'apiKey',in:'header',name:'X-Remote'},Other:{type:'http',scheme:'basic'}})]);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])test(`explicit part media choices use captured ${version} encoding semantics`,()=>{
 const value={openapi:version,info:{title:'Part choices',version:'1'},paths:{'/form':{post:{requestBody:{content:{'multipart/form-data':{
   schema:{type:'object',properties:{metadata:{type:'string'},image:{type:'string'},default:{type:'string'}}},
   encoding:{metadata:{contentType:'application/json; profile="a,b", text/plain'},image:{contentType:'image/*'},literal:{contentType:'application/*+json;; profile="a,b"'},ignored:{style:'form',contentType:'application/json, text/plain'}}
 }}},responses:{204:{description:'ok'}}}}}};
 const packet={root:id,snapshot:version,resource:id,pointer:'/paths/~1form/post',resources:[{id,text:JSON.stringify(value),generation:1}],mediaType:'multipart/form-data',files:[]};
 const plan=requestOperation(packet),parts=plan.requestBody.content[0].form.parts;
 assert.deepEqual(parts.metadata.contentTypes,['application/json; profile="a,b"','text/plain']);
 assert.equal(parts.metadata.requiresChoice,true);assert.equal(parts.image.allowsCustom,true);
 assert.deepEqual(parts.literal.concreteTypes,['application/*+json;; profile="a,b"']);
 assert.equal(parts.literal.allowsCustom,false);assert.equal(parts.literal.requiresChoice,false);
 assert.equal(requestFormMediaTypes({...packet,parts:['literal'],choices:{}}).types.literal,'application/*+json;; profile="a,b"');
 assert.throws(()=>requestFormMediaTypes({...packet,parts:['literal'],choices:{literal:'application/problem+json; profile="a,b"'}}));
 assert.equal(parts.metadata.source.pointer,'/paths/~1form/post/requestBody/content/multipart~1form-data/encoding/metadata/contentType');
 assert.equal(parts.default.source.pointer,'/paths/~1form/post/requestBody/content/multipart~1form-data/schema/properties/default');
 for(const part of Object.values(parts))assert.ok(part.source.range[1]>part.source.range[0]);
 assert.equal(parts.ignored.styled,!version.startsWith('3.0.'));
 const selected=requestFormMediaTypes({...packet,parts:['metadata','image','default'],choices:{metadata:'application/json; profile="a,b"',image:'image/png'}});
 assert.deepEqual({...selected.types},{metadata:'application/json; profile="a,b"',image:'image/png'});
 assert.equal(selected.identity,plan.identity);assert.equal(selected.snapshot,version);
 assert.throws(()=>requestFormMediaTypes({...packet,parts:['metadata'],choices:{}}),error=>error.code==='request.form.content-type');
 for(const choice of ['application/json','text/xml','text/plain, application/json','image/*','text/plain\r\nX: evil'])
   assert.throws(()=>requestFormMediaTypes({...packet,parts:['metadata'],choices:{metadata:choice}}));
 assert.throws(()=>requestFormMediaTypes({...packet,parts:['image'],choices:{image:'application/png'}}));
 assert.deepEqual(requestFormMediaTypes({...packet,parts:[],choices:{},files:[{name:'image',fallback:'application/octet-stream',selected:'image/png'},{name:'image',fallback:'image/jpeg',selected:'image/jpeg'}]}).files,['image/png','image/jpeg']);
 assert.throws(()=>requestFormMediaTypes({...packet,parts:[],choices:{},files:[{name:'image',fallback:'image/png'}]}));
 assert.throws(()=>requestFormMediaTypes({...packet,parts:['default'],choices:{default:'application/json'}}));
 if(!version.startsWith('3.0.')){
   assert.deepEqual({...requestFormMediaTypes({...packet,parts:['ignored'],choices:{}}).types},{});
   assert.throws(()=>requestFormMediaTypes({...packet,parts:['ignored'],choices:{ignored:'text/plain'}}));
 }else assert.equal(requestFormMediaTypes({...packet,parts:['ignored'],choices:{ignored:'text/plain'}}).types.ignored,'text/plain');
 const changed={...packet,resources:[{...packet.resources[0],text:JSON.stringify(value).replace('application/json; profile=\\"a,b\\", text/plain','application/json')}]};
 assert.throws(()=>requestFormMediaTypes({...changed,parts:['metadata'],choices:{metadata:'text/plain'}}));
});
test('part media list validation locates malformed quoted parameters without treating example text as declarations',()=>{
 for(const contentType of ['','text/plain,','text/plain; x="unfinished','*/json']){
  const value={openapi:'3.0.4',info:{title:'Invalid part',version:'1'},paths:{'/':{post:{requestBody:{content:{'multipart/form-data':{schema:{type:'object'},encoding:{a:{contentType}},example:{contentType:'not a media type'}}}},responses:{204:{description:'ok'}}}}}};
  const report=analyse({root:id,snapshot:'invalid',resources:[{id,text:JSON.stringify(value),generation:1}]});
  const findings=report.findings.filter(value=>value.code==='encoding.content-type');
  assert.equal(findings.length,1,JSON.stringify(report));assert.equal(findings[0].pointer,'/paths/~1/post/requestBody/content/multipart~1form-data/encoding/a/contentType');
  assert.ok(findings[0].range[1]>findings[0].range[0]);
 }
});
test('repeated media parameters are an execution limitation rather than a grammar violation',()=>{
 for(const contentType of ['text/plain; charset=utf-8; charset=utf-8','text/plain; charset=utf-8; charset=us-ascii']){
  const value={openapi:'3.2.1',info:{title:'Parameter ambiguity',version:'1'},paths:{'/':{post:{requestBody:{content:{'multipart/form-data':{schema:{type:'object'},encoding:{a:{contentType}}}}},responses:{204:{description:'ok'}}}}}};
  const packet={root:id,snapshot:'ambiguity',resources:[{id,text:JSON.stringify(value),generation:1}],resource:id,pointer:'/paths/~1/post',mediaType:'multipart/form-data',parts:['a'],choices:{},files:[]};
  const analysis=analyse(packet);assert.equal(analysis.complete,true);assert.equal(analysis.findings.some(finding=>finding.severity==='error'),false);
  assert.throws(()=>requestFormMediaTypes(packet),error=>error.code==='request.form.media-parameters.unsupported');
  assert.equal(packet.resources[0].text,JSON.stringify(value));
 }
});
const document={
 openapi:'3.2.1',info:{title:'Execution',version:'1'},
 servers:[{url:'https://{tenant}.example.invalid/v1',variables:{tenant:{default:'demo'}}}],
 components:{
  securitySchemes:{bearer:{type:'http',scheme:'bearer'}},
  pathItems:{Shared:{get:{responses:{204:{description:'shared'}}}}},
  schemas:{Dynamic:{$dynamicAnchor:'node',type:'object',properties:{next:{$dynamicRef:'#node'}}}},
 },
 paths:{'/things/{id}':{
  parameters:[{name:'id',in:'path',required:true,style:'matrix',schema:{type:'string'}}],
  get:{
   security:[{bearer:[]}],
   parameters:[{name:'tag',in:'query',explode:true,schema:{type:'array',items:{type:'string'}}}],
   responses:{200:{description:'ok',content:{'application/json':{examples:{literal:{value:{$ref:'payload data',amount:9007199254740992}}}}}}},
  },
 }},
};
const text=JSON.stringify(document).replace('9007199254740992','9007199254740993');
const input={root:id,snapshot:'captured-snapshot',resources:[{id,text,generation:7,identity:'captured'}]};

test('request parameter scalar projection reuses strict CST numeric lexemes at every leaf',()=>{
 const result=requestParameterValues({values:{array:'[9007199254740993,123456789012345678901234567890,1.0000000000000000001,false,null,"雪"]',object:'{"n":1.234567890123456789e99,"text":"100"}'}});
 assert.deepEqual(result,{version:1,values:{array:['9007199254740993','123456789012345678901234567890','1.0000000000000000001',false,null,'雪'],object:{n:'1.234567890123456789e99',text:'100'}}});
 for(const raw of ['[1,]','{"n":1,"n":2}','NaN','undefined'])assert.throws(()=>requestParameterValues({values:{value:raw}}));
});

test('request projection keeps inherited semantics, locations and exact example text',()=>{
 const operation=analyse(input).operations[0];
 const result=requestOperation({...input,resource:id,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(result.version,1);assert.equal(result.snapshot,input.snapshot);assert.equal(result.family,'3.2');
 assert.deepEqual(result.parameters.map(parameter=>[parameter.name,parameter.in,parameter.style,parameter.explode]),[
  ['id','path','matrix',false],['tag','query','form',true],
 ]);
 assert.equal(result.servers[0].url,'https://{tenant}.example.invalid/v1');
 assert.deepEqual(result.security.requirements[0].schemes,['bearer']);
 const example=result.responses[0].content[0].example;
 assert.equal(example.name,'literal');
 assert.match(example.raw,/"\$ref":"payload data"/);
 assert.match(example.raw,/9007199254740993/);
 assert.deepEqual(example.source.range.length,2);
});

test('reviewed response example is a located exact transaction and never resolves data refs',()=>{
 const operation=analyse(input).operations[0];
 const plan=requestOperation({...input,resource:id,pointer:operation.pointer,occurrence:operation.occurrence});
 const media=plan.responses[0].content[0];
 const raw='{"$ref":"still response data","amount":9007199254740993}';
 const result=planResponseExample({...input,target:media.definition,raw,redacted:true});
 assert.equal(result.kind,'response-example');assert.equal(result.redacted,true);
 assert.ok(result.edits.length>0);assert.match(result.changes[0].after,/9007199254740993/);
 assert.match(result.changes[0].after,/still response data/);
 assert.equal(result.bodyIdentity.length,64);
});

test('semantic coverage names pinned comparator gaps instead of claiming completeness',()=>{
 const result=semanticDiffCoverage(input);
 assert.ok(result.dynamicReferences.length>0);
 assert.ok(result.reusablePathItems.length>0);
 assert.equal(result.coverage.dynamicReferences,'unclassified');
 assert.equal(result.coverage.reusablePathItems,'unclassified');
});

test('oasdiff input keeps exact embedded schemas while using a proved local entry reference',()=>{
 const root='file:///execution/multi.json',schema='file:///execution/schema.json';
 const rootText=JSON.stringify({openapi:'3.1.2',info:{title:'Diff input',version:'1'},paths:{'/items':{get:{responses:{200:{description:'ok',content:{'application/json':{schema:{$ref:'./schema.json'}}}}}}}}});
 const schemaText='{"type":"integer","enum":[9007199254740993]}';
 const result=deriveBundle({root,snapshot:'oasdiff-snapshot',consumer:'oasdiff',outputId:'file:///temporary/base.json',resources:[
  {id:root,text:rootText,generation:1,identity:'root'},
  {id:schema,text:schemaText,generation:1,identity:'schema'},
 ]});
 assert.equal(result.complete,true);
 assert.match(result.output.text,/"\$ref":"#\/components\/schemas\//);
 assert.match(result.output.text,/9007199254740993/);
 assert.doesNotMatch(result.output.text,/"\$ref":"file:\/\/\/execution\/schema\.json#/);
});

test('H05 H07 H08 H15 projection retains item constraints, scope alternatives and representation layers',()=>{
 const value={
   openapi:'3.2.1',info:{title:'Projection',version:'1'},
   components:{securitySchemes:{oauth:{type:'oauth2',flows:{clientCredentials:{tokenUrl:'https://auth.invalid/token',scopes:{read:'Read'}}}}}},
   paths:{'/items':{post:{
     security:[{oauth:['read']},{}],
     parameters:[{name:'color',in:'cookie',style:'cookie',schema:{type:'array',items:{type:'string'}},examples:{pair:{serializedValue:'color=red; color=blue'}}}],
     requestBody:{content:{'multipart/form-data':{examples:{parts:{dataValue:{metadata:{id:1},note:'fish&chips'}}},encoding:{metadata:{contentType:'application/json'}}}}},
     responses:{200:{description:'ok',content:{'application/jsonl':{schema:{type:'array'},itemSchema:{type:'object',required:['id'],properties:{id:{type:'integer'}}}}}}}
   }}}
 };
 const packet={...input,resources:[{...input.resources[0],text:JSON.stringify(value)}]};
 const operation=analyse(packet).operations[0];
 const plan=requestOperation({...packet,resource:id,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(plan.parameters[0].explode,true);
 assert.equal(plan.parameters[0].example.representation,'serialized');
 assert.equal(plan.parameters[0].example.level,'parameter');
 assert.deepEqual(plan.security.requirements.map(r=>r.scopes),[{oauth:['read']},{}]);
 assert.match(plan.responses[0].content[0].itemSchema.pointer,/itemSchema$/);
 assert.match(plan.responses[0].content[0].schema.pointer,/schema$/);
 assert.deepEqual(plan.requestBody.content[0].example.fields,{metadata:['{"id":1}'],note:['fish&chips']});
 assert.equal(plan.requestBody.content[0].example.level,'media');
});

test('T01 saved YAML case values retain exact numeric types and lexemes through the canonical CST',()=>{
 const {executionCaseValues}=require('./dist/execution.cjs');
 const numbers=['1.0000000000000000001','9007199254740993','123456789012345678901234567890','1e-100','1e100'];
 const source={id:'file:///execution/busyapi.yaml',text:`version: 1\ntests:\n - name: exact\n   parameters: {query: {values: [${numbers.join(',')}]}}\n   body: {mediaType: application/json, value: {values: [${numbers.join(',')}], text: "9007199254740993"}}\n`};
 const values=executionCaseValues({source,name:'exact'});
 assert.deepEqual(values.parameters['query\0values'],{text:'['+numbers.join(',')+']',json:true});
 assert.equal(values.body.text,'{"values":['+numbers.join(',')+'],"text":"9007199254740993"}');
});

test('U4 JSON formatting preserves exact numeric lexemes and treats data refs literally',()=>{
 const {inspectExecutionJson}=require('./dist/execution.cjs');
 const raw='{"n":1.0000000000000000001,"big":9007199254740993,"$ref":"literal","items":[1e100]}';
 const inspected=inspectExecutionJson({text:raw});
 assert.match(inspected.pretty,/1\.0000000000000000001/);
 assert.match(inspected.pretty,/9007199254740993/);
 assert.match(inspected.pretty,/1e100/);
 assert.equal(inspected.entries[2].text,'"literal"');
 assert.throws(()=>inspectExecutionJson({text:'{"n":1,}'}));
});


test('H07 YAML scalar nodes keep literal media strings and form fields',()=>{
 const text='openapi: 3.2.1\ninfo: {title: Test, version: "1"}\npaths: {/x: {post: {requestBody: {content: {text/plain: {example: hello}, application/x-www-form-urlencoded: {examples: {fields: {dataValue: {note: "fish&chips", amount: 1.0000000000000000001}}}}}}, responses: {"204": {description: ok}}}}}\n';
 const packet={root:id,snapshot:'yaml-scalar',resources:[{id:id.replace('.json','.yaml'),text,generation:1,identity:'a'}]};packet.root=packet.resources[0].id;
 const operation=analyse(packet).operations[0];const plan=requestOperation({...packet,resource:packet.root,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(plan.requestBody.content[0].example.text,'hello');
 assert.deepEqual(plan.requestBody.content[1].example.fields,{note:['fish&chips'],amount:['1.0000000000000000001']});
 const {executionCaseValues}=require('./dist/execution.cjs');
 const values=executionCaseValues({source:{id:'file:///busyapi.yaml',text:'version: 1\ntests: [{name: raw, parameters: {query: {word: hello}}, body: {mediaType: text/plain, value: hello}}]\n'},name:'raw'});
 assert.deepEqual(values.parameters['query\0word'],{text:'hello',json:false});assert.deepEqual(values.body,{text:'hello',json:false});
 const nested=text.replace('note: "fish&chips"','note: {inner: "fish&chips"}');
 const nestedPacket={...packet,resources:[{...packet.resources[0],text:nested}]};
 const nestedPlan=requestOperation({...nestedPacket,resource:packet.root,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.match(nestedPlan.requestBody.content[1].example.conversionError,/nested|structured/i);
 const nestedJson=text.replace('text/plain: {example: hello}', 'application/json: {example: {outer: {inner: 1}}}, text/plain: {example: hello}');
 const jsonPlan=requestOperation({...packet,resources:[{...packet.resources[0],text:nestedJson}],resource:packet.root,pointer:operation.pointer,occurrence:operation.occurrence});
 assert.equal(jsonPlan.requestBody.content.find(m=>m.mediaType==='application/json').example.conversionError,undefined);
});

test('T01 saved exact values retain the existing numeric work bound before any request',()=>{
 const text='version: 1\ntests: [{name: bounded, body: {mediaType: application/json, value: '+ '1'.repeat(4097) +'}}]\n';
 assert.throws(()=>executionCaseValues({source:{id:'file:///project/busyapi.yaml',text},name:'bounded'}),error=>error.code==='limit.schema.numeric'&&error.message.includes('/tests/0/body/value')&&error.range[0]>0);
});

test('U3 configuration setup patches owned leaves and preserves exact unrelated CST values',()=>{
 const text="version: 1\nenvironments:\n  local:\n    baseUrl: http://old.example.test\n    x-extra: {exact: 1.0000000000000000001}\n    authentication:\n      alternative: 0\n      x-auth: {exact: 9007199254740993}\n      schemes:\n        access: {tokenRef: old-reference, x-scheme: 123456789012345678901234567890}\n    tls: {caFile: ca.pem, clientKeyPasswordRef: old-reference, x-tls: keep}\n";
 const result=planExecutionEnvironment({root:'file:///project/openapi.yaml',snapshot:'captured',source:{id:'file:///project/busyapi.yaml',generation:1,text},name:'local',definition:{baseUrl:'http://new.example.test',variables:{},headers:{},authentication:{alternative:0,schemes:{access:{tokenRef:'new-reference'}}},tls:{caFile:'ca.pem'}}});
 const after=result.changes[0].after;
 for(const value of ['1.0000000000000000001','9007199254740993','123456789012345678901234567890','x-tls: keep','http://new.example.test','new-reference'])assert.ok(after.includes(value),value);
 assert.ok(!after.includes('clientKeyPasswordRef'));
});

test('F04A canonical saved inputs traverse aliases at every structural level without rounding',()=>{
 const aliases=`version: 1
x-number: &number 1.0000000000000000001
x-large: &large 9007199254740993
x-object: &object {decimal: *number, large: *large}
x-query: &query {q: *large, nested: *object}
x-parameters: &parameters {query: *query}
x-body: &body {value: *object}
x-case: &case {name: exact, parameters: *parameters, body: *body}
tests: [*case]
`;
 const inline='version: 1\ntests: [{name: exact, parameters: {query: {q: 9007199254740993, nested: {decimal: 1.0000000000000000001, large: 9007199254740993}}}, body: {value: {decimal: 1.0000000000000000001, large: 9007199254740993}}}]\n';
 const project=text=>executionCaseValues({source:{id:'file:///execution/busyapi.yaml',text},name:'exact'});
 assert.deepEqual(project(aliases),project(inline));
 assert.equal(project(aliases).parameters['query\0q'].text,'9007199254740993');
 assert.throws(()=>project(aliases.replace('1.0000000000000000001','1'.repeat(4097))),e=>e.code.startsWith('limit.')&&e.range?.length===2);
});

test('F04B aliased field maps arrays objects and nested items preserve form conversion semantics',()=>{
 const project=(media,body)=>{
 const rid='file:///execution/alias.yaml';
 const text=`openapi: 3.2.1
info: {title: Aliases, version: '1'}
x-colors: &colors [red, blue]
x-number: &number 1.0000000000000000001
x-item: &item {n: *number}
x-items: &items [*item]
x-fields: &fields {color: *colors, n: *number}
paths:
  /x:
    post:
      requestBody:
        content:
          ${media}:
            examples: {sample: {dataValue: ${body}}}
      responses: {'204': {description: ok}}
`;
 const packet={root:rid,snapshot:'aliases',resources:[{id:rid,text,generation:1}]};
 const operation=analyse(packet).operations[0];
 return requestOperation({...packet,resource:rid,pointer:operation.pointer,occurrence:operation.occurrence}).requestBody.content[0].example;
 };
 for(const media of ['application/x-www-form-urlencoded','multipart/form-data']){
  const aliased=project(media,'*fields'),inline=project(media,'{color: [red, blue], n: 1.0000000000000000001}');
  assert.deepEqual(aliased.fields,inline.fields);
  assert.deepEqual(aliased.fields,{color:['red','blue'],n:['1.0000000000000000001']});
  for(const [alias,plain] of [['{field: *item}','{field: {n: 1.0000000000000000001}}'],['{field: *items}','{field: [{n: 1.0000000000000000001}]}']]){
   const a=project(media,alias),b=project(media,plain);
   assert.deepEqual(a.fields,b.fields);assert.equal(a.compositeFields,true);assert.equal(a.conversionError,b.conversionError);assert(a.conversionError);
  }
 }
});
