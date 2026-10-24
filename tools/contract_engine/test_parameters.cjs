const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const {referencePage}=require('./dist/reference_projection.cjs');
const {SourceDocument}=require('./dist/document.cjs');

for(const openapi of ['3.1.2','3.2.1'])for(const json of [false,true]) {
 const label=`${openapi} ${json?'JSON':'YAML'}`;
 const id='file:///parameter-fixture/root.'+(json?'json':'yaml'),part='file:///parameter-fixture/parts.'+(json?'json':'yaml');
 const resource=(id,value)=>({id,text:json?JSON.stringify(value):YAML.stringify(value),generation:3,identity:'captured'});
 const input=(root,fragment)=>({root:id,snapshot:'captured',resources:[resource(id,{openapi,info:{title:'Parameters',version:'1'},...root}),...(fragment?[resource(part,fragment)]:[])]});
 const pathParameter=(required=true)=>({name:'id',in:'path',required,schema:{type:'string'}});
 const query=(name)=>({name,in:'query',schema:{type:'string'}});
 const codes=result=>result.findings.map(finding=>finding.code);
 test(`effective parameters use real definition ranges and local overrides ${label}`,()=>{
  const root={paths:{'/p/{id}':{parameters:[{$ref:part+'#/Shared'}],get:{parameters:[pathParameter(false)],responses:{204:{description:'No body'}}}}}};
  const frozen=input(root,{Shared:pathParameter()});
  const before=frozen.resources.map(r=>r.text),result=analyse(frozen);
  assert(codes(result).includes('parameter.path.required'));
  assert(!codes(result).includes('parameter.path.missing'));
  const required=result.findings.find(f=>f.code==='parameter.path.required');
  assert.equal(required.resource,id);assert.equal(required.pointer,'/paths/~1p~1{id}/get/parameters/0');
  const page=referencePage({...frozen,resource:id,pointer:'/paths/~1p~1{id}/get'}).effective.find(e=>e.name==='parameters');
  assert.equal(page.complete,true);assert.equal(page.count,1);assert.equal(page.overriddenCount,1);assert.equal(page.entries[0].inherited,false);
  delete root.paths['/p/{id}'].get.parameters;
  const inherited=input(root,{Shared:pathParameter(false)}),invalid=analyse(inherited);
  const finding=invalid.findings.find(f=>f.code==='parameter.path.required');
  assert.equal(finding.resource,part);assert.equal(finding.pointer,'/Shared');
  assert.deepEqual(finding.range,new SourceDocument(inherited.resources[1].text,part).node('/Shared').range);
  assert(!codes(invalid).includes('parameter.path.missing'));
  const inheritedPage=referencePage({...inherited,resource:id,pointer:'/paths/~1p~1{id}/get'}).effective.find(e=>e.name==='parameters');
  assert.equal(inheritedPage.entries[0].source.pointer,'/paths/~1p~1{id}/parameters/0');
  assert.equal(inheritedPage.entries[0].definition.resource,part);assert.equal(inheritedPage.entries[0].definition.pointer,'/Shared');
  assert.deepEqual(frozen.resources.map(r=>r.text),before);
 });
 test(`duplicate lists, case-sensitive identities and absent path definitions ${label}`,()=>{
  const root={paths:{'/p/{id}':{parameters:[query('q'),query('q'),query('Q')],get:{parameters:[query('local'),query('local')],responses:{204:{description:'No body'}}}}}};
  const result=analyse(input(root));
  assert.deepEqual(result.findings.filter(f=>f.code==='parameter.duplicate').map(f=>f.pointer).sort(),[
   '/paths/~1p~1{id}/get/parameters/1','/paths/~1p~1{id}/parameters/1',
  ]);
  assert(codes(result).includes('parameter.path.missing'));
  root.paths['/p/{id}'].parameters=[pathParameter(),{...query('X-Id'),in:'header'},{...query('x-id'),in:'header'}];
  root.paths['/p/{id}'].get.parameters=[{...query('q')},{...query('Q')}];
  assert(!codes(analyse(input(root))).some(code=>code.startsWith('parameter.')));
 });
 test(`unavailable, ambiguous and cyclic references cannot invent missing parameters ${label}`,()=>{
  const root={paths:{'/p/{id}':{parameters:[{$ref:part+'#/Missing'}],get:{responses:{204:{description:'No body'}}}}}};
  const unavailable=analyse(input(root));
  assert.equal(unavailable.complete,false);assert(codes(unavailable).includes('reference.unavailable'));
  assert(!codes(unavailable).includes('parameter.path.missing'));
  const cyclic=input(root,{Missing:{$ref:'#/Other'},Other:{$ref:'#/Missing'}}),result=analyse(cyclic);
  assert.equal(result.complete,false);assert(codes(result).includes('parameter.reference.cycle'));
  assert(!codes(result).includes('parameter.path.missing'));
  const page=referencePage({...cyclic,resource:id,pointer:'/paths/~1p~1{id}/get'}).effective.find(e=>e.name==='parameters');
  assert.equal(page.complete,false);assert.equal(page.entries[0].state,'cycle');
  assert.equal(referencePage({...cyclic,resource:id,pointer:'/paths/~1p~1{id}/get'}).complete,false);
  const duplicated=input({paths:{'/p/{id}':{get:{parameters:[{$ref:'https://duplicate.invalid/definition#/Parameter'}],responses:{204:{description:'No body'}}}}}});
  duplicated.resources.push({...resource(part,{openapi:'3.2.1',$self:'https://duplicate.invalid/definition',Parameter:pathParameter()}),aliases:[]},
   resource('file:///parameter-fixture/other.'+(json?'json':'yaml'),{openapi:'3.2.1',$self:'https://duplicate.invalid/definition',Parameter:pathParameter()}));
  const ambiguous=analyse(duplicated);assert.equal(ambiguous.complete,false);assert(codes(ambiguous).includes('reference.ambiguous'));
  assert(!codes(ambiguous).includes('parameter.path.missing'));
 });
 test(`shared Path Items count physical operations once and keep parameter provenance ${label}`,()=>{
  const operation={operationId:'shared',responses:{204:{description:'No body'}}};
  const root={paths:{'/a/{id}':{$ref:part+'#/Path'},'/b/{id}':{$ref:part+'#/Path'}}};
  const result=analyse(input(root,{Path:{parameters:[pathParameter()],get:operation}}));
  assert.equal(result.operations.length,2);assert(!codes(result).includes('operation.id.duplicate'));
  assert(!codes(result).some(code=>code.startsWith('parameter.')));
  root.paths['/bad/{other}']={$ref:part+'#/Path'};
  const wrong=analyse(input(root,{Path:{parameters:[pathParameter()],get:operation}}));
  assert(codes(wrong).includes('parameter.path.missing'));assert(codes(wrong).includes('parameter.path.name'));
  assert.equal(wrong.findings.find(f=>f.code==='parameter.path.name').resource,part);
  root.paths['/another']={get:{...operation}};
  assert(codes(analyse(input(root,{Path:{parameters:[pathParameter()],get:operation}}))).includes('operation.id.duplicate'));
 });
 test(`callbacks, webhooks and payloads do not acquire Paths template checks ${label}`,()=>{
  const root={paths:{'/p':{get:{responses:{204:{description:'No body'}},callbacks:{notify:{'{$request.query.callback}':{post:{responses:{204:{description:'None'}}}}}}}}},
   webhooks:{'notify {not-a-path}':{post:{responses:{204:{description:'None'}}}}},
   'x-payload':{parameters:[{name:'not interpreted',in:'path',required:false}],operationId:'duplicate'}};
  assert(!codes(analyse(input(root))).some(code=>code.startsWith('parameter.')));
  const ids=input({paths:{'/a':{get:{operationId:'',responses:{204:{description:'None'}}}},'/b':{get:{operationId:'',responses:{204:{description:'None'}}}}}});
  assert(codes(analyse(ids)).includes('operation.id.duplicate'));
 });
 if(openapi.startsWith('3.2'))test(`querystring conflicts use effective local/inherited identities ${label}`,()=>{
  const all=name=>({name,in:'querystring',content:{'application/json':{schema:{type:'object'}}}});
  const root={paths:{'/p':{parameters:[all('whole')],query:{parameters:[all('whole')],responses:{204:{description:'No body'}}},additionalOperations:{COPY:{parameters:[query('q')],responses:{204:{description:'No body'}}}}}}};
  let result=analyse(input(root));
  assert(!codes(result).includes('parameter.querystring.duplicate'));
  assert(codes(result).includes('parameter.querystring.mixed'));
  assert.equal(result.findings.find(f=>f.code==='parameter.querystring.mixed').pointer,'/paths/~1p/parameters/0');
  root.paths['/p'].query.parameters.push(all('other'));
  result=analyse(input(root));assert(codes(result).includes('parameter.querystring.duplicate'));
  root.paths['/p'].query.parameters=[{name:'whole',in:'querystring',schema:{type:'string'},explode:false}];
  result=analyse(input(root));assert(codes(result).includes('parameter.querystring.content'));assert(codes(result).includes('parameter.querystring.field'));
  root.paths['/p'].query.parameters=[{name:'cookie',in:'cookie',schema:{type:'array'},explode:false}];
  assert(codes(analyse(input(root))).includes('parameter.cookie.explode'));
 });
}
