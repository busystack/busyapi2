const assert=require('node:assert/strict');
const {test}=require('node:test');
const YAML=require('yaml');
const {referenceChoices,referenceValue}=require('./dist/reference_choices.cjs');
const {createGraph}=require('./dist/model.cjs');
const {assistSource}=require('./dist/source_assistance.cjs');
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`typed reference choices ${version} ${json?'JSON':'YAML'} retain provenance, pagination and literal data`,()=>{
 const root='file:///project/root.'+(json?'json':'yaml'),external='file:///project/models.json';
 const key='a/b~%?#雪😀',pointer='/'+key.replaceAll('~','~0').replaceAll('/','~1');
 const uri='models.json#/'+encodeURIComponent(pointer.slice(1));
 const document={openapi:version,info:{title:'Choices',version:'1'},paths:{
  '/first':{get:{operationId:'notUnique',responses:{204:{description:'Empty'}}}},
  '/second':{get:{operationId:'notUnique',responses:{204:{description:'Empty'}}}},
 },components:{schemas:{Use:{$ref:'#/components/schemas/Boolean'},Boolean:false,
  External:{$ref:uri},Dynamic:{$dynamicAnchor:'node',type:'object'},DynamicUse:{$dynamicRef:'#node'},
  ...Object.fromEntries(Array.from({length:251},(_,i)=>['Item'+i,{type:'string'}])),
 },parameters:{Use:{$ref:'models.json#/Param'}},headers:{Use:{$ref:'models.json#/Header'}},
 links:{Next:{operationRef:'#/paths/~1first/get'}},examples:{Payload:{value:{$ref:'literal payload',components:{schemas:{fake:false}}}}},
 },'x-unknown':{components:{schemas:{fake:false}}}};
 const input={root,snapshot:'choices',resources:[{id:root,generation:4,identity:'root',text:json?JSON.stringify(document):YAML.stringify(document)},
  {id:external,generation:6,identity:'model',text:JSON.stringify({[key]:{type:'number'},Param:{name:'X-Name',in:'header',schema:{type:'string'}},Header:{description:'Not a Parameter',schema:{type:'string'}}})}]};
 const choose=(pointer,keyword='$ref',query='',offset=0)=>referenceChoices({...input,resource:root,pointer,keyword,query,offset});
 const first=choose('/components/schemas/Use','$ref','Item');assert.equal(first.count,251);assert.equal(first.entries.length,50);
 const last=choose('/components/schemas/Use','$ref','Item',250);assert.equal(last.entries.length,1);
 const all=[...first.entries,...[50,100,150,200,250].flatMap(offset=>choose('/components/schemas/Use','$ref','Item',offset).entries)];
 assert.equal(new Set(all.map(e=>e.semanticId)).size,251);
 const parameters=choose('/components/parameters/Use');assert(parameters.entries.every(e=>e.kind==='parameter'));
 assert(parameters.entries.some(e=>e.target.resource===external&&e.target.pointer==='/Param'));
 assert(!parameters.entries.some(e=>e.target.pointer==='/Header'));
 const headers=choose('/components/headers/Use');assert(headers.entries.every(e=>e.kind==='header'));assert.equal(headers.entries[0].target.pointer,'/Header');
 const schemas=choose('/components/schemas/Use','$ref','Boolean');assert.equal(schemas.entries[0].selected,true);assert.equal(schemas.entries[0].role,'component');
 assert.equal(schemas.entries[0].target.generation,4);
 assert.equal(choose('/components/schemas/Use','$ref','fake').entries.length,0);
 const escaped=choose('/components/schemas/Use','$ref',key).entries[0];assert.equal(escaped.target.pointer,pointer);assert.equal(escaped.target.resource,external);
 const {graph}=createGraph(input),from=graph.scope(root,'/components/schemas/Use');
 assert.equal(graph.resolve(escaped.value,from).targetPointer,pointer);
 const links=choose('/components/links/Next','operationRef');assert.equal(links.count,2);assert.equal(new Set(links.entries.map(e=>e.value)).size,2);
 assert(links.entries.every(e=>e.kind==='operation'));
 const dynamic=choose('/components/schemas/DynamicUse','$dynamicRef');assert.equal(dynamic.count,1);assert.equal(dynamic.entries[0].value,'#node');assert.equal(dynamic.entries[0].dynamic,true);
 const valueNode=graph.docs.get(root).node('/components/schemas/DynamicUse/$dynamicRef');
 const assisted=assistSource({...input,resource:root,caret:valueNode.range[0]+2,action:'completion'});
 // The same already-authored value is a no-op, not a normalization edit.
 assert(!assisted.completions.some(c=>c.edits[0].replacement.includes('#node')));
 for(const location of ['/components/examples/Payload/value','/x-unknown','/components/schemas/Boolean'])
  assert.throws(()=>choose(location),e=>e.code==='reference.choice.context');
 const snapshot=JSON.stringify(input.resources);choose('/components/schemas/Use');assert.equal(JSON.stringify(input.resources),snapshot);
});
test('reference addresses preserve query identity, reserved escapes, nested ids and unknown dialect boundaries',()=>{
 const root='file:///project/root.json';
 const document={openapi:'3.2.1',$self:'https://contracts.invalid/root.json?view=one',info:{title:'URI','version':'1'},paths:{},components:{schemas:{
  Use:{$ref:'#/components/schemas/Boolean'},Boolean:false,Target:{$id:'nested/a%2Fb?view=two',type:'string'},
  Unknown:{$id:'urn:unknown', $schema:'https://dialect.invalid/custom',type:'string'},
 }}};
 const input={root,snapshot:'uris',resources:[{id:root,text:JSON.stringify(document),generation:1,identity:'uri'}]}, {graph}=createGraph(input);
 const from=graph.scope(root,'/components/schemas/Use'),to=graph.scope(root,'/components/schemas/Target');
 const value=referenceValue(graph,from,to);assert(value.includes('a%2Fb?view=two'));assert.equal(graph.resolve(value,from).targetPointer,to.pointer);
 assert.equal(referenceValue(graph,from,graph.scope(root,'/components/schemas/Unknown')),undefined);
 const choices=referenceChoices({...input,resource:root,pointer:from.pointer,query:'',keyword:'$ref'});
 assert.equal(choices.complete,false);assert(!choices.entries.some(e=>e.target.pointer.endsWith('/Unknown')));
});
test('external identified schemas retain a proven retrieval route without changing canonical identity or dynamic anchor semantics',()=>{
 const root='file:///project/root.json',external='file:///project/a%20model.json';
 const data={openapi:'3.2.1',info:{title:'Retrieval',version:'1'},paths:{},components:{schemas:{Use:{$ref:'a%20model.json#/$defs/Old'}}}};
 const input={root,snapshot:'retrieval',resource:root,pointer:'/components/schemas/Use',query:'New',resources:[
  {id:root,generation:1,text:JSON.stringify(data)},
  {id:external,generation:1,text:JSON.stringify({$id:'urn:busyapi:external',$dynamicAnchor:'node',$defs:{Old:{type:'string'},New:{$id:'urn:busyapi:nested',type:'integer'}}})},
 ]};
 const {graph}=createGraph(input),from=graph.scope(root,input.pointer),to=graph.scope(external,'/$defs/New');
 const value=referenceValue(graph,from,to);assert.equal(value,'a%20model.json#/$defs/New');
 assert.equal(graph.resolve(value,from).targetPointer,to.pointer);assert.equal(to.base,'urn:busyapi:nested');
 const dynamic=referenceValue(graph,from,graph.scope(external,''),'$dynamicRef');
 assert.equal(dynamic,'a%20model.json#node');
 const resolved=graph.resolve(dynamic,from,true);assert.equal(resolved.targetPointer,'');assert.equal(resolved.dynamic.anchor,'node');
 assert.equal(resolved.dynamic.candidates.length,1);
 // A retrieval alias is not an alias for a nested resource's anchors.
 assert.equal(graph.resolve('a%20model.json#nested',from).resolution,'missing');
 const self='https://contracts.invalid/other';
 const described={...input,resources:[input.resources[0],{id:external,generation:1,text:JSON.stringify({openapi:'3.2.1',$self:self,info:{title:'Other',version:'1'},paths:{},components:{schemas:{New:{type:'string'}}}})}]};
 const declared=createGraph(described).graph;
 assert.equal(referenceValue(declared,declared.scope(root,input.pointer),declared.scope(external,'/components/schemas/New')),self+'#/components/schemas/New');
});
