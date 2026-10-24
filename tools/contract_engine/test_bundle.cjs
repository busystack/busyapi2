const assert=require('node:assert/strict');
const {test}=require('node:test');
const fs=require('node:fs');
const YAML=require('yaml');
const {deriveBundle}=require('./dist/derived_bundle.cjs');
const {createGraph,analyse}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const root='https://contracts.invalid/api/root.json',outputId='https://offline.invalid/export/openapi.json';
const resource=(id,text)=>({id,text,generation:1,identity:require('node:crypto').createHash('sha256').update(text).digest('hex')});
const input=(document,others=[])=>({root,outputId,snapshot:'bundle-fixture',resources:[resource(root,typeof document==='string'?document:JSON.stringify(document)),...others]});
const api=version=>({openapi:version,info:{title:'Derived bundle',version:'1'},paths:{}});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const alias of json?[false]:[false,true])for(const value of [false,true])for(const external of [false,true])test(`boolean example and explicit schema occurrences remain distinct ${version} ${json} alias=${alias} value=${value} external=${external}`,async()=>{
 const entry=root.replace('.json',json?'.json':'.yaml'),model='https://contracts.invalid/api/boolean.'+(json?'json':'yaml'),document=api(version),other=api(version),owner=external?other:document,identity=external?model:entry;
 owner.components={examples:{Boolean:{summary:'Authored boolean data',value}}};
 document.components={...document.components,examples:{...document.components?.examples,Captured:{$ref:(external?model:'')+'#/components/examples/Boolean'}},schemas:{Use:{$ref:(external?model:'')+'#/components/examples/Boolean/value',examples:[0,'sample']}}};
 const render=data=>{const text=json?JSON.stringify(data):YAML.stringify(data,{lineWidth:0});return alias&&data===owner?'x-boolean: &boolean '+value+'\n'+text.replace('value: '+value,'value: *boolean'):text;},params={root:entry,outputId,snapshot:'boolean-literal',resources:[resource(entry,render(document)),...(external?[resource(model,render(other))]:[])]},frozen=params.resources.map(value=>value.text);
 const before=await evaluateSchemas(params);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[value,value]);
 const result=deriveBundle(params);assert.equal(resolve(result,identity,'/components/examples/Boolean').value,value,'Literal boolean data must not become a generated reference object');
 const relocated='file:///independent/boolean%20%E9%9B%AA/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'boolean-literal-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[value,value]);assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`nested identified literal occurrences retain resource boundaries ${version} ${json}`,async()=>{
 const entry=root.replace('.json',json?'.json':'.yaml'),model='https://identities.invalid/owner',tree='https://identities.invalid/tree',payload={$ref:'tree','x-number':111},literal={$id:'nested',const:payload},document=api(version),schema={$id:model,const:literal};
 document.components={schemas:{Data:{$ref:model,examples:[literal,{$id:'nested',const:{...payload,'x-number':222}}]},Outer:{$ref:model+'#/const',examples:[payload,{...payload,'x-number':222}]},Inner:{$ref:model+'#/const/const',examples:['good',1]}}};
 const render=value=>(json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0})).replaceAll('111','9007199254740993').replaceAll('222','9007199254740992'),params={root:entry,outputId,snapshot:'identified-literal',resources:[resource(entry,render(document)),resource(model,render(schema)),resource(tree,render({$id:tree,type:'string'}))]};
 const before=await evaluateSchemas(params);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,true,false,true,false]);
 const result=deriveBundle(params),data=resolve(result,model,''),outer=resolve(result,model,'/const');
 assert.equal(data.const.$id,'nested');assert.equal(data.const.const.$ref,'tree');assert.equal(outer.$id,'https://identities.invalid/nested');assert.equal(outer.const.$ref,'tree');
 assert(result.identitiesRetained.includes('https://identities.invalid/nested'));
 const relocated='file:///independent/nested-id%20%E9%9B%AA/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'identified-literal-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,true,false,true,false]);
});
test('hundreds of literal/schema placements preserve the last target without repeated whole-output surgery',{timeout:30000},async()=>{
 const count=512,model='https://identities.invalid/many',tree='https://identities.invalid/tree',document=api('3.2.1'),payload=Object.fromEntries(Array.from({length:count},(_,index)=>['P'+index,{$ref:'tree',description:'Target '+index,'x-number':111}]));
 document.components={schemas:Object.fromEntries(Array.from({length:count},(_,index)=>['Use'+index,{$ref:model+'#/const/P'+index,...([0,count-1].includes(index)?{examples:['good',1]}:{})}]))};
 const render=value=>JSON.stringify(value).replaceAll('111','9007199254740993'),params={root,outputId,snapshot:'many-literals',resources:[resource(root,render(document)),resource(model,render({$id:model,const:payload})),resource(tree,render({$id:tree,type:'string'}))]};
 const frozen=params.resources.map(value=>value.text),result=deriveBundle(params),data=resolve(result,model,'');
 assert.equal(data.const.P511.$ref,'tree');assert.equal(resolve(result,model,'/const/P511').description,'Target 511');assert.equal(Object.keys(data.$defs).length,count);
 assert.equal(result.provenance.filter(p=>p.kind==='literal-data-occurrence'&&p.source.resource===model).length,count);
 const relocated='file:///independent/many/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'many-literals-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,true,false]);assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`explicit Example target inside extension data has distinct literal and URI occurrences ${version} ${json}`,()=>{
 const document=api(version),entry=root.replace('.json',json?'.json':'.yaml');
 document['x-data']={Example:{summary:'Literal source',externalValue:'payload%20%E9%9B%AA.txt','x-payload':{$ref:'literal payload',value:111}}};
 document.components={examples:{Shared:{$ref:'#/x-data/Example'}}};
 const source=(json?JSON.stringify(document):YAML.stringify(document,{lineWidth:0})).replaceAll('111','9007199254740993.00'),params={root:entry,outputId,snapshot:'example-data',resources:[resource(entry,source)]};
 const result=deriveBundle(params),output=JSON.parse(result.output.text),example=resolve(result,entry,'/x-data/Example');
 assert.equal(output['x-data'].Example.externalValue,'payload%20%E9%9B%AA.txt');assert.equal(output['x-data'].Example['x-payload'].$ref,'literal payload');
 assert.equal(example.externalValue,'https://contracts.invalid/api/payload%20%E9%9B%AA.txt');assert.equal(example['x-payload'].$ref,'literal payload');
 assert(result.output.text.includes('9007199254740993.00'));assert(result.provenance.some(p=>p.kind==='literal-data-occurrence'&&p.derived.pointer==='/x-data/Example'));
 assert.equal(params.resources[0].text,source);assert.deepEqual(result.sourceResources.map(item=>item.id),[entry]);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`nested literal/schema occurrences and generated-name collisions retain exact data ${version} ${json}`,async()=>{
 const entry=root.replace('.json',json?'.json':'.yaml'),model='https://identities.invalid/nested',tree='https://identities.invalid/tree',payload={$ref:'tree','x-number':111},literal={const:payload},schema={$id:model,const:literal,$defs:{Original:{type:'integer'}}},document=api(version);
 document.components={schemas:{Data:{$ref:model,examples:[literal,{const:{...payload,'x-number':222}}]},Outer:{$ref:model+'#/const',examples:[payload,{...payload,'x-number':222}]},Inner:{$ref:model+'#/const/const',examples:[{value:'good'},{value:1}]}}};
 const render=value=>(json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0})).replaceAll('111','9007199254740993').replaceAll('222','9007199254740992');
 const params=()=>({root:entry,outputId,snapshot:'nested-literal',resources:[resource(entry,render(document)),resource(model,render(schema)),resource(tree,render({$id:tree,type:'object',properties:{value:{type:'string'}},required:['value']}))]});
 const first=deriveBundle(params()),derivedSchema=resolve(first,model,''),generated=Object.keys(derivedSchema.$defs).filter(name=>name.startsWith('_busyapi_literal_'));
 assert.equal(generated.length,2);for(const name of generated)schema.$defs[name]={type:'integer',description:'Original colliding definition '+name};
 const captured=params(),frozen=captured.resources.map(value=>value.text),before=await evaluateSchemas(captured);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,true,false,true,false]);
 const result=deriveBundle(captured),value=resolve(result,model,'');
 assert.equal(value.const.const.$ref,'tree');for(const name of generated)assert.equal(value.$defs[name].description,'Original colliding definition '+name);
 assert.equal(Object.keys(value.$defs).length,5);
 const relocated='file:///independent/nested%20%E9%9B%AA/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'nested-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,true,false,true,false]);assert.deepEqual(captured.resources.map(value=>value.text),frozen);
 assert.equal(deriveBundle({...captured,resources:[captured.resources[2],captured.resources[0],captured.resources[1]]}).output.text,result.output.text);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const external of [false,true])for(const keyword of ['$ref','$dynamicRef'])test(`literal constraint also used as schema retains both occurrences ${version} ${json} ${external} ${keyword}`,async()=>{
 const document=api(version),model='https://identities.invalid/model',tree='https://identities.invalid/tree',payload={[keyword]:'tree'+(keyword==='$dynamicRef'?'#node':''),'x-number':111},schema={$id:model,const:payload};
 document.components={schemas:{Data:external?{$ref:model,examples:[payload,{...payload,'x-number':222}]}:{...schema,examples:[payload,{...payload,'x-number':222}]},Use:{$ref:model+'#/const',examples:[{value:'good',child:{value:'good'}},{value:'good',child:{value:1}}]}}};
 const recursive={$id:tree,$dynamicAnchor:'node',type:'object',properties:{value:{type:'string'},child:{$dynamicRef:'#node'}},required:['value'],unevaluatedProperties:false};
 const entry=root.replace('.json',json?'.json':'.yaml'),render=value=>(json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0})).replaceAll('111','9007199254740993').replaceAll('222','9007199254740992'),params={root:entry,outputId,snapshot:'literal-constraint',resources:[resource(entry,render(document)),...(external?[resource(model,render(schema))]:[]),resource(tree,render(recursive))]},frozen=params.resources.map(value=>value.text);
 const before=await evaluateSchemas(params);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,true,false]);
 const result=deriveBundle(params),originalData=resolve(result,external?model:entry,external?'':'/components/schemas/Data');
 assert.equal(originalData.const[keyword],payload[keyword]);
 assert(result.output.text.includes('9007199254740993'));assert(result.provenance.some(p=>p.kind==='literal-data-occurrence'&&p.source.pointer===(external?'/const':'/components/schemas/Data/const')));
 const relocated='file:///independent/literal%20%E9%9B%AA/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'literal-constraint-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,true,false]);assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])test(`bundle refuses to change a referenced object's authored family ${version}`,()=>{
 const other=version.startsWith('3.1')?'3.2.1':'3.1.2',document=api(version),part='https://contracts.invalid/api/part.json';
 document.paths['/shared']={$ref:'part.json#/components/pathItems/Shared'};
 const external=api(other);external.components={pathItems:{Shared:{get:{responses:{'204':{description:'No content'}}}}}};
 const params=input(document,[resource(part,JSON.stringify(external))]),frozen=params.resources.map(value=>value.text);
 assert.throws(()=>deriveBundle(params),error=>error.code==='bundle.object.version');
 assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`bundle retains empty-id canonical anchors and real instance outcomes ${version} ${json?'JSON':'YAML'}`,async()=>{
 const document=api(version);document.components={schemas:{Tree:{$id:'https://schemas.invalid/tree#',$dynamicAnchor:'node',type:'object',properties:{value:{type:'integer'},child:{$dynamicRef:'#node'}},required:['value'],unevaluatedProperties:false},Use:{$ref:'https://schemas.invalid/tree#node',examples:[{value:1,child:{value:2}},{value:1,child:{value:'wrong'}}]}}};
 const source=json?JSON.stringify(document):YAML.stringify(document),id=root.replace('.json',json?'.json':'.yaml'),params={root:id,outputId,snapshot:'empty-id',resources:[resource(id,source)]},before=await evaluateSchemas(params),result=deriveBundle(params);
 const after=await evaluateSchemas({root:outputId,snapshot:'empty-id-derived',resources:[resource(outputId,result.output.text)]});
 assert.equal(before.complete,true,JSON.stringify(before.findings));assert.equal(after.complete,true,JSON.stringify(after.findings));
 assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false]);assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false]);
 assert.equal(params.resources[0].text,source);assert(source.includes('https://schemas.invalid/tree#'));
 const graph=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]}).graph;
 assert.equal(graph.issues.length,0);assert.equal(graph.references.find(ref=>ref.keyword==='$dynamicRef').dynamic.anchor,'node');
});
const resolve=(result,source,pointer)=>{
 const mapped=result.provenance.find(p=>p.source.resource===source&&p.source.pointer===pointer&&!['effective-schema-dialect','schema-reference-occurrence','literal-data-occurrence'].includes(p.kind));
 assert(mapped,'Original-to-derived provenance is required: '+source+'#'+pointer);
 const next=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]});
 return next.docs.get(outputId).node(mapped.derived.pointer).value;
};
for(const version of ['3.1.2','3.2.1'])for(const json of [true,false])test(`derived bundle ${version} ${json} retains rich operations, recursive schemas, literal payloads and exact values`,async()=>{
 const path=require('node:path'),family=version.startsWith('3.1')?'31':'32';
 const original=JSON.parse(fs.readFileSync(path.join(__dirname,'../../fixtures/compatibility/oas'+family+'.json'),'utf8'));
 original.components.examples={Serialized:{externalValue:'https://must-not-fetch.invalid/payload'},Big:{value:{integer:111,decimal:222,zero:333}}};
 original['x-payload']={$ref:'literal extension',$id:'not a schema id',schemas:{fake:{$ref:'must not resolve'}}};
 const ext=fs.readFileSync(path.join(__dirname,'../../fixtures/compatibility/schema.json'),'utf8');
 const render=value=>json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0});
 const rootId=root.replace('.json',json?'.json':'.yaml');
 const text=render(original).replaceAll('111','9007199254740993').replaceAll('222','1.00000000000000000001').replaceAll('333','-0');
 const params={root:rootId,outputId,snapshot:'rich',resources:[resource(rootId,text),resource('https://contracts.invalid/api/schema.json',ext)]};
 const frozen=params.resources.map(r=>r.text),result=deriveBundle(params),repeat=deriveBundle(params);
 assert.equal(result.output.text,repeat.output.text);assert.deepEqual(params.resources.map(r=>r.text),frozen);
 const document=JSON.parse(result.output.text);
 assert.equal(document.openapi,version);assert.equal(document.paths['/things'].get.operationId,'listThings');
 if(family==='32'){assert.equal(document.paths['/things'].query.operationId,'queryThings');assert.equal(document.paths['/things'].additionalOperations.COPY.operationId,'copyThings');}
 assert.deepEqual(document['x-payload'],original['x-payload']);
 assert.deepEqual(document.paths['/things'].get.responses['200'].content['application/json'].example,original.paths['/things'].get.responses['200'].content['application/json'].example);
 assert.deepEqual(document.components.examples.Serialized,original.components.examples.Serialized);
 for(const lexeme of ['9007199254740993','1.00000000000000000001','-0'])assert(result.output.text.includes(lexeme));
 for(const entries of Object.values(document.components))for(const name of Object.keys(entries))assert.match(name,/^[A-Za-z0-9._-]+$/);
 assert.equal(resolve(result,'https://contracts.invalid/api/schema.json','/a~1b').type,'string');
 assert.equal(resolve(result,rootId,'/components/schemas/Boolean'),true);
 assert.equal(resolve(result,rootId,'/components/schemas/Composed').allOf.length,2);
 const checked=analyse({root:outputId,snapshot:'derived',resources:[resource(outputId,result.output.text)]});assert.equal(checked.complete,true);assert(!checked.findings.some(f=>f.severity==='error'));
 const schemas=await evaluateSchemas({root:outputId,snapshot:'derived',resources:[resource(outputId,result.output.text)]});assert.equal(schemas.complete,true,JSON.stringify(schemas.findings));
});
for(const version of ['3.1.2','3.2.1'])test(`derived bundle ${version} keeps distinct pointer targets and legal deterministic collision-resistant names`,()=>{
 const keys=['a/b','a~1b','a~01b','a_b','a-b','a.b','a~b','雪/😀'];
 const schemas=Object.fromEntries(keys.map((name,i)=>[name,{type:'string',description:'target-'+i}]));
 schemas.boolean=false;schemas.recursive={type:'object',properties:{self:{$ref:'#/recursive'}}};
 const document=api(version);document.components={schemas:Object.fromEntries([...keys,'boolean','recursive'].map((name,i)=>['S'+i,{$ref:'../models.json#/'+name.replaceAll('~','~0').replaceAll('/','~1')}]))};
 const model=resource('https://contracts.invalid/models.json',JSON.stringify(schemas));
 const first=deriveBundle(input(document,[model])),generated=Object.keys(JSON.parse(first.output.text).components.schemas).find(name=>name.startsWith('_busyapi_'));
 document.components.schemas[generated]={type:'integer',description:'User-owned colliding component'};
 const second=deriveBundle(input(document,[model]));
 assert.equal(resolve(second,root,'/components/schemas/'+generated).description,'User-owned colliding component');
 for(let i=0;i<keys.length;i++)assert.equal(resolve(second,model.id,'/'+keys[i].replaceAll('~','~0').replaceAll('/','~1')).description,'target-'+i);
 assert.equal(resolve(second,model.id,'/boolean'),false);
 const graph=createGraph({root:outputId,resources:[resource(outputId,second.output.text)]}).graph;
 assert.equal(graph.issues.length,0);assert(graph.references.every(r=>r.resolution==='resolved'));
});
for(const version of ['3.1.2','3.2.1'])test(`derived bundle ${version} retains nested ids, anchors and real dynamic evaluation`,async()=>{
 const document=api(version);
 if(version.startsWith('3.2'))document.$self='https://identities.invalid/entry';
 const model='https://models.invalid/base.json',models={$id:'https://models.invalid/resource',$defs:{Tree:{$id:'tree',$dynamicAnchor:'node',type:'object',properties:{value:{type:'integer'},child:{$dynamicRef:'#node'}},required:['value']},Strict:{$id:'strict',$dynamicAnchor:'node',$ref:'tree',unevaluatedProperties:false}},properties:{standalone:{$ref:'child'}}};
 document.paths['/p']={post:{requestBody:{content:{'application/json':{schema:{$ref:model+'#/$defs/Strict'},examples:{good:{value:{value:1,child:{value:2}}},bad:{value:{value:1,child:{value:2,unexpected:true}}}}}}},responses:{'204':{description:'Bodyless'}}}};
 const params=input(document,[resource(model,JSON.stringify(models)),resource('https://models.invalid/child',JSON.stringify({type:'string',description:'nested child sentinel'}))]);
 const before=await evaluateSchemas(params);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false]);
 const result=deriveBundle(params),after=await evaluateSchemas({root:outputId,snapshot:'derived',resources:[resource(outputId,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false]);
 assert.equal(JSON.parse(result.output.text).paths['/p'].post.responses['204'].content,undefined);
 assert.equal(JSON.parse(result.output.text).$self,document.$self);
 assert(result.identitiesRetained.includes('https://models.invalid/tree'));assert(result.identitiesRetained.includes('https://models.invalid/strict'));
});
test('derived bundle imports actual reusable owners and preserves original-source evidence',()=>{
 const document=api('3.2.1');
 document.paths['/p']={$ref:'path.json'};
 const external={get:{operationId:'read',responses:{'200':{$ref:'response.json'}}}};
 const response={description:'Remote response',headers:{'X-Count':{schema:{type:'integer'}}},links:{again:{operationRef:'path.json#/get'}}};
 const result=deriveBundle(input(document,[resource('https://contracts.invalid/api/path.json',JSON.stringify(external)),resource('https://contracts.invalid/api/response.json',JSON.stringify(response))]));
 assert.equal(resolve(result,'https://contracts.invalid/api/path.json','/get').operationId,'read');
 assert.equal(resolve(result,'https://contracts.invalid/api/response.json','').description,'Remote response');
 assert(result.provenance.some(p=>p.kind==='header'&&p.source.pointer==='/headers/X-Count'));
 const before=createGraph(input(document,[resource('https://contracts.invalid/api/path.json',JSON.stringify(external)),resource('https://contracts.invalid/api/response.json',JSON.stringify(response))]));
 const after=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]});
 const references=result.provenance.filter(p=>p.kind==='reference');
 assert.equal(references.length,before.graph.references.length);
 for(const ref of before.graph.references) {
  const pointer=ref.pointer+'/'+ref.keyword.replaceAll('~','~0').replaceAll('/','~1');
  const mapped=references.find(p=>p.source.resource===ref.resource&&p.source.pointer===pointer);
  assert(mapped,'Every actual graph edge retains its original field, including imported Link targets');
  assert(after.docs.get(outputId).dataNode(mapped.derived.pointer));
 }
});
test('derived bundle fails closed on unavailable, ambiguous or meaning-changing inputs without source changes',()=>{
 const document=api('3.1.2');document.components={schemas:{Missing:{$ref:'https://unapproved.invalid/missing'}}};
 const params=input(document),saved=params.resources[0].text;
 assert.throws(()=>deriveBundle(params),e=>e.code==='bundle.graph');assert.equal(params.resources[0].text,saved);
 assert.throws(()=>deriveBundle({...params,outputId:root}),e=>e.code==='bundle.destination');
});
for(const version of ['3.1.2','3.2.1'])test(`derived bundle ${version} keeps standalone dialect boundaries and relative presentation identities`,async()=>{
 const document=api(version);document.servers=[{url:'../{region}/v1',variables:{region:{default:'dev'}}}];
 document.externalDocs={url:'guide.html'};document.info.contact={url:'./contact'};
 document.components={examples:{Remote:{$ref:'../example.json'}},schemas:{Value:{$ref:'../standalone.json'}}};
 const standalone={$schema:'https://json-schema.org/draft/2020-12/schema',type:'number',multipleOf:0.1,examples:[0.3,0.31]};
 const example={externalValue:'../payload.txt',description:'A location, not an acquisition capability'};
 const params=input(document,[resource('https://contracts.invalid/standalone.json',JSON.stringify(standalone)),resource('https://contracts.invalid/example.json',JSON.stringify(example))]);
 const result=deriveBundle(params),value=JSON.parse(result.output.text);
 assert(value.servers[0].url.includes('{region}'));
 for(const region of ['dev','east/west','../other'])assert.equal(new URL(value.servers[0].url.replace('{region}',region),outputId).href,new URL('../'+region+'/v1',root).href);
 assert.equal(value.externalDocs.url,'https://contracts.invalid/api/guide.html');
 assert.equal(value.info.contact.url,'https://contracts.invalid/api/contact');
 assert.equal(resolve(result,'https://contracts.invalid/example.json','').externalValue,'https://contracts.invalid/payload.txt');
 assert.equal(resolve(result,'https://contracts.invalid/standalone.json','').$schema,standalone.$schema);
 const checked=await evaluateSchemas({root:outputId,snapshot:'derived',resources:[resource(outputId,result.output.text)]});
 assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.evaluations.map(e=>e.valid),[true,false]);
});
test('derived 3.2 security URI requirements import the actual scheme without inventing credentials',()=>{
 const document=api('3.2.1');document.security=[{'../security.json':['read']}];
 const security={type:'oauth2',flows:{clientCredentials:{tokenUrl:'token',scopes:{read:'Read'}}}};
 const result=deriveBundle(input(document,[resource('https://contracts.invalid/security.json',JSON.stringify(security))]));
 const value=JSON.parse(result.output.text),name=Object.keys(value.security[0])[0];assert(name.startsWith('#/components/securitySchemes/'));
 const mapped=result.provenance.find(p=>p.kind==='reference'&&p.connection==='security');
 assert.equal(mapped.source.pointer,'/security/0/..~1security.json');
 assert.equal(mapped.derived.pointer,'/security/0/'+name.replaceAll('~','~0').replaceAll('/','~1'));
 const scopes=result.provenance.filter(p=>p.source.pointer==='/security/0/..~1security.json');
 assert(scopes.some(p=>p.kind==='string-array'));
 for(const scope of scopes)assert.equal(scope.derived.pointer,mapped.derived.pointer);
 assert.deepEqual(value.security[0][name],['read']);
 assert.equal(resolve(result,'https://contracts.invalid/security.json','').flows.clientCredentials.tokenUrl,'token');
 assert.equal(value.servers[0].url,'https://contracts.invalid/');
 assert.equal(new URL('token',value.servers[0].url).href,'https://contracts.invalid/token');
 assert(!result.output.text.includes('access_token'));
});
for(const version of ['3.1.2','3.2.1'])for(const mapped of [false,true])for(const json of [false,true])test(`API URL bases retain retrieval identity, not schema/document identity ${version} mapped=${mapped} ${json?'JSON':'YAML'}`,()=>{
 const ext=json?'json':'yaml',retrieval='https://device.example/contracts/openapi.'+ext,physical=mapped?'file:///private/cache/openapi.'+ext:retrieval;
 const document=api(version);if(version.startsWith('3.2'))document.$self='https://identity.example/description/openapi.json';
 document.info.termsOfService='./terms';document.info.contact={url:'../contact'};document.info.license={name:'License',url:'license.txt'};document.externalDocs={url:'guide.html'};
 document.servers=[{url:'.'},{url:'../{region}/v1',variables:{region:{default:'test'}}}];
 document.paths['/p']={servers:[{url:'../path/'}],get:{servers:[{url:'../operation/'}],responses:{204:{description:'No body'}}}};
 document.components={securitySchemes:{OAuth:{type:'oauth2',flows:{authorizationCode:{authorizationUrl:'authorize',tokenUrl:'token',refreshUrl:'../refresh',scopes:{}}}}},examples:{External:{externalValue:'./payload.txt#part'},Literal:{value:{externalValue:'payload data',url:'literal'}},Ignored:{$ref:'#/components/examples/Literal',externalValue:'ignored-relative-data'}}};
 document['x-data']={externalValue:'payload data',url:'literal'};
 const source=json?JSON.stringify(document):YAML.stringify(document),params={root:physical,outputId,snapshot:'url-bases',resources:[{...resource(physical,source),...(mapped?{aliases:[retrieval]}:{})}]};
 const result=deriveBundle(params),derived=JSON.parse(result.output.text);
 assert.equal(derived.servers[0].url,'https://device.example/contracts/');
 for(const region of ['test','east/west','../other'])assert.equal(new URL(derived.servers[1].url.replace('{region}',region),outputId).href,new URL('../'+region+'/v1',retrieval).href);
 assert.equal(derived.paths['/p'].servers[0].url,'https://device.example/path/');
 assert.equal(derived.paths['/p'].get.servers[0].url,'https://device.example/operation/');
 assert.deepEqual(derived.components.securitySchemes.OAuth,document.components.securitySchemes.OAuth);
 assert.equal(new URL(derived.components.securitySchemes.OAuth.flows.authorizationCode.tokenUrl,derived.paths['/p'].get.servers[0].url).href,'https://device.example/operation/token');
 const base=document.$self??retrieval;
 assert.equal(derived.info.termsOfService,new URL('./terms',base).href);assert.equal(derived.info.contact.url,new URL('../contact',base).href);
 assert.equal(derived.info.license.url,new URL('license.txt',base).href);assert.equal(derived.externalDocs.url,new URL('guide.html',base).href);
 assert.equal(derived.components.examples.External.externalValue,new URL('./payload.txt#part',base).href);
 assert.equal(derived.components.examples.Ignored.externalValue,'ignored-relative-data');
 assert.deepEqual(derived.components.examples.Literal,document.components.examples.Literal);assert.deepEqual(derived['x-data'],document['x-data']);
 assert.equal(derived.$self,document.$self);assert.equal(params.resources[0].text,source);
});
for(const version of ['3.1.2','3.2.1'])for(const servers of [undefined,[]])test(`relocation retains the effective absent/empty Server default ${version} ${JSON.stringify(servers)}`,()=>{
 const document=api(version);if(servers)document.servers=servers;if(version.startsWith('3.2'))document.$self='https://identity.example/description';
 const source=JSON.stringify(document),result=deriveBundle(input(source));
 assert.equal(JSON.parse(result.output.text).servers[0].url,'https://contracts.invalid/');
 assert.equal(JSON.parse(source).servers?.length??0,0);
});
for(const version of ['3.1.2','3.2.1'])test(`security discovery URLs retain their Server context ${version}`,()=>{
 const document=api(version);document.servers=[{url:'https://api.invalid/v1/'}];
 document.components={securitySchemes:{Discovery:{type:'openIdConnect',openIdConnectUrl:'../.well-known/openid-configuration'},OAuth:{type:'oauth2',flows:{clientCredentials:{tokenUrl:'token',scopes:{}}},...(version.startsWith('3.2')?{oauth2MetadataUrl:'oauth-metadata'}:{})}}};
 const source=JSON.stringify(document),result=deriveBundle(input(source)),value=JSON.parse(result.output.text);
 assert.deepEqual(value.components.securitySchemes,document.components.securitySchemes);
 assert.equal(new URL(value.components.securitySchemes.Discovery.openIdConnectUrl,value.servers[0].url).href,'https://api.invalid/.well-known/openid-configuration');
 if(version.startsWith('3.2'))assert.equal(new URL(value.components.securitySchemes.OAuth.oauth2MetadataUrl,value.servers[0].url).href,'https://api.invalid/v1/oauth-metadata');
 assert.equal(input(source).resources[0].text,source);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [true,false])test(`server template ports, schemes, authorities and variable-dependent dot paths retain their meaning ${version} ${json?'JSON':'YAML'}`,()=>{
 const document=api(version);
 document.servers=[
  {url:'https://{username}.example.com:{port}/{basePath}',variables:{username:{default:'demo'},port:{default:'8443'},basePath:{default:'v2'}}},
  {url:'//{host}:{port}/v1',variables:{host:{default:'api.example'},port:{default:'8443'}}},
  {url:'{scheme}://api.example:{port}/v1',variables:{scheme:{default:'https',enum:['http','https']},port:{default:'8443'}}},
  {url:'../prefix/{part}/../tail',variables:{part:{default:'a',enum:['a','a/b','../../c']}}},
  {url:'/api/{part}/../tail',variables:{part:{default:'a',enum:['a','a/b','../../c']}}},
  {url:'/{path}',variables:{path:{default:'v1',enum:['v1','v2']}}},
  {url:'v{version}/api',variables:{version:{default:'1',enum:['1','2']}}},
  {url:'{endpoint}',variables:{endpoint:{default:'https://a.example',enum:['https://a.example','https://b.example']}}},
  {url:'{prefix}://api',variables:{prefix:{default:'{literal}',enum:['{literal}']}}},
  {url:'{empty}',variables:{empty:{default:'',enum:['']}}},
 ];
 const before=JSON.stringify(document),sourceRoot=json?root:root.replace('.json','.yaml'),text=json?before:YAML.stringify(document,{lineWidth:0});
 const params={root:sourceRoot,outputId,snapshot:'server-templates',resources:[resource(sourceRoot,text)]};
 const result=deriveBundle(params),derived=JSON.parse(result.output.text);
 assert.equal(derived.servers[0].url,document.servers[0].url);assert.equal(derived.servers[2].url,document.servers[2].url);
 for(let index=0;index<document.servers.length;index++) {
  const original=document.servers[index],next=derived.servers[index];assert.deepEqual(next.variables,original.variables);
  let assignments=[{}];
  for(const [name,variable]of Object.entries(original.variables))assignments=assignments.flatMap(values=>(variable.enum??[variable.default]).map(value=>({...values,[name]:value})));
  for(const values of assignments) {
   const expand=value=>value.replace(/\{([^}]+)\}/g,(_,name)=>values[name]);
   assert.equal(new URL(expand(next.url),outputId).href,new URL(expand(original.url),sourceRoot).href,'Server '+index+' / '+JSON.stringify(values));
  }
 }
 assert.equal(JSON.stringify(document),before);
 assert.equal(params.resources[0].text,text);
 for(const url of ['{endpoint}','/{path}','v{version}/api']) {
  const name=url.match(/\{([^}]+)\}/)[1],ambiguous=api(version);ambiguous.servers=[{url,variables:{[name]:{default:'v1'}}}];
  const source=JSON.stringify(ambiguous);assert.throws(()=>deriveBundle(input(source)),error=>error.code==='bundle.server.template-context');assert.equal(JSON.stringify(ambiguous),source);
 }
 const mixed=api(version);mixed.servers=[{url:'{endpoint}',variables:{endpoint:{default:'v1',enum:['v1','https://a.example']}}}];
 assert.throws(()=>deriveBundle(input(mixed)),error=>error.code==='bundle.server.template-context');
});
for(const version of ['3.1.2','3.2.1'])test(`derived bundle ${version} retains local OAS dialect roots, aliases and anchor recursion`,async()=>{
 const document=api(version);
 document.components={schemas:{Tree:{$schema:'https://json-schema.org/draft/2020-12/schema',$anchor:'tree',type:'object',properties:{child:{$ref:'#tree'}},examples:[{child:{}},{child:false}]},Explicit:{$id:'../identity/model',type:'integer',examples:[1,'bad']}}};
 const result=deriveBundle(input(document)),value=JSON.parse(result.output.text);
 assert.equal(value.components.schemas.Tree.$schema,document.components.schemas.Tree.$schema);
 assert.equal(value.components.schemas.Explicit.$id,'https://contracts.invalid/identity/model');
 const evaluated=await evaluateSchemas({root:outputId,snapshot:'anchor',resources:[resource(outputId,result.output.text)]});
 assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,false,true,false]);
 assert.equal(result.entryIdentity.source,root);assert.equal(result.entryIdentity.derived,outputId);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`shared explicit root dialect is retained at the compound boundary ${version} ${json?'JSON':'YAML'}`,async()=>{
 const dialect='https://json-schema.org/draft/2020-12/schema',model='https://contracts.invalid/api/models.'+(json?'json':'yaml');
 const document=api(version),external=api(version);
 document.components={schemas:{Use:{$ref:model+'#/components/schemas/Tree',examples:[{value:111,child:{value:111}},{value:222},{value:111,child:{value:222}},{value:111,extra:true}]},Boolean:{$ref:model+'#/components/schemas/Boolean',examples:[null]}}};
 external.jsonSchemaDialect=dialect;
 external.components={schemas:{Tree:{$schema:dialect,$dynamicAnchor:'tree',type:'object',properties:{value:{type:'integer',const:111},child:{$dynamicRef:'#tree'}},required:['value'],unevaluatedProperties:false},Boolean:false,Independent:{$id:'independent',$schema:`https://spec.openapis.org/oas/${version.slice(0,3)}/dialect/base`,type:'string'}}};
 const render=value=>(json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0})).replaceAll('111','9007199254740993').replaceAll('222','9007199254740992');
 const entry=json?root:root.replace('.json','.yaml'),params={root:entry,outputId,snapshot:'shared-root-dialect',resources:[resource(entry,render(document)),resource(model,render(external))]},frozen=params.resources.map(value=>value.text);
 const before=await evaluateSchemas(params);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,false,false,false]);
 const result=deriveBundle(params),tree=result.provenance.find(p=>p.kind==='schema'&&p.source.resource===model&&p.source.pointer==='/components/schemas/Tree');
 const declaration=result.provenance.find(p=>p.kind==='schema-dialect-declaration'&&p.source.resource===model&&p.source.pointer==='/components/schemas/Tree/$schema');
 assert(tree&&declaration);assert.notEqual(declaration.derived.pointer,tree.derived.pointer+'/$schema');
 const derived=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]});
 assert.equal(derived.docs.get(outputId).dataNode(declaration.derived.pointer).value,dialect);
 assert.equal(derived.docs.get(outputId).dataNode(tree.derived.pointer+'/$schema'),undefined);
 const scope=derived.graph.scope(outputId,tree.derived.pointer);assert.equal(scope.base,model);assert.equal(scope.dialect,dialect);
 assert.equal(resolve(result,model,'/components/schemas/Independent').$schema,external.components.schemas.Independent.$schema);
 assert.equal(derived.graph.issues.length,0);assert(result.output.text.includes('9007199254740993'));
 const relocated='file:///independent/space%20%E9%9B%AA/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'relocated-root-dialect',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,false,false,false]);
 assert.equal(deriveBundle({...params,resources:[...params.resources].reverse()}).output.text,result.output.text);
 assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const json of [false,true])test(`retained 3.1 entry dialect keeps its base and dynamic evaluation ${json?'JSON':'YAML'}`,async()=>{
 const dialect='https://json-schema.org/draft/2020-12/schema',entry=json?root:root.replace('.json','.yaml'),document=api('3.1.2');
 document.jsonSchemaDialect=dialect;
 document.components={schemas:{Value:{$schema:dialect,$dynamicAnchor:'value',type:'object',properties:{value:{type:'string'},child:{$dynamicRef:'#value'}},required:['value'],unevaluatedProperties:false},Remote:{$ref:'https://schemas.invalid/consumer'}}};
 const consumer={$id:'https://schemas.invalid/consumer',properties:{entry:{$ref:entry+'#/components/schemas/Value'}},examples:[{entry:{value:'good',child:{value:'good'}}},{entry:{value:'good',child:{value:1}}}]};
 const render=value=>json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0}),params={root:entry,outputId,snapshot:'retained-local-dialect',resources:[resource(entry,render(document)),resource(consumer.$id,render(consumer))]},frozen=params.resources.map(value=>value.text);
 const before=await evaluateSchemas(params);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false]);
 const result=deriveBundle(params);assert.equal(Object.hasOwn(JSON.parse(result.output.text),'$self'),false);
 assert(result.provenance.some(p=>p.kind==='schema-dialect-declaration'&&p.source.resource===entry));assert(result.identitiesRetained.includes(entry));
 const relocated='file:///independent/space%20%E9%9B%AA/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'retained-local-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false]);assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`distinct legal unanchored OAS schema-root dialects are not collapsed into one resource ${version} ${json?'JSON':'YAML'}`,async()=>{
 const model='https://contracts.invalid/api/mixed.'+(json?'json':'yaml'),document=api(version),external=api(version);
 document.components={schemas:{A:{$ref:model+'#/components/schemas/A'},B:{$ref:model+'#/components/schemas/B'}}};
 external.components={schemas:{A:{$schema:'https://json-schema.org/draft/2020-12/schema',type:'string',examples:['accepted',1]},B:{type:'string',examples:['accepted',1]}}};
 const render=value=>json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0});
 const params={...input(render(document),[resource(model,render(external))]),root:root.replace('.json',json?'.json':'.yaml')};params.resources[0].id=params.root;
 const frozen=params.resources.map(value=>value.text),context=createGraph(params);
 assert.equal(context.graph.issues.length,0);
 // OAS 3.1 §4.8.24.5 / 3.2 §4.24.7: these are independently
 // embedded root Schema Objects, not schemas nested in another schema.
 // Core §4.3.5 explicitly leaves other-format embedding to that format.
 assert.equal(context.graph.scope(model,'/components/schemas/A').dialect,'https://json-schema.org/draft/2020-12/schema');
 assert.equal(context.graph.scope(model,'/components/schemas/B').dialect,`https://spec.openapis.org/oas/${version.slice(0,3)}/dialect/base`);
 const structural=analyse(params,context);assert.equal(structural.complete,true);assert(!structural.findings.some(f=>f.severity==='error'),JSON.stringify(structural.findings));
 const evaluated=await evaluateSchemas(params,undefined,context);assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));
 assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,false,true,false]);
 assert(evaluated.findings.filter(f=>f.code==='example.schema.incompatible').length===2);
 assert(!evaluated.findings.some(f=>['schema.keyword.invalid','schema.dialect.location'].includes(f.code)));
 assert.throws(()=>deriveBundle(params),error=>error.code==='bundle.dialect.boundary');assert.deepEqual(params.resources.map(value=>value.text),frozen);
 const invalid=structuredClone(external);invalid.components.schemas.A.properties={nested:{$schema:'https://json-schema.org/draft/2020-12/schema',type:'integer'}};
 const negative={...params,resources:[params.resources[0],resource(model,render(invalid))]};
 assert(analyse(negative).findings.some(f=>f.code==='schema.dialect.location'&&f.pointer==='/components/schemas/A/properties/nested/$schema'));
 assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])test(`an identified sibling keeps its implicit dialect when the compound boundary selects another ${version}`,async()=>{
 const document=api(version),external=api(version),model='https://contracts.invalid/api/siblings.json';
 document.components={schemas:{Use:{$ref:model+'#/components/schemas/A',examples:['good',123]}}};
 external.components={schemas:{A:{$schema:'https://json-schema.org/draft/2020-12/schema',type:'string'},B:{$id:'identified',type:'integer',examples:[1,'wrong']}}};
 const params=input(document,[resource(model,JSON.stringify(external))]),frozen=params.resources.map(value=>value.text),before=await evaluateSchemas(params);
 assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,true,false]);
 const result=deriveBundle(params),original=createGraph(params).graph,derived=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]}).graph;
 const mapped=result.provenance.find(p=>p.kind==='schema'&&p.source.resource===model&&p.source.pointer==='/components/schemas/B');
 assert.equal(derived.scope(outputId,mapped.derived.pointer).dialect,original.scope(model,'/components/schemas/B').dialect);
 assert.equal(resolve(result,model,'/components/schemas/B').$schema,`https://spec.openapis.org/oas/${version.slice(0,3)}/dialect/base`);
 const after=await evaluateSchemas({root:outputId,snapshot:'identified-sibling',resources:[resource(outputId,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,true,false]);assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`standalone implicit dialect does not inherit the destination default ${version} ${json?'JSON':'YAML'}`,async()=>{
 const entry=json?root:root.replace('.json','.yaml'),model='https://contracts.invalid/api/model.'+(json?'json':'yaml'),document=api(version);
 document.jsonSchemaDialect='https://json-schema.org/draft/2020-12/schema';
 document.components={schemas:{Use:{$ref:model,examples:[{value:'good',nested:111},{value:123,nested:111},{value:'good',nested:222}]}}};
 const schema={$id:'https://models.invalid/root',type:'object',properties:{value:{type:'string'},nested:{$id:'nested',type:'integer',const:111}},required:['value','nested'],unevaluatedProperties:false};
 const render=value=>(json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0})).replaceAll('111','9007199254740993').replaceAll('222','9007199254740992'),params={root:entry,outputId,snapshot:'implicit-dialect',resources:[resource(entry,render(document)),resource(model,render(schema))]},frozen=params.resources.map(value=>value.text);
 const before=await evaluateSchemas(params);assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,false]);
 const result=deriveBundle(params),original=createGraph(params).graph,derived=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]}).graph;
 const mapped=result.provenance.find(p=>p.kind==='schema'&&p.source.resource===model&&p.source.pointer==='');assert(mapped);
 for(const pointer of ['','/properties/nested']) {
  assert.equal(derived.scope(outputId,mapped.derived.pointer+pointer).dialect,original.scope(model,pointer).dialect);
  assert.equal(derived.scope(outputId,mapped.derived.pointer+pointer).base,original.scope(model,pointer).base);
 }
 assert.equal(JSON.parse(result.output.text).jsonSchemaDialect,document.jsonSchemaDialect);
 assert.equal(resolve(result,model,'').$schema,`https://spec.openapis.org/oas/${version.slice(0,3)}/dialect/base`);
 assert(result.provenance.some(p=>p.kind==='effective-schema-dialect'&&p.source.resource===model));
 const relocated='file:///independent/space%20%E9%9B%AA/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'implicit-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,false]);assert.deepEqual(params.resources.map(value=>value.text),frozen);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])for(const identified of [false,true])test(`external dual data/schema ${version} ${json} ${identified} keeps both meanings and exact relocated outcomes`,async()=>{
 const entry=api(version),model=root.replace('root.json',json?'model.json':'model.yaml');
 entry.components={schemas:{Use:{$ref:model+'#/Example/value',examples:identified?[{value:'accepted',child:{value:'accepted'}},{value:'accepted',child:{value:123}}]:['accepted',123]}},examples:{Payload:{$ref:model+'#/Example'}}};
 // Recursion consumes an instance property rather than evaluating an
 // unproductive same-instance cycle. The literal Example remains opaque.
 const literal=identified?{$id:'https://identities.invalid/dual',$dynamicAnchor:'node',type:'object',properties:{value:{type:'string',const:'accepted'},child:{$dynamicRef:'#node'}},required:['value'],unevaluatedProperties:false,'x-count':111}:{$ref:'#/Value','x-count':111};
 const data={Example:{summary:'Unchanged literal schema-shaped data',value:literal},Value:{type:'string',const:'accepted'}};
 const render=value=>(json?JSON.stringify(value):YAML.stringify(value,{lineWidth:0})).replaceAll('111','9007199254740993.00');
 const captured=input(entry,[resource(model,render(data))]),frozen=captured.resources.map(value=>value.text),before=await evaluateSchemas(captured);
 assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(value=>value.valid),[true,false]);
 const result=deriveBundle(captured),derived=new (require('./dist/document.cjs').SourceDocument)(result.output.text,outputId);
 const semantic=result.provenance.find(value=>value.kind==='schema'&&value.source.resource===model&&value.source.pointer==='/Example/value');
 const payload=result.provenance.find(value=>value.kind==='literal-data-occurrence'&&value.source.resource===model&&value.source.pointer==='/Example/value');
 assert(semantic&&payload);assert.notEqual(semantic.derived.pointer,payload.derived.pointer);
 const original=new (require('./dist/document.cjs').SourceDocument)(frozen[1],model);
 assert.equal(derived.dataJson(payload.derived.pointer),original.dataJson('/Example/value'));
 assert.equal(derived.dataJson(payload.derived.pointer+'/x-count'),'9007199254740993.00');
 const graph=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]}).graph;
 assert.equal(graph.issues.length,0);assert.equal(graph.references.find(value=>value.pointer==='/components/schemas/Use').targetPointer,semantic.derived.pointer);
 assert(!graph.references.some(value=>value.pointer.startsWith(payload.derived.pointer+'/')||value.pointer===payload.derived.pointer));
 const relocated='file:///offline/space%20%E9%9B%AA/openapi.json',after=await evaluateSchemas({root:relocated,snapshot:'external-dual-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(value=>value.valid),[true,false]);
 assert.deepEqual(captured.resources.map(value=>value.text),frozen);assert.equal(deriveBundle(captured).output.text,result.output.text);
});
for(const version of ['3.1.2','3.2.1'])test(`dual entry data/schema occurrences retain literal data and a distinct proved schema destination ${version}`,()=>{
 const document=api(version);
 document.components={schemas:{Literal:{const:{$ref:'#/components/schemas/Value'}},Consumer:{$ref:'#/components/schemas/Literal/const'},Value:{type:'string'}}};
 const preserved=deriveBundle(input(document));
 assert.deepEqual(JSON.parse(preserved.output.text).components.schemas.Literal.const,document.components.schemas.Literal.const);
 assert.equal(document.components.schemas.Literal.const.$ref,'#/components/schemas/Value');
 document.components.schemas.Literal.const.$ref=root+'#/components/schemas/Value';
 const captured=input(document),result=deriveBundle(captured),value=JSON.parse(result.output.text);
 assert.deepEqual(value.components.schemas.Literal.const,document.components.schemas.Literal.const);
 assert(!value.components.schemas.Consumer.$ref.includes('/Literal/const'));
 const after=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]});
 const target=after.graph.references.find(ref=>ref.pointer==='/components/schemas/Consumer');
 assert.equal(target.resolution,'resolved');
 const semantic=result.provenance.find(p=>p.kind==='schema'&&p.source.pointer==='/components/schemas/Literal/const');
 assert.equal(target.targetPointer,semantic.derived.pointer);
 assert.equal(after.docs.get(outputId).node(target.targetPointer).value.$ref,'#/components/schemas/Value');
 assert(result.provenance.some(p=>p.kind==='literal-data-occurrence'&&p.source.pointer==='/components/schemas/Literal/const'));
 assert.equal(captured.resources[0].text,JSON.stringify(document));
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`dual entry data/schema ${version} ${json} keeps exact literal equality and relocated validation`,async()=>{
 const id=root.replace('.json',json?'.json':'.yaml'),document=api(version);
 const literal={$ref:id+'#/components/schemas/Value','x-count':111};
 document.components={schemas:{Literal:{const:literal,examples:[literal,{...literal,'x-count':222}]},Consumer:{$ref:'#/components/schemas/Literal/const',examples:['accepted',123]},Value:{type:'string',const:'accepted'}}};
 const text=(json?JSON.stringify(document):YAML.stringify(document)).replaceAll('111','9007199254740993.00').replaceAll('222','9007199254740992');
 const captured={...input(text),root:id,resources:[resource(id,text)]};
 const before=await evaluateSchemas(captured);assert.equal(before.complete,true,JSON.stringify(before.findings));
 assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,true,false]);
 const result=deriveBundle(captured),after=createGraph({root:outputId,resources:[resource(outputId,result.output.text)]});
 assert.equal(after.docs.get(outputId).dataJson('/components/schemas/Literal/const/x-count'),'9007199254740993.00');
 assert.equal(after.docs.get(outputId).dataNode('/components/schemas/Literal/const/$ref').value,literal.$ref);
 const relocated='file:///offline/space%20%E9%9B%AA/openapi.json';
 const checked=await evaluateSchemas({root:relocated,snapshot:'dual-relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert.deepEqual(checked.evaluations.map(e=>e.valid),[true,false,true,false]);
 assert.equal(captured.resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])test(`derived bundle ${version} local references survive a different retrieval location`,async()=>{
 const document=api(version);document.components={schemas:{Value:{type:'string'},Recursive:{$anchor:'recursive',type:'object',properties:{value:{$ref:'#/components/schemas/Value'},child:{$ref:'#recursive'}},examples:[{value:'good',child:{}},{value:42}]}}};
 const result=deriveBundle(input(document));
 const value=JSON.parse(result.output.text);
 assert.equal(value.components.schemas.Recursive.properties.value.$ref,'#/components/schemas/Value');
 assert.equal(value.components.schemas.Recursive.properties.child.$ref,'#recursive');
 const relocated='file:///relocated/space%20%E9%9B%AA/openapi.json';
 const evaluated=await evaluateSchemas({root:relocated,snapshot:'relocated',resources:[resource(relocated,result.output.text)]});
 assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,false]);
});
test('cross-resource entry identities survive relocation without inventing $self in 3.1',async()=>{
 for(const version of ['3.1.2','3.2.1'])for(const json of [true,false]) {
  const entry=json?root:'file:///project/space%20%E9%9B%AA/root.yaml';
  const document=api(version);document.components={schemas:{Value:{type:'string'},Remote:{$ref:'https://schemas.invalid/remote'}}};
  const external=resource('https://schemas.invalid/remote',JSON.stringify({$id:'https://schemas.invalid/remote',type:'object',properties:{value:{$ref:entry+'#/components/schemas/Value'}},examples:[{value:'good'},{value:42}]}));
  const captured={root:entry,outputId,snapshot:'entry-resource',resources:[resource(entry,json?JSON.stringify(document):YAML.stringify(document)),external]};
  const original=captured.resources.map(r=>r.text);
  const before=await evaluateSchemas(captured);
  assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false]);
  const result=deriveBundle(captured),derived=JSON.parse(result.output.text);
  assert.deepEqual(captured.resources.map(r=>r.text),original);
  if(version.startsWith('3.1')) {
   assert.equal(Object.hasOwn(derived,'$self'),false);
   assert(result.identitiesRetained.includes(entry));
   for(const name of Object.keys(derived.components.schemas))assert.match(name,/^[A-Za-z0-9._-]+$/);
   assert.equal(resolve(result,entry,'/components/schemas/Value').type,'string');
   const occurrence=result.provenance.find(p=>p.kind==='schema-reference-occurrence'&&p.source.resource===entry&&p.source.pointer==='/components/schemas/Value');
   assert.equal(occurrence.derived.pointer,'/components/schemas/Value');
  }else assert.equal(derived.$self,entry);
  const relocated='file:///relocated/space%20%E9%9B%AA/openapi.json';
  const evaluated=await evaluateSchemas({root:relocated,snapshot:'relocated',resources:[resource(relocated,result.output.text)]});
  assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,false]);
 }
});
for(const version of ['3.1.2','3.2.1'])test(`derived YAML alias occurrences retain distinct schema/data context ${version}`,async()=>{
 const rootId='https://contracts.invalid/api/root.yaml',externalId='https://contracts.invalid/api/model.yaml';
 const text=`# untouched 😀\r\nopenapi: ${version}\r\ninfo: {title: Alias, version: '1'}\r\npaths: {}\r\nx-template: &template\r\n  type: object\r\n  properties:\r\n    value: {type: integer, minimum: 9007199254740993}\r\n    recursive: {$ref: '#/components/schemas/Alias'}\r\n  examples: [{value: 9007199254740993}, {value: 9007199254740992}]\r\ncomponents:\r\n  schemas:\r\n    Alias: *template\r\n    Remote: {$ref: 'model.yaml#/Target'}\r\n`;
 const external=`x-template: &template\n  type: object\n  properties:\n    child: {$ref: '${rootId}#/components/schemas/Alias'}\n  examples: [{child: {value: 9007199254740993}}, {child: {value: 9007199254740992}}]\nTarget: *template\n`;
 const captured={root:rootId,outputId,snapshot:'alias-bundle',resources:[resource(rootId,text),resource(externalId,external)]};
 const before=await evaluateSchemas(captured);
 assert.equal(before.complete,true,JSON.stringify(before.findings));
 assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,true,false]);
 const result=deriveBundle(captured),value=JSON.parse(result.output.text);
 assert.deepEqual(value['x-template'],YAML.parse(text)['x-template']);
 assert.equal(captured.resources[0].text,text);assert.equal(captured.resources[1].text,external);
 assert(result.output.text.includes('9007199254740993'));
 const evaluated=await evaluateSchemas({root:outputId,snapshot:'alias-derived',resources:[resource(outputId,result.output.text)]});
 assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));
 assert.deepEqual(evaluated.evaluations.map(e=>e.valid),[true,false,true,false]);
 const mapped=result.provenance.find(p=>p.source.resource===rootId&&p.source.pointer==='/components/schemas/Alias/properties/recursive');
 assert(mapped);assert.equal(mapped.source.physicalPointer,'/x-template/properties/recursive');
 assert.equal(text.slice(...mapped.source.occurrenceRange),'*template');
 assert(text.slice(...mapped.source.range).includes('$ref'));
});
for(const version of ['3.1.2','3.2.1'])test(`derived aliases keep different nested base targets ${version}`,async()=>{
 const text=`openapi: ${version}\ninfo: {title: Bases, version: '1'}\npaths: {}\nx-template: &template\n  type: object\n  properties:\n    value: {$ref: 'value.json'}\ncomponents:\n  schemas:\n    A:\n      $id: https://schemas.invalid/a/base\n      allOf: [*template]\n      examples: [{value: A}, {value: B}]\n    B:\n      $id: https://schemas.invalid/b/base\n      allOf: [*template]\n      examples: [{value: B}, {value: A}]\n`;
 const captured=input(text,[resource('https://schemas.invalid/a/value.json','{"const":"A"}'),resource('https://schemas.invalid/b/value.json','{"const":"B"}')]);
 captured.root=captured.resources[0].id=root.replace('.json','.yaml');
 const before=await evaluateSchemas(captured);assert.equal(before.complete,true,JSON.stringify(before.findings));
 assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,true,false]);
 const result=deriveBundle(captured),value=JSON.parse(result.output.text);
 assert.equal(value['x-template'].properties.value.$ref,'value.json');
 assert.notEqual(value.components.schemas.A.allOf[0].properties.value.$ref,value.components.schemas.B.allOf[0].properties.value.$ref);
 const after=await evaluateSchemas({root:outputId,snapshot:'different-alias-bases',resources:[resource(outputId,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,true,false]);
 assert.equal(captured.resources[0].text,text);
});
test('resource acquisition order cannot change bundled content or source provenance',()=>{
 const document=api('3.2.1');document.components={schemas:{First:{$ref:'https://models.invalid/one#/Item'},Second:{$ref:'https://models.invalid/two#/Item'}}};
 const one=resource('https://models.invalid/one',JSON.stringify({Item:{type:'string'}})),two=resource('https://models.invalid/two',JSON.stringify({Item:{type:'integer'}}));
 const original=input(document,[one,two]),reordered={...original,resources:[two,...original.resources.slice(0,2)]};
 const first=deriveBundle(original),second=deriveBundle(reordered);
 assert.equal(first.output.text,second.output.text);assert.deepEqual(first.provenance,second.provenance);assert.deepEqual(first.sourceResources,second.sourceResources);
});
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`entry resource bundle ${version} ${json} keeps dynamic anchors, nested ids, booleans and exact equality`,async()=>{
 const entry='file:///approved/space%20%E9%9B%AA/entry.'+(json?'json':'yaml');
 const document=api(version);document.components={schemas:{
  Value:{$dynamicAnchor:'value',allOf:[{type:'integer'},{const:111}],'x-preserved':{$ref:'literal payload',n:111}},
  Never:false,Nested:{$id:'nested/base',type:'object',properties:{q:{$ref:'part'}},required:['q']},
  Part:{$id:'nested/part',type:'string',const:'kept'},Remote:{$ref:'https://schemas.invalid/entry-consumer'},
 }};
 const remote={$id:'https://schemas.invalid/entry-consumer',type:'object',required:['value'],properties:{
  value:{$dynamicRef:entry+'#value'},nested:{$ref:entry+'#/components/schemas/Nested'},never:{$ref:entry+'#/components/schemas/Never'},
 },examples:[{value:111,nested:{q:'kept'}},{value:222,nested:{q:'kept'}},{value:111,never:1},{value:111,nested:{q:'wrong'}}]};
 const render=value=>(json?JSON.stringify(value):YAML.stringify(value)).replaceAll('111','9007199254740993.00').replaceAll('222','9007199254740992');
 const captured={root:entry,outputId,snapshot:'entry-advanced',resources:[resource(entry,render(document)),resource(remote.$id,JSON.stringify(remote).replaceAll('111','9007199254740993.00').replaceAll('222','9007199254740992'))]};
 const before=await evaluateSchemas(captured);
 assert.equal(before.complete,true,JSON.stringify(before.findings));assert.deepEqual(before.evaluations.map(e=>e.valid),[true,false,false,false]);
 const frozen=captured.resources.map(r=>r.text),result=deriveBundle(captured);
 assert.deepEqual(captured.resources.map(r=>r.text),frozen);
 assert(result.output.text.includes('9007199254740993.00'));
 assert(result.output.text.includes('"$ref":"literal payload"'));
 for(const id of ['file:///approved/space%20%E9%9B%AA/nested/base','file:///approved/space%20%E9%9B%AA/nested/part'])assert(result.identitiesRetained.includes(id));
 const relocated='file:///unrelated/another%20%E9%9B%AA/openapi.json';
 const after=await evaluateSchemas({root:relocated,snapshot:'relocated-advanced',resources:[resource(relocated,result.output.text)]});
 assert.equal(after.complete,true,JSON.stringify(after.findings));assert.deepEqual(after.evaluations.map(e=>e.valid),[true,false,false,false]);
 assert.equal(resolve(result,entry,'/components/schemas/Never'),false);
});
