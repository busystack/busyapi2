const assert=require('node:assert/strict');
const {test}=require('node:test');
const {referenceDisplay:prepareDisplay}=require('./dist/reference_display.cjs');
const referenceDisplay=(input,outputId)=>prepareDisplay({...input,outputId});
const {analyse}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {deriveBundle}=require('./dist/derived_bundle.cjs');
const {mixed}=require('../../fixtures/compatibility/reference_display.cjs');
const output='https://display.invalid/reference.json';
test('the versioned display wire packet round-trips exact text rather than authored numbers',()=>{
 const {referenceDisplayPacket}=require('./dist/reference_display.cjs'),input=mixed('3.2.1');
 const packet=referenceDisplayPacket({...input,outputId:output});
 assert.equal(packet.version,1);assert.equal(packet.producer,'busyapi-reference-display-packet');assert.equal(packet.encoding,'json');
 const decoded=JSON.parse(packet.content);assert.deepEqual(decoded,referenceDisplay(input,output));
 assert(decoded.output.text.includes('9007199254740993.00'));
});
for(const family of ['31','32'])test(`an ordinary external definition container is not mistaken for literal payload ${family}`,async()=>{
 const fs=require('node:fs'),path=require('node:path'),root='https://contracts.invalid/root.json',external='https://contracts.invalid/schema.json';
 const resources=[{id:root,text:fs.readFileSync(path.join(__dirname,`../../fixtures/compatibility/oas${family}.json`),'utf8'),generation:1},{id:external,text:fs.readFileSync(path.join(__dirname,'../../fixtures/compatibility/schema.json'),'utf8'),generation:1}];
 const result=referenceDisplay({root,resources,snapshot:'rich-container-'+family},output);
 const container=result.original.sections.find(section=>section.source.resource===external&&section.source.pointer==='');
 assert.equal(container.entries.find(entry=>entry.name==='Thing').kind,'schema');
 assert.equal(container.entries.find(entry=>entry.name==='Thing').target.pointer,'/Thing');
 const {graphAddressedDisplay}=await import('../documentation_renderers/graph_display.mjs');
 const display=graphAddressedDisplay(result.output.text,result.projection,'https://display.invalid/index.html',{addresses:'document-pointer'});
 const recursive=display.referenceOrigins.find(reference=>reference.authored==='#/Thing');
 assert(recursive);assert.equal(recursive.source.resource,output);
 assert.equal(recursive.target.pointer,result.provenance.find(record=>record.kind==='schema'&&record.source.resource===external&&record.source.pointer==='/Thing').derived.pointer);
 assert.deepEqual(resources.map(resource=>resource.text),[...resources].map(resource=>fs.readFileSync(path.join(__dirname,resource.id===root?`../../fixtures/compatibility/oas${family}.json`:'../../fixtures/compatibility/schema.json'),'utf8')));
});
for(const version of ['3.1.2','3.2.1'])for(const pathItem of [false,true])test(`mixed legal dialects have exact graph-addressed display coordinates, not an altered API bundle ${version} pathItem=${pathItem}`,async()=>{
 const input=mixed(version,{pathItem}),before=JSON.stringify(input);
 const checked=analyse(input);assert.equal(checked.status,'complete');assert.deepEqual(checked.findings,[]);
 const evaluated=await evaluateSchemas(input);assert.equal(evaluated.complete,true);assert(!evaluated.findings.some(f=>f.severity==='error'));
 assert.throws(()=>deriveBundle({...input,outputId:output}),error=>error.code==='bundle.dialect.boundary');
 const result=referenceDisplay(input,output),spec=JSON.parse(result.output.text);
 assert.equal(JSON.stringify(input),before);assert.equal(result.representation,'graph-addressed-display-only');
 assert.deepEqual(spec['x-busyapi-display-resources'],{must:'remain authored'});
 assert(result.output.text.includes('9007199254740993.00'));
 for(const original of result.original.sections) {
  const record=result.provenance.find(p=>p.kind===original.kind&&p.source.resource===original.source.resource&&p.source.pointer===original.source.pointer);
  assert(record,'Every semantic node retains original provenance');
  const copy=result.projection.sections.find(s=>s.source.pointer===record.derived.pointer);
  assert(copy);assert.equal(copy.dialect,original.dialect);
  assert.deepEqual(copy.references.map(r=>r.value),original.references.map(r=>r.value));
 }
 const imported=result.projection.sections.filter(s=>s.kind==='schema'&&s.source.pointer.startsWith('/x-busyapi-display-resources-'));
 assert(imported.some(s=>s.dialect==='https://json-schema.org/draft/2020-12/schema'));
 assert(imported.some(s=>s.dialect===`https://spec.openapis.org/oas/${version.startsWith('3.2')?'3.2':'3.1'}/dialect/base`));
 const {graphAddressedDisplay}=await import('../documentation_renderers/graph_display.mjs');
 const presentation=graphAddressedDisplay(result.output.text,result.projection,'https://display.invalid/index.html',{addresses:'document-pointer'});
 assert.equal(presentation.canonicalText,result.output.text);
 assert(presentation.referenceOrigins.some(r=>r.authored==='models.json#/components/schemas/A'));
 assert.equal(JSON.stringify(input),before);
});
for(const version of ['3.1.2','3.2.1'])test(`a display keeps literal and explicitly referenced schema meanings distinct ${version}`,async()=>{
 const root='https://contracts.invalid/api.json',literal={$ref:root+'#/components/schemas/Value','x-count':111};
 const document={openapi:version,info:{title:'Two meanings',version:'1'},paths:{},components:{schemas:{Literal:{const:literal,examples:[literal]},Consumer:{$ref:'#/components/schemas/Literal/const',examples:['accepted']},Value:{type:'string',const:'accepted'}}}};
 const text=JSON.stringify(document).replaceAll('111','9007199254740993.00'),input={root,snapshot:'dual-presentation-'+version,resources:[{id:root,text,generation:1}]};
 const checked=analyse(input);assert.equal(checked.status,'complete');assert.deepEqual(checked.findings,[]);
 const evaluation=await evaluateSchemas(input);assert.equal(evaluation.complete,true);assert(evaluation.evaluations.every(item=>item.valid));
 const result=referenceDisplay(input,output),{graphAddressedDisplay}=await import('../documentation_renderers/graph_display.mjs');
 const display=graphAddressedDisplay(result.output.text,result.projection,'https://display.invalid/index.html',{addresses:'document-pointer'});
 assert.equal(display.spec.components.schemas.Literal.const.$ref,literal.$ref);
 const consumer=display.referenceOrigins.find(item=>item.source.pointer==='/components/schemas/Consumer/$ref');
 assert(consumer);assert.notEqual(consumer.target.pointer,'/components/schemas/Literal/const');
 const semantic=result.projection.sections.find(section=>section.source.pointer===consumer.target.pointer);
 assert.equal(semantic.kind,'schema');
 assert(result.output.text.includes('9007199254740993.00'));assert.equal(input.resources[0].text,text);
});
for(const version of ['3.1.2','3.2.1'])test(`nested identifiers, dynamic scope, recursion, boolean/composed schemas and implicit connections retain the original graph ${version}`,async()=>{
 const root='file:///approved/physical.json',models='file:///approved/models.json',base='https://schemas.invalid/';
 const tree={$id:base+'tree#',$dynamicAnchor:'node',type:'object',$defs:{'a/b':{$anchor:'leaf',type:'string'},Nested:{$id:'nested',properties:{value:{$ref:'tree#leaf'}}}},properties:{children:{type:'array',items:{$dynamicRef:'#node'}},slash:{$ref:'#/$defs/a~1b'},nested:{$ref:'nested'}}};
 const strict={$id:base+'strict',$dynamicAnchor:'node',$ref:'tree',unevaluatedProperties:false};
 const document={openapi:version,...(version.startsWith('3.2')?{$self:'https://contracts.invalid/api/root'}:{}),info:{title:'Graph content',version:'1'},security:[{Key:[]}],paths:{'/tree':{get:{operationId:'readTree',responses:{200:{description:'Tree',links:{again:{operationId:'readTree'}},content:{'application/json':{schema:{$ref:base+'tree'}}}}}}}},components:{schemas:{Tree:{$ref:models+'#/Tree'},Strict:{$ref:models+'#/Strict'},Boolean:false,Choice:{oneOf:[{$ref:base+'tree'},{type:'null'}],discriminator:{propertyName:'kind',mapping:{tree:'Tree'}}}},securitySchemes:{Key:{type:'apiKey',in:'header',name:'x-key'}}}};
 const model={Tree:tree,Strict:strict};
 const resources=[{id:root,text:JSON.stringify(document),generation:7},{id:models,text:JSON.stringify(model),generation:8}];
 const checked=analyse({root,resources,snapshot:'advanced-display-'+version});assert.equal(checked.complete,true,JSON.stringify(checked.findings));
 const result=referenceDisplay({root,resources,snapshot:'advanced-display-'+version},output);
 const {graphAddressedDisplay}=await import('../documentation_renderers/graph_display.mjs');
 const display=graphAddressedDisplay(result.output.text,result.projection,'https://display.invalid/index.html',{addresses:'document-pointer'});
 const sourceFor=(resource,pointer)=>result.provenance.find(record=>record.kind!=='reference'&&record.source.resource===resource&&record.source.pointer===pointer)?.derived.pointer;
 const dynamic=display.referenceOrigins.find(reference=>reference.dynamic);
 assert(dynamic);assert.equal(dynamic.authored,'#node');assert.equal(dynamic.display,'#node');
 assert.deepEqual(dynamic.dynamic.candidates.map(value=>value.pointer).sort(),[sourceFor(models,'/Strict'),sourceFor(models,'/Tree')].sort());
 const escaped=display.referenceOrigins.find(reference=>reference.authored==='#/$defs/a~1b');
 assert.equal(escaped.target.pointer,sourceFor(models,'/Tree/$defs/a~1b'));
 for(const connection of ['security','operationId','discriminator'])assert(display.referenceOrigins.some(reference=>reference.connection===connection));
 const copied=JSON.parse(result.output.text),at=pointer=>pointer.split('/').slice(1).reduce((value,part)=>value[part.replaceAll('~1','/').replaceAll('~0','~')],copied);
 assert.deepEqual(at(sourceFor(models,'/Tree')),tree);
 assert.deepEqual(at(sourceFor(models,'/Strict')),strict);
 assert.equal(at(sourceFor(root,'/components/schemas/Boolean')),false);
 if(version.startsWith('3.2'))assert.equal(copied.$self,document.$self);
 assert.deepEqual(resources.map(resource=>resource.text),[JSON.stringify(document),JSON.stringify(model)]);
});
test('YAML aliases retain occurrence and physical provenance in read-only coordinates',async()=>{
 const root='file:///approved/alias.yaml',text=`# retained source\r\nopenapi: 3.2.1\ninfo: {title: Alias, version: '1'}\npaths: {}\ncomponents:\n  schemas:\n    Base: &base\n      type: object\n      properties:\n        recursive: {$ref: '#/components/schemas/Base'}\n      examples: [{number: 9007199254740993.00}]\n    Alias: *base\n`;
 const input={root,snapshot:'alias-display',resources:[{id:root,text,generation:3}]},result=referenceDisplay(input,output);
 const alias=result.provenance.find(record=>record.kind==='schema'&&record.source.pointer==='/components/schemas/Alias');
 assert.equal(alias.source.physicalPointer,'/components/schemas/Base');assert(alias.source.occurrenceRange);
 const {graphAddressedDisplay}=await import('../documentation_renderers/graph_display.mjs');
 const display=graphAddressedDisplay(result.output.text,result.projection,'https://display.invalid/index.html',{addresses:'document-pointer'});
 assert(display.referenceOrigins.some(reference=>reference.source.pointer==='/components/schemas/Alias/properties/recursive/$ref'));
 assert(result.output.text.includes('9007199254740993.00'));assert.equal(input.resources[0].text,text);
});
test('display identity, missing resources, ambiguity and unsupported dialects fail rather than producing partial presentation',()=>{
 const input=mixed('3.2.1');
 for(const id of [input.root,'file:///display.json','https://display.invalid/reference.json#fragment','https://user:password@display.invalid/reference.json','https://display.invalid/reference.json?remote=true'])
  assert.throws(()=>referenceDisplay(input,id),error=>error.code==='documentation.display-input');
 assert.throws(()=>referenceDisplay({...input,resources:input.resources.slice(0,1)},output),error=>error.code==='documentation.incomplete');
 const root='https://contracts.invalid/ambiguous.json';
 for(const schemas of [{A:{$id:'https://schemas.invalid/same'},B:{$id:'https://schemas.invalid/same'}},{Custom:{$schema:'https://custom.invalid/dialect',type:'string'}}]) {
  const document={openapi:'3.2.1',info:{title:'Incomplete',version:'1'},paths:{},components:{schemas}};
  assert.throws(()=>referenceDisplay({root,snapshot:'incomplete',resources:[{id:root,text:JSON.stringify(document),generation:1}]},output),error=>error.code==='documentation.incomplete');
 }
});
