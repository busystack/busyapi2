const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {createHash}=require('node:crypto');
const {planMigration}=require('./dist/migration.cjs');
const modern=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const forms=['reference','dynamic-pointer','static-anchor','one-anchor','external-root','external-anchor','external-dynamic'];
function captured(input){for(const resource of input.resources)resource.identity=createHash('sha256').update(resource.text).digest('hex');input.snapshot=createHash('sha256').update(JSON.stringify([input.root,input.resources.map(resource=>[resource.id,resource.generation,resource.identity])])).digest('hex');return input;}
function packet(version,format,kind,state='required',name='kind'){
 const root='file:///approved/api.'+format,remote='file:///approved/base.'+format,external=kind.startsWith('external-');
 const base={type:'object',...(state==='required'?{required:[name]}:{}),properties:Object.fromEntries([[name,{type:'string'}]])};
 if(['static-anchor','external-anchor'].includes(kind))base.$anchor='base';
 if(['one-anchor','external-dynamic'].includes(kind))base.$dynamicAnchor='base';
 const reference={[kind==='reference'?'$ref':'$dynamicRef']:(external?'base.'+format:'')+(kind==='external-root'?'':kind.includes('anchor')||kind==='external-dynamic'?'#base':'#/components/schemas/Base')};
 const document={openapi:version,info:{title:'Keep 雪',version:'unrelated-api-version'},paths:{},components:{schemas:{...(external?{}:{Base:base}),Subject:{allOf:[reference],discriminator:{propertyName:name,...(state==='default'?{defaultMapping:'Fallback'}:{})}},Fallback:{type:'object'}}},'x-number':'EXACT','x-payload':{$dynamicRef:'missing.yaml',discriminator:{propertyName:'decoy'},allOf:[{$ref:'missing.json'}]}};
 const encode=value=>(format==='yaml'?'# Keep CRLF and exact literals\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
 return captured({root,resources:[{id:root,text:encode(document),generation:3},...(external?[{id:remote,text:encode(base),generation:4}]:[])]});
}
function edit(input,change){const value=YAML.parse(input.resources[0].text);change(value);input.resources[0].text=input.root.endsWith('.yaml')?'# Keep changed fixture\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value);input.resources[0].generation++;return captured(input);}
async function checked(input){const before=input.resources.map(resource=>resource.text),structural=analyse(input),schema=await evaluateSchemas(input);assert.deepEqual(input.resources.map(resource=>resource.text),before);return {structural,schema};}
const code=(result,name)=>result.findings.filter(finding=>finding.code===name);
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const kind of forms)for(const state of ['required','optional','default'])test(`${version} ${format} ${kind} retains ${state} discriminator presence semantics`,async()=>{
 const input=packet(version,format,kind,state),{structural,schema}=await checked(input);assert.equal(structural.status,'complete',JSON.stringify(structural.findings));assert.equal(schema.complete,true,JSON.stringify(schema.findings));
 const errors=schema.findings.filter(finding=>finding.severity==='error');
 if(state==='optional'){assert.equal(errors.length,1,JSON.stringify(schema.findings));assert.equal(errors[0].code,'discriminator.default-mapping.required');assert.equal(errors[0].resource,input.root);assert.equal(errors[0].pointer,'/components/schemas/Subject/discriminator');assert(errors[0].range[1]>errors[0].range[0]);}
 else assert.deepEqual(errors,[]);
 assert.equal(code(schema,'discriminator.required.incomplete').length,0);
 assert(input.resources[0].text.includes('9007199254740993.00'));assert(!schema.findings.some(finding=>finding.pointer.startsWith('/x-payload')));
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const name of ['','__proto__','constructor','雪/~😀'])test(`${version} ${format} required inheritance preserves property ${JSON.stringify(name)}`,async()=>{
 const {schema}=await checked(packet(version,format,'dynamic-pointer','required',name));assert.equal(schema.complete,true,JSON.stringify(schema.findings));assert(!schema.findings.some(finding=>finding.severity==='error'),JSON.stringify(schema.findings));
});
for(const version of modern)for(const format of ['yaml','json'])for(const kind of ['dynamic-pointer','static-anchor','one-anchor'])test(`${version} ${format} ${kind} establishes a discriminator parent through allOf`,async()=>{
 const input=edit(packet(version,format,kind),value=>{value.components.schemas.Base.discriminator=value.components.schemas.Subject.discriminator;delete value.components.schemas.Subject.discriminator;});
 const {structural,schema}=await checked(input);assert.equal(structural.status,'complete',JSON.stringify(structural.findings));assert.equal(schema.complete,true,JSON.stringify(schema.findings));assert(!schema.findings.some(finding=>finding.severity==='error'),JSON.stringify(schema.findings));
});
for(const version of modern)for(const format of ['yaml','json'])for(const mode of ['missing','dynamic','unresolved'])test(`${version} ${format} ${mode} discriminator parent proof retains certainty and source ownership`,async()=>{
 const input=edit(packet(version,format,'one-anchor'),value=>{
  const schemas=value.components.schemas;schemas.Base.discriminator=schemas.Subject.discriminator;delete schemas.Subject.discriminator;
  if(mode==='missing')delete schemas.Subject;
  if(mode==='dynamic')schemas.Peer={$id:'other',$dynamicAnchor:'base',type:'object'};
  if(mode==='unresolved')schemas.Subject.allOf=[{$dynamicRef:'missing.yaml#base'}];
 });
 const {structural,schema}=await checked(input),expected=mode==='missing'?'discriminator.composition':'discriminator.composition.incomplete';
 for(const result of [structural,schema]){
  const findings=code(result,expected);assert.equal(findings.length,1,JSON.stringify(result.findings));assert.equal(findings[0].resource,input.root);assert.equal(findings[0].pointer,'/components/schemas/Base/discriminator');assert.equal(findings[0].severity,mode==='missing'?'error':'warning');
 }
 if(mode!=='missing'){assert.equal(structural.status,'incomplete',JSON.stringify(structural.findings));assert.equal(schema.complete,false);assert.equal(code(schema,'discriminator.composition').length,0);}
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const required of ['$ref','$dynamicRef','neither'])test(`${version} ${format} both schema reference applicators preserve required proof from ${required}`,async()=>{
 const input=edit(packet(version,format,'dynamic-pointer',required==='$dynamicRef'?'required':'optional'),value=>{value.components.schemas.Neutral={type:'object',...(required==='$ref'?{required:['kind']}:{})};value.components.schemas.Subject.allOf[0].$ref='#/components/schemas/Neutral';});
 const {schema}=await checked(input);assert.equal(schema.complete,true,JSON.stringify(schema.findings));assert.equal(code(schema,'discriminator.default-mapping.required').length,required==='neither'?1:0);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const composition of ['allOf','anyOf','oneOf'])for(const allRequired of [false,true])test(`${version} ${format} inherited ${composition} requires the correct branches required=${allRequired}`,async()=>{
 const input=edit(packet(version,format,'dynamic-pointer'),value=>{value.components.schemas.Base={[composition]:[{type:'object',required:['kind'],properties:{kind:{const:'a'}}},{type:'object',...(allRequired?{required:['kind']}:{}),properties:{kind:{const:'b'}}}]};});
 const {schema}=await checked(input);assert.equal(schema.complete,true,JSON.stringify(schema.findings));assert.equal(code(schema,'discriminator.default-mapping.required').length,!allRequired&&composition!=='allOf'?1:0);
});
for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])for(const form of ['chain','escaped-pointer','resource-id','recursive','static-with-peer','dynamic-peer','unsupported-dialect','bounded-absence'])test(`${version} ${format} discriminator ${form} keeps captured semantics`,async()=>{
 const input=edit(packet(version,format,form==='static-with-peer'?'static-anchor':form==='dynamic-peer'?'one-anchor':'dynamic-pointer'),value=>{
  const schemas=value.components.schemas;
  if(form==='chain'){schemas.Alias={$dynamicRef:'#/components/schemas/Base'};schemas.Subject.allOf=[{$dynamicRef:'#/components/schemas/Alias'}];}
  if(form==='escaped-pointer'){schemas.Base={$defs:{'雪/~':schemas.Base}};schemas.Subject.allOf=[{$dynamicRef:'#/components/schemas/Base/$defs/%E9%9B%AA~1~0'}];}
  if(form==='resource-id'){schemas.Base.$id='base-resource';schemas.Subject.allOf=[{$dynamicRef:'base-resource'}];}
  if(form==='recursive'){schemas.Base.$dynamicAnchor='base';schemas.Base.properties.children={type:'array',items:{$dynamicRef:'#base'}};}
  if(form==='static-with-peer'||form==='dynamic-peer')schemas.Peer={$id:'other',$dynamicAnchor:'base',type:'object'};
  if(form==='unsupported-dialect')schemas.Base.$schema='https://dialects.example.invalid/unsupported';
  if(form==='bounded-absence'){schemas.Base.required=['other'];schemas.Base.properties.other={type:'integer'};}
 });
 const {schema}=await checked(input),incomplete=['dynamic-peer','unsupported-dialect','bounded-absence'].includes(form);assert.equal(schema.complete,!incomplete,JSON.stringify(schema.findings));
 if(['dynamic-peer','bounded-absence'].includes(form)){assert.equal(code(schema,'discriminator.required.incomplete').length,1);assert.equal(code(schema,'discriminator.default-mapping.required').length,0);}
 if(form==='unsupported-dialect')assert(schema.findings.some(finding=>finding.code.includes('dialect')),JSON.stringify(schema.findings));
 if(!incomplete)assert(!schema.findings.some(finding=>finding.severity==='error'),JSON.stringify(schema.findings));
});

const routes=modern.flatMap(from=>modern.filter(target=>target.slice(0,3)!==from.slice(0,3)).map(target=>[from,target]));
for(const [from,target]of routes)for(const format of ['yaml','json'])for(const kind of ['dynamic-pointer','static-anchor','one-anchor','external-dynamic'])test(`${from} ${format} ${kind} migration to ${target} retains native reference and required semantics`,async()=>{
 const input=packet(from,format,kind),before=input.resources.map(resource=>resource.text),result=await planMigration({...input,targetVersion:target,destination:'file:///output/migrated/'});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);assert.equal(result.producerVersion,'28');assert.equal(result.validation.family,target.slice(0,3));const entry=result.outputs.find(output=>output.id===result.outputRoot),value=YAML.parse(entry.text);assert.equal(value.openapi,target);assert.equal(value.info.version,'unrelated-api-version');assert(entry.text.includes('$dynamicRef'));assert(entry.text.includes('9007199254740993.00'));
 const output={root:result.outputRoot,resources:result.outputs.map(output=>({id:output.id,text:output.text,generation:0})),snapshot:'migrated-'+input.snapshot+'-'+target};const checkedOutput=await evaluateSchemas(output);assert.equal(checkedOutput.complete,true,JSON.stringify(checkedOutput.findings));assert(!checkedOutput.findings.some(finding=>finding.severity==='error'),JSON.stringify(checkedOutput.findings));assert.deepEqual(input.resources.map(resource=>resource.text),before);
});
for(const version of modern)for(const format of ['yaml','json'])test(`${version} ${format} migration preserves actual dynamic anchors and all captured candidate owners`,async()=>{
 const input=edit(packet(version,format,'one-anchor'),value=>{delete value.components.schemas.Subject.discriminator;value.components.schemas.Peer={$id:'other',$dynamicAnchor:'base',type:'object'};}),target=version.startsWith('3.1.')?'3.2.1':'3.1.2',before=input.resources.map(resource=>resource.text),result=await planMigration({...input,targetVersion:target,destination:'file:///output/dynamic/'});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));const entry=YAML.parse(result.outputs.find(output=>output.id===result.outputRoot).text);assert.equal(entry.components.schemas.Base.$dynamicAnchor,'base');assert.equal(entry.components.schemas.Peer.$dynamicAnchor,'base');assert.equal(entry.components.schemas.Subject.allOf[0].$dynamicRef,'#base');assert.deepEqual(input.resources.map(resource=>resource.text),before);
});
