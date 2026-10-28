const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const dist=process.env.BUSYAPI_SERVER_DEFAULT_DIST||require('node:path').join(__dirname,'dist');
const {analyse}=require(dist+'/model.cjs'),{deriveBundle}=require(dist+'/derived_bundle.cjs'),{planFileMove}=require(dist+'/refactoring_file.cjs'),{planMigration}=require(dist+'/migration.cjs');
const patches=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'];
const cases=[
 ['relative choices','{base}/','other',['v1'],true],
 ['absolute choices','{base}/','https://default.example.invalid/v1',['https://enum.example.invalid/v2'],true],
 ['absolute default / relative enum','{base}/','https://default.example.invalid/v1',['v1'],false],
 ['relative default / absolute enum','{base}/','v1',['https://enum.example.invalid/v2'],false],
 ['authority default / relative enum','{base}/','//default.example.invalid/v1',['v1'],false],
 ['root default / relative enum','{base}/','/v1',['v1'],false],
 ['empty default / relative enum','{base}','',['v1'],false],
 ['empty enum / relative default','v{base}/','雪',[],true],
 ['empty enum / absolute default','{base}/','https://default.example.invalid/v1',[],true],
 ['relative empty default','v{base}/','',['known'],true],
 ['opaque braces in a default','path/{base}/','{literal}',['v1'],true],
 ['fixed root prefix','/{base}/','https://default.example.invalid/v1',['v1'],true],
];
function capture(version,format,url,fallback,options,terms,operation=false){
 const root='https://contracts.example.invalid/source/api.'+format,value={openapi:version,info:{title:'Captured default 雪',version:'API-1',...(terms===undefined?{}:{termsOfService:terms})},servers:[{url,variables:{base:{default:fallback,enum:options}}}],paths:operation?{'/items':{get:{responses:{204:{description:'No body'}}}}}:{},'x-exact':'EXACT','x-data':{servers:[{url:'literal invalid %zz',variables:{base:{default:'unchanged'}}}]}};
 const text=(format==='json'?JSON.stringify(value,null,2):'# Keep organization and default\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
 return {root,snapshot:version+'-'+format,resources:[{id:root,text,generation:7,identity:'original'}]};
}
const expand=(url,value)=>url.replace(/\{base\}/gu,()=>value);
function checkMeaning(original,before,converted,after,values){
 for(const value of new Set(values))assert.equal(new URL(expand(converted,value),after).href,new URL(expand(original,value),before).href,'substitution '+JSON.stringify(value));
}
function apply(source,edits){for(const edit of [...edits].sort((a,b)=>b.start-a.start)){assert.equal(source.slice(edit.start,edit.end),edit.expected);source=source.slice(0,edit.start)+edit.replacement+source.slice(edit.end);}return source;}
for(const version of patches)for(const format of ['yaml','json'])for(const [name,url,fallback,options,portable]of cases){
 test(`${version} ${format} bundle and file move include the declared default: ${name}`,()=>{
  const input=capture(version,format,url,fallback,options),before=input.resources[0].text;
  assert.equal(analyse(input).status,'complete');
  const physical='file:///approved/source/api.'+format,moveInput={...input,root:physical,resources:[{...input.resources[0],id:physical}]},destination='file:///approved/deep/moved/api.'+format;
  assert.equal(analyse(moveInput).status,'complete');
  if(!portable){
   assert.throws(()=>deriveBundle({...input,outputId:'file:///output/bundle.json'}),error=>error.code==='bundle.server.template-context'&&error.kind==='unsupported'&&error.source.resource===input.root&&error.source.pointer==='/servers/0/url'&&error.source.range[1]>error.source.range[0]);
   assert.throws(()=>planFileMove({snapshot:moveInput.snapshot,resources:moveInput.resources,contexts:[{root:physical,resources:[physical]}],target:{resource:physical,generation:7},destinationResource:destination}),error=>error.code==='file.move.server.template-context'&&error.kind==='unsupported'&&error.source.resource===physical&&error.source.pointer==='/servers/0/url'&&error.source.range[1]>error.source.range[0]);
  }else{
   const output=deriveBundle({...input,outputId:'file:///output/bundle.json'}),server=JSON.parse(output.output.text).servers[0];
   assert.deepEqual(server.variables.base,{default:fallback,enum:options});assert(output.output.text.includes('9007199254740993.00'));
   checkMeaning(url,input.root,server.url,output.output.id,[fallback,...options]);
   const plan=planFileMove({snapshot:moveInput.snapshot,resources:moveInput.resources,contexts:[{root:physical,resources:[physical]}],target:{resource:physical,generation:7},destinationResource:destination}),changed=apply(before,plan.edits.filter(edit=>edit.buffer===physical)),value=YAML.parse(changed);
   checkMeaning(url,physical,value.servers[0].url,destination,[fallback,...options]);assert(changed.includes('9007199254740993.00'));assert.deepEqual(value.servers[0].variables.base,{default:fallback,enum:options});
  }
  assert.equal(input.resources[0].text,before);assert.equal(moveInput.resources[0].text,before);
 });
 test(`${version} ${format} separate-copy 3.0 migration proves the default: ${name}`,async()=>{
  const input=capture(version,format,url,fallback,options),before=input.resources[0].text,result=await planMigration({...input,targetVersion:'3.0.4',destination:'file:///output/review/'});
  if(!portable){assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(problem=>problem.code==='bundle.server.template-context'&&problem.resource===input.root&&problem.pointer==='/servers/0/url'&&problem.range[1]>problem.range[0]));}
  else {assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));const output=result.outputs.find(output=>output.id===result.outputRoot),value=YAML.parse(output.text);assert.equal(value.openapi,'3.0.4');checkMeaning(url,input.root,value.servers[0].url,output.id,[fallback,...options]);assert.deepEqual(value.servers[0].variables.base,{default:fallback,enum:options});assert(output.text.includes('9007199254740993.00'));}
  assert.equal(input.resources[0].text,before);
 });
}
for(const version of patches)for(const format of ['yaml','json'])for(const targetVersion of ['2.0','3.1.2','3.2.1'])test(`${version} ${format} Terms migration to ${targetVersion} cannot ignore its default destination`,async()=>{
 const input=capture(version,format,'https://api.example.invalid/{base}/','default',['enum'],'terms'),before=input.resources[0].text,result=await planMigration({...input,targetVersion,destination:'file:///output/refused/'});
 assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(problem=>problem.code==='migration.info.terms-bases'&&problem.reason==='target-representation'&&problem.pointer==='/info/termsOfService'&&problem.resource===input.root&&problem.range[1]>problem.range[0]));assert.equal(input.resources[0].text,before);
});
for(const version of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} strict-family finite defaults retain both URI choices`,()=>{
 const input=capture(version,format,'v{base}/','first',['first','second']),before=input.resources[0].text,output=deriveBundle({...input,outputId:'file:///output/bundle.json'}),server=JSON.parse(output.output.text).servers[0];assert.equal(analyse(input).status,'complete');checkMeaning('v{base}/',input.root,server.url,output.output.id,['first','second']);assert.equal(input.resources[0].text,before);
});
for(const version of patches)for(const format of ['yaml','json'])for(const targetVersion of ['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const fallback of ['', '雪', '0'])for(const membership of ['empty','outside','inside'])test(`${version} ${format} upgrade to ${targetVersion} retains default ${JSON.stringify(fallback)} with ${membership} choices`,async()=>{
 const options=membership==='empty'?[]:membership==='outside'?['known']:[fallback,'known'],input=capture(version,format,'https://api.example.invalid/v{base}',fallback,options,undefined,true),value=YAML.parse(input.resources[0].text);
 const before=input.resources[0].text,result=await planMigration({...input,targetVersion,destination:'file:///output/upgraded/'});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);
 const output=result.outputs.find(output=>output.id===result.outputRoot),converted=YAML.parse(output.text),variable=converted.servers[0].variables.base;
 assert.equal(converted.openapi,targetVersion);assert.equal(converted.info.version,'API-1');assert.equal(variable.default,fallback);assert.deepEqual(variable.enum,options.includes(fallback)?options:[...options,fallback]);assert.deepEqual(converted['x-data'],value['x-data']);
 assert(output.text.includes('9007199254740993.00'));assert.equal(input.resources[0].text,before);
 const target={root:output.id,snapshot:'target',resources:[{id:output.id,text:output.text,generation:0}]};assert.equal(analyse(target).status,'complete');
 checkMeaning('https://api.example.invalid/v{base}',input.root,converted.servers[0].url,output.id,[fallback,...options]);
});
for(const targetVersion of ['3.1.2','3.2.1'])for(const kind of ['variable','enum'])for(const changed of [false,true])test(`3.0 YAML ${kind} alias to ${targetVersion} changes=${changed} retains shared ownership`,async()=>{
 const root='file:///approved/alias.yaml',fallback=changed?'other':'known',held=kind==='variable'?`x-held: &held {default: ${fallback}, enum: [known]}\n`:'x-held: &held [known]\n',variable=kind==='variable'?'*held':`{default: ${fallback}, enum: *held}`;
 const text='openapi: 3.0.4\ninfo: {title: "Keep shared choices", version: "1"}\n'+held+'servers: [{url: "https://api.example.invalid/{v}", variables: {v: '+variable+'}}]\npaths: {}\n',input={root,snapshot:kind+changed,resources:[{id:root,text,generation:3}]};
 const result=await planMigration({...input,targetVersion,destination:'file:///output/alias/'});
 if(changed){assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(problem=>problem.resource===root&&problem.reason==='implementation'&&problem.pointer===(kind==='variable'?'/servers/0/variables/v':'/servers/0/variables/v/enum')&&problem.range[1]>problem.range[0]));}
 else {assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert(result.outputs.find(output=>output.id===result.outputRoot).text.includes('*held'));}
 assert.equal(input.resources[0].text,text);
});
for(const targetVersion of ['3.1.2','3.2.1'])for(const flow of [false,true])test(`3.0 YAML ${flow?'flow':'block'} enum comments remain byte-exact while upgrading to ${targetVersion}`,async()=>{
 const root='file:///approved/comments.yaml',choices=flow?'      enum: ["known"] # Keep flow choice\r\n':'      enum:\r\n        # Keep first choice\r\n        - "known" # Keep value comment\r\n';
 const text='# Keep document\r\nopenapi: "3.0.4"\r\ninfo: {title: "Keep comments", version: "1"}\r\nservers:\r\n- url: "https://api.example.invalid/{v}"\r\n  variables:\r\n    v:\r\n      default: "雪" # Keep default comment\r\n'+choices+'paths: {}\r\nx-exact: 9007199254740993.00\r\n',input={root,snapshot:targetVersion+flow,resources:[{id:root,text,generation:2}]},result=await planMigration({...input,targetVersion,destination:'file:///output/comments/'});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));const output=result.outputs.find(output=>output.id===result.outputRoot),value=YAML.parse(output.text);assert.deepEqual(value.servers[0].variables.v.enum,['known','雪']);
 for(const comment of ['# Keep document','# Keep default comment',...(flow?['# Keep flow choice']:['# Keep first choice','# Keep value comment'])])assert.equal(output.text.split(comment).length,2,comment);
 assert(output.text.includes('default: "雪" # Keep default comment\r\n'));if(!flow)assert(output.text.includes('- "known" # Keep value comment\r\n'));assert(output.text.includes('9007199254740993.00'));assert(!/(^|[^\r])\n/u.test(output.text));assert.equal(input.resources[0].text,text);
});

for(const format of ['yaml','json'])test(`${format} HTTP retrieval identities are never physical file-move targets`,()=>{
 const input=capture('3.0.4',format,'v{base}/','first',['first']),before=input.resources[0].text;
 assert.throws(()=>planFileMove({snapshot:input.snapshot,resources:input.resources,contexts:[{root:input.root,resources:[input.root]}],target:{resource:input.root,generation:7},destinationResource:'file:///approved/moved/api.'+format}),error=>error.code==='file.move.path');
 assert.equal(input.resources[0].text,before);
});
