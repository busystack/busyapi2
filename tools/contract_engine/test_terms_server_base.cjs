const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {deriveBundle}=require('./dist/derived_bundle.cjs'),{planFileMove}=require('./dist/refactoring_file.cjs'),{planMigration}=require('./dist/migration.cjs'),{analyse}=require('./dist/model.cjs');
const root='https://contracts.example.invalid/descriptions/api.json';
function capture(version,format='json',terms='terms',servers=[{url:'https://api.example.invalid/v1/'}]){
 const id=root.replace('.json','.'+format),value={...(version==='2.0'?{swagger:version,host:'api.example.invalid',basePath:'/v1/',schemes:['https']}:{openapi:version,servers}),info:{title:'Terms 雪',version:'1',termsOfService:terms},paths:{},'x-exact':111};
 const text=(format==='json'?JSON.stringify(value):'# Keep terms\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace('111','9007199254740993.00');return {root:id,snapshot:'terms-base',resources:[{id,text,generation:1,identity:'original'}]};
}
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])for(const terms of ['terms','../terms?lang=en#part','/terms','?terms',''])test(`${version} ${format} bundle retains Server-relative Terms ${JSON.stringify(terms)}`,()=>{
 const input=capture(version,format,terms),before=input.resources[0].text,bundle=deriveBundle({...input,outputId:'https://output.example.invalid/deep/api.json'}),after=JSON.parse(bundle.output.text);
 assert.equal(after.info.termsOfService,terms);assert.equal(new URL(after.info.termsOfService,after.servers[0].url).href,new URL(terms,'https://api.example.invalid/v1/').href);assert(bundle.output.text.includes('9007199254740993.00'));assert.equal(input.resources[0].text,before);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} file move preserves Terms destination in the owning kind of base`,()=>{
 const input=capture(version,format,'terms',[{url:'../service/'}]);input.root='file:///approved/api.'+format;input.resources[0].id=input.root;const original=input.resources[0].text,destination='file:///approved/deep/moved/api.'+format,plan=planFileMove({snapshot:input.snapshot,resources:input.resources,contexts:[{root:input.root,resources:[input.root]}],target:{resource:input.root,generation:1},destinationResource:destination});let text=original;
 for(const edit of plan.edits.filter(e=>e.buffer===input.root).sort((a,b)=>b.start-a.start)){assert.equal(text.slice(edit.start,edit.end),edit.expected);text=text.slice(0,edit.start)+edit.replacement+text.slice(edit.end);}
 const before=YAML.parse(original),after=YAML.parse(text),sourceBase=version.startsWith('3.0')?new URL(before.servers[0].url,input.root).href:input.root,targetBase=version.startsWith('3.0')?new URL(after.servers[0].url,destination).href:destination;
 assert.equal(new URL(after.info.termsOfService,targetBase).href,new URL(before.info.termsOfService,sourceBase).href);if(version.startsWith('3.0'))assert.equal(after.info.termsOfService,'terms');assert.equal(input.resources[0].text,original);assert(text.includes('9007199254740993.00'));
});
for(const format of ['yaml','json'])for(const version of ['3.0.0','3.0.4'])for(const targetVersion of ['2.0','3.1.2','3.2.1'])test(`${version} ${format} migration to ${targetVersion} captures Terms Server URL before declaration changes`,async()=>{
 const input={...capture(version,format),targetVersion,destination:'file:///output/review/'},original=input.resources[0].text,result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));const output=result.outputs.find(o=>o.id===result.outputRoot),value=YAML.parse(output.text);assert.equal(value.info.termsOfService,'https://api.example.invalid/v1/terms');assert.equal(input.resources[0].text,original);assert(output.text.includes('9007199254740993.00'));assert.equal(analyse({root:output.id,snapshot:'cold',resources:result.outputs.map(o=>({id:o.id,text:o.text,generation:0}))}).status,'complete');
});
for(const format of ['yaml','json'])test(`${format} modern document URI does not become a Server-relative URL on downgrade`,async()=>{
 const input={...capture('3.1.2',format),targetVersion:'3.0.4',destination:'file:///output/review/'},result=await planMigration(input);assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(YAML.parse(result.outputs.find(o=>o.id===result.outputRoot).text).info.termsOfService,'https://contracts.example.invalid/descriptions/terms');
});
for(const format of ['yaml','json'])for(const targetVersion of ['3.0.4','3.1.2','3.2.1'])test(`Swagger ${format} composed migration to ${targetVersion} applies reviewed Terms intent to the actual Server base`,async()=>{
 const input={...capture('2.0',format),targetVersion,destination:'file:///output/review/'},review=await planMigration(input),problem=review.problems.find(p=>p.code==='migration.info.terms-uri-activation');assert(problem,JSON.stringify(review.problems));const result=await planMigration({...input,decisions:{[problem.id]:'interpret-terms-as-uri'}});assert.equal(result.complete,true,JSON.stringify(result.problems));const value=YAML.parse(result.outputs.find(o=>o.id===result.outputRoot).text);assert.equal(value.info.termsOfService,targetVersion==='3.0.4'?'terms':'https://api.example.invalid/v1/terms');
});
for(const format of ['yaml','json'])for(const [name,terms,servers,expected]of [
 ['same-target','/terms',[{url:'https://api.example.invalid/v1/'},{url:'https://api.example.invalid/v2/'}],'https://api.example.invalid/terms'],
 ['distinct-target','terms',[{url:'https://one.example.invalid/'},{url:'https://two.example.invalid/'}],null],
 ['finite-template-same','/terms',[{url:'https://api.example.invalid/{version}/',variables:{version:{default:'v1',enum:['v1','v2']}}}],'https://api.example.invalid/terms'],
 ['finite-template-distinct','terms',[{url:'https://{host}.example.invalid/',variables:{host:{default:'one',enum:['one','two']}}}],null],
 ['unrestricted-template','terms',[{url:'https://{host}.example.invalid/',variables:{host:{default:'one'}}}],null],
 ['absolute-terms','https://terms.example.invalid/',[{url:'https://{host}.example.invalid/',variables:{host:{default:'one'}}}],'https://terms.example.invalid/'],
 ])test(`3.0 ${format} migration proves all captured Server choices: ${name}`,async()=>{
 const input={...capture('3.0.4',format,terms,servers),targetVersion:'3.1.2',destination:'file:///output/review/'},original=input.resources[0].text,result=await planMigration(input);assert.equal(result.complete,expected!==null,JSON.stringify(result.problems));assert.equal(input.resources[0].text,original);
 if(expected)assert.equal(YAML.parse(result.outputs.find(o=>o.id===result.outputRoot).text).info.termsOfService,expected);else{assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);const problem=result.problems.find(p=>p.code===(name==='unrestricted-template'?'migration.info.terms-server-variable':'migration.info.terms-bases'));assert(problem,JSON.stringify(result.problems));assert.equal(problem.resource,input.root);assert(problem.range[1]>problem.range[0]);assert.equal(problem.reason,name==='unrestricted-template'?'implementation':'target-representation');}
});
for(const format of ['yaml','json'])for(const servers of [undefined,[]])test(`3.0 ${format} default Server uses the retrieval origin, not the document directory`,async()=>{
 const input=capture('3.0.4',format);const value=YAML.parse(input.resources[0].text);if(servers===undefined)delete value.servers;else value.servers=servers;input.resources[0].text=format==='json'?JSON.stringify(value):YAML.stringify(value);
 const result=await planMigration({...input,targetVersion:'3.1.2',destination:'file:///output/review/'});assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(YAML.parse(result.outputs.find(o=>o.id===result.outputRoot).text).info.termsOfService,'https://contracts.example.invalid/terms');
});
test('unsupported Swagger Terms URI host notation is an implementation blocker',async()=>{
 const input={...capture('2.0','json','https://[v1.future]/terms'),targetVersion:'3.0.4',destination:'file:///output/review/'},result=await planMigration(input),problem=result.problems.find(p=>p.code==='migration.info.terms-uri');assert(problem);assert.equal(problem.reason,'implementation');assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);
});
for(const [name,server,code]of [
 ['limit',{url:'https://api.example.invalid/{item}/',variables:{item:{default:'0',enum:Array.from({length:257},(_,i)=>String(i))}}},'limit.migration.terms-servers'],
 ['unsupported',{url:'https://[v1.future]/'},'migration.info.terms-server-uri'],
 ['invalid',{url:'https://api.example.invalid/has space'},'migration.info.terms-server-uri'],
 ])test(`3.0 Terms Server ${name} does not create a partial or falsely complete conversion`,async()=>{
 const input={...capture('3.0.4','json','terms',[{url:'https://known.example.invalid/'},server]),targetVersion:'3.1.2',destination:'file:///output/review/'},result=await planMigration(input);assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code===code),JSON.stringify(result.problems));assert(!result.problems.some(p=>p.code==='migration.info.terms-bases'));
});
