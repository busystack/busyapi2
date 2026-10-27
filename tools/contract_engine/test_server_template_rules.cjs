const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{deriveBundle}=require('./dist/derived_bundle.cjs'),{planFileMove}=require('./dist/refactoring_file.cjs'),{planMigration}=require('./dist/migration.cjs');
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function capture(version,format,url){
 const root='file:///approved/servers/api.'+format,value={openapi:version,info:{title:'Server literals 雪',version:'api-version'},paths:{},servers:[{url}], 'x-exact':'EXACT','x-payload':{servers:[{url:'https://literal/{unclosed'}]}};
 const text=(format==='json'?JSON.stringify(value):'# Keep literals\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
 return {root,snapshot:'server-literals-'+version,resources:[{id:root,text,generation:1,identity:'original'}]};
}
for(const version of versions)for(const format of ['yaml','json'])for(const character of ['\u00a0','\u1680','\u2000','\u200a','\u2028','\u2029','\u202f','\u205f','\u3000','\ufeff'])test(`${version} ${format} Server preserves allowed Unicode URL literal U+${character.charCodeAt(0).toString(16)}`,()=>{
 const input=capture(version,format,'https://api.example.invalid/path'+character+'part'),original=JSON.stringify(input),result=analyse(input);
 assert.equal(result.status,'complete',JSON.stringify(result.findings));assert.equal(result.complete,true);assert.equal(result.versions.serverRules,'2');assert.equal(JSON.stringify(input),original);
});
for(const version of versions)for(const format of ['yaml','json'])for(const suffix of ['{unfinished','stray}','{outer{inner}}','{v}/{unfinished','{v}}'])test(`${version} ${format} Server delimiters reject ${suffix}`,()=>{
 const input=capture(version,format,'https://api.example.invalid/'+suffix),original=input.resources[0].text,result=analyse(input),code=version.startsWith('3.2')?'server.url.template':'server.url.template-delimiters',finding=result.findings.find(f=>f.code===code);
 assert.equal(result.status,'invalid',JSON.stringify(result.findings));assert.equal(result.complete,true);assert(finding);assert.equal(finding.resource,input.root);assert.equal(finding.pointer,'/servers/0/url');assert(finding.range[1]>finding.range[0]);assert.equal(input.resources[0].text,original);assert(!result.findings.some(f=>f.pointer.startsWith('/x-payload')));
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const character of [' ','\t','\n','\r','\v','\f'])test(`${version} ${format} ASCII whitespace U+${character.charCodeAt(0).toString(16)} remains invalid`,()=>{
 const result=analyse(capture(version,format,'https://api.example.invalid/path'+character+'part'));assert.equal(result.status,'invalid',JSON.stringify(result.findings));assert.equal(result.complete,true);
});
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} percent-adjacent variables retain the legacy/new grammar distinction`,()=>{
 const input=capture(version,format,'https://api.example.invalid/%{hex}/'),value=YAML.parse(input.resources[0].text);value.servers[0].variables={hex:{default:'20',enum:['20']}};input.resources[0].text=format==='json'?JSON.stringify(value):YAML.stringify(value);
 const result=analyse(input);assert.equal(result.status,version.startsWith('3.2')?'invalid':'complete',JSON.stringify(result.findings));assert(!result.findings.some(f=>f.code==='server.url.template-delimiters'));
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const character of ['\u00a0','\ufeff','\u2028'])test(`${version} ${format} Unicode U+${character.charCodeAt(0).toString(16)} survives bundle and file relocation`,()=>{
 const input=capture(version,format,'../path'+character+'part/'),original=input.resources[0].text,expected=new URL(YAML.parse(original).servers[0].url,input.root).href;
 const bundle=deriveBundle({...input,outputId:'file:///output/bundle.json'}),value=JSON.parse(bundle.output.text);assert.equal(value.openapi,version);assert.equal(value.servers[0].url,expected);assert.equal(analyse({root:bundle.output.id,snapshot:'bundle',resources:[{id:bundle.output.id,text:bundle.output.text,generation:1,identity:'bundle'}]}).status,'complete');
 const destination='file:///approved/deep/moved/api.'+format,plan=planFileMove({snapshot:input.snapshot,resources:input.resources,contexts:[{root:input.root,resources:[input.root]}],target:{resource:input.root,generation:1},destinationResource:destination});let changed=original;
 for(const edit of plan.edits.filter(e=>e.buffer===input.root).sort((a,b)=>b.start-a.start)){assert.equal(changed.slice(edit.start,edit.end),edit.expected);changed=changed.slice(0,edit.start)+edit.replacement+changed.slice(edit.end);}
 assert.equal(new URL(YAML.parse(changed).servers[0].url,destination).href,expected);assert(changed.includes('9007199254740993.00'));assert.equal(input.resources[0].text,original);
});
for(const format of ['yaml','json'])for(const character of ['\u00a0','\ufeff','\u2028'])for(const targetVersion of ['2.0','3.1.2','3.2.1'])test(`3.0 ${format} Unicode Server preserves relative Terms on migration to ${targetVersion}`,async()=>{
 const input=capture('3.0.4',format,'https://api.example.invalid/path'+character+'part/'),value=YAML.parse(input.resources[0].text);value.info.termsOfService='terms';input.resources[0].text=format==='json'?JSON.stringify(value):YAML.stringify(value);const original=input.resources[0].text;
 const result=await planMigration({...input,targetVersion,destination:'file:///output/migrated/'});assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.producerVersion,'17');const output=result.outputs.find(o=>o.id===result.outputRoot),converted=YAML.parse(output.text);assert.equal(converted.info.termsOfService,new URL('terms',new URL(value.servers[0].url,input.root)).href);assert.equal(input.resources[0].text,original);
});
for(const version of ['3.0.4','3.1.2'])for(const format of ['yaml','json'])test(`${version} ${format} malformed delimiters cannot publish any supported target`,async()=>{
 const input=capture(version,format,'https://api.example.invalid/{unfinished'),original=input.resources[0].text;
 for(const targetVersion of ['2.0','3.0.4','3.1.2','3.2.1']){const result=await planMigration({...input,targetVersion,destination:'file:///output/refused/'});assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.validation.server.url.template-delimiters'&&p.pointer==='/servers/0/url'&&p.reason==='source-incomplete'));}assert.equal(input.resources[0].text,original);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} file relocation retains independent absolute Unicode Server spelling`,()=>{
 const input=capture(version,format,'https://api.example.invalid/path\u00a0part/'),original=input.resources[0].text,plan=planFileMove({snapshot:input.snapshot,resources:input.resources,contexts:[{root:input.root,resources:[input.root]}],target:{resource:input.root,generation:1},destinationResource:'file:///approved/deep/moved/api.'+format});assert(!plan.edits.some(e=>e.buffer===input.root),JSON.stringify(plan.edits));assert.equal(input.resources[0].text,original);
});
