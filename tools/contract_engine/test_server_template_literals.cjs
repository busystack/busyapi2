const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{planMigration}=require('./dist/migration.cjs');
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const invalid=['bad space','bad\tpart','bad\npart','bad\rpart','bad\vpart','bad\fpart','bad\u0000part','bad\u001fpart','bad\\part','bad%zz','bad%2z','bad%z2','bad%','bad%2','%A{digit}/%zz','%{hex}/%'];
function capture(version,format,suffix){
 const root='file:///approved/api.'+format,url='https://api.example.invalid/{version}/'+suffix,value={openapi:version,info:{title:'Template literals 雪',version:'api-version'},paths:{},servers:[{url,variables:{version:{default:'v1'},hex:{default:'20'},digit:{default:'1'}}}],'x-exact':'EXACT','x-payload':{servers:[{url:'https://literal/{value}/bad space%zz'}]}};
 const text=(format==='json'?JSON.stringify(value):'# Keep literal URL spelling\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
 return {root,snapshot:'template-literals',resources:[{id:root,text,generation:1,identity:'original'}]};
}
for(const version of versions)for(const format of ['yaml','json'])for(const suffix of invalid)test(`${version} ${format} literal outside variables rejects ${JSON.stringify(suffix)}`,()=>{
 const input=capture(version,format,suffix),original=input.resources[0].text,result=analyse(input),code=version.startsWith('3.2')?'server.url.template':'server.url.template-literal',finding=result.findings.find(f=>f.code===code);
 assert.equal(result.status,'invalid',JSON.stringify(result.findings));assert.equal(result.complete,true);assert(finding);assert.equal(finding.category,'openapi');assert.equal(finding.resource,input.root);assert.equal(finding.pointer,'/servers/0/url');assert(finding.range[1]>finding.range[0]);assert.equal(input.resources[0].text,original);assert(!result.findings.some(f=>f.pointer.startsWith('/x-payload')));
});
for(const version of versions)for(const format of ['yaml','json'])for(const suffix of ['%{hex}','%A{digit}','%2f','x\u00a0part','x\ufeffpart','x\u2028part'])test(`${version} ${format} percent substitutions and allowed Unicode retain family rules ${JSON.stringify(suffix)}`,()=>{
 const input=capture(version,format,suffix),original=input.resources[0].text,result=analyse(input),invalid=version.startsWith('3.2')&&suffix.includes('{');assert.equal(result.status,invalid?'invalid':'complete',JSON.stringify(result.findings));assert(!result.findings.some(f=>f.code==='server.url.template-literal'));assert.equal(input.resources[0].text,original);
});
for(const version of ['3.0.4','3.1.2'])for(const format of ['yaml','json'])for(const suffix of ['bad space','bad\\path','bad%zz'])for(const targetVersion of ['2.0','3.0.4','3.1.2','3.2.1'])test(`${version} ${format} invalid literal ${JSON.stringify(suffix)} cannot migrate to ${targetVersion}`,async()=>{
 const input=capture(version,format,suffix),original=input.resources[0].text,result=await planMigration({...input,targetVersion,destination:'file:///output/refused/'});assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.validation.server.url.template-literal'&&p.reason==='source-incomplete'&&p.resource===input.root&&p.pointer==='/servers/0/url'&&p.range[1]>p.range[0]));assert.equal(input.resources[0].text,original);
});
