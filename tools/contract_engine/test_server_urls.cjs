const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse,createGraph}=require('./dist/model.cjs'),{planMigration}=require('./dist/migration.cjs');
const patches=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function capture(version,format,url,placement='root'){
 const root='file:///servers/api.'+format,server={url},value={openapi:version,info:{title:'Servers 雪',version:'api-version'},paths:{'/items':{get:{operationId:'follow',responses:{200:{description:'ok'}}}}},'x-exact':111,'x-payload':{servers:[{url:'literal space %zz'}]}};
 if(placement==='root')value.servers=[server];if(placement==='path')value.paths['/items'].servers=[server];if(placement==='operation')value.paths['/items'].get.servers=[server];if(placement==='link')value.components={links:{Next:{operationId:'follow',server}}};
 const text=(format==='json'?JSON.stringify(value):'# Keep servers\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace('111','9007199254740993.00');return {root,snapshot:'server-url-'+version,resources:[{id:root,text,generation:1,identity:'original'}]};
}
for(const version of patches)for(const format of ['yaml','json'])for(const [name,url,valid]of [
 ['https','https://api.example.invalid/v1/',true],['relative','../v1/',true],['empty','',!version.startsWith('3.2')],['unicode','https://例え.invalid/雪',true],['ipv6','https://[::1]:443/v1',true],['url-path-literals','https://api.example.invalid/path[part]',true],['query','https://api.example.invalid/v1?selected=1',version.startsWith('3.0')],['fragment','https://api.example.invalid/v1#part',version.startsWith('3.0')],['space','https://api.example.invalid/has space',false],['newline','https://api.example.invalid/v1\n',false],['percent','https://api.example.invalid/%zz',false],['port','https://api.example.invalid:abc/v1',false],['backslash','https://api.example.invalid/\\path',false],
])test(`${version} ${format} fixed Server ${name} follows its own rules`,()=>{
 const input=capture(version,format,url),before=JSON.stringify(input),result=analyse(input);assert.equal(result.status,valid?'complete':'invalid',JSON.stringify(result.findings));assert.equal(result.complete,true);assert.equal(JSON.stringify(input),before);
 const issues=result.findings.filter(f=>f.code.startsWith('server.url.'));assert.equal(issues.length,valid?0:1,JSON.stringify(issues));if(!valid){assert.equal(issues[0].resource,input.root);assert.equal(issues[0].pointer,'/servers/0/url');assert(issues[0].range[1]>issues[0].range[0]);}
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const placement of ['root','path','operation','link'])test(`${version} ${format} ${placement} Server has precise ownership`,()=>{
 const input=capture(version,format,'https://api.example.invalid/has space',placement),result=analyse(input),issue=result.findings.find(f=>f.code.startsWith('server.url.'));assert(issue,JSON.stringify(result.findings));const pointer={root:'/servers/0/url',path:'/paths/~1items/servers/0/url',operation:'/paths/~1items/get/servers/0/url',link:'/components/links/Next/server/url'}[placement];assert.equal(issue.pointer,pointer);assert.equal(issue.resource,input.root);assert.equal(result.status,'invalid');
});
for(const version of patches)for(const format of ['yaml','json'])for(const [url,variables,repeated]of [
 ['{scheme}://{host}:{port}/{path}',{scheme:{default:'https'},host:{default:'api.example.invalid'},port:{default:'443'},path:{default:'v1'}},false],
 ['https://{id}.example.invalid/{id}',{id:{default:'demo'}},true],
 ['https://api.example.invalid/{odd?name}',{'odd?name':{default:'v1'}},false],
])test(`${version} ${format} variable templates do not inherit fixed URL or newer repeated-name rules: ${url}`,()=>{
 const input=capture(version,format,url),doc=YAML.parse(input.resources[0].text);doc.servers[0].variables=variables;input.resources[0].text=format==='json'?JSON.stringify(doc):YAML.stringify(doc);const result=analyse(input),invalid=repeated&&version.startsWith('3.2');assert.equal(result.status,invalid?'invalid':'complete',JSON.stringify(result.findings));assert.equal(result.findings.some(f=>f.code==='server.variable.repeated'),invalid);assert(!result.findings.some(f=>f.code==='server.url.uri'));
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} unsupported fixed Server host remains incomplete`,()=>{
 const input=capture(version,format,'https://[v1.future]/api'),result=analyse(input);assert.equal(result.complete,false);assert.equal(result.status,'incomplete');const issue=result.findings.find(f=>f.code==='server.url.unsupported');assert(issue,JSON.stringify(result.findings));assert.equal(issue.pointer,'/servers/0/url');assert.equal(issue.severity,'warning');
});
for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} default enum policy retains the family SHOULD/MUST distinction`,()=>{
 const input=capture(version,'json','https://{host}.example.invalid/'),doc=JSON.parse(input.resources[0].text);doc.servers[0].variables={host:{default:'other',enum:['known']}};input.resources[0].text=JSON.stringify(doc);const result=analyse(input),issue=result.findings.find(f=>f.code==='server.variable.default-enum');assert(issue);assert.equal(issue.severity,version==='3.0.4'?'warning':'error');assert.equal(result.status,version==='3.0.4'?'complete':'invalid');
});
for(const format of ['yaml','json'])for(const targetVersion of ['3.1.2','3.2.1'])test(`3.0 ${format} Server query cannot publish a target ${targetVersion} violation`,async()=>{
 const input={...capture('3.0.4',format,'https://api.example.invalid/v1?selected=1'),targetVersion,destination:'file:///output/review/'},original=input.resources[0].text,result=await planMigration(input);assert.equal(result.complete,false);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.validation.server.url.query-fragment'),JSON.stringify(result.problems));assert.equal(input.resources[0].text,original);
});
test('changing declarations in the same root retires query and repetition rules without retaining prior scopes',()=>{
 for(let cycle=0;cycle<5;cycle++)for(const version of ['3.0.4','3.1.2','3.2.1','3.0.4']){const input=capture(version,'json','https://api.example.invalid/v1?selected=1'),result=analyse(input);assert.equal(result.status,version==='3.0.4'?'complete':'invalid');assert.equal(createGraph(input).graph.scope(input.root,'/servers/0').family,version.slice(0,3));}
});
for(const [entryVersion,otherVersion]of [['3.0.4','3.1.2'],['3.1.2','3.0.4'],['3.0.4','3.2.1'],['3.2.1','3.0.4']])test(`Server query policy follows external owner ${otherVersion} under ${entryVersion}`,()=>{
 const input=capture(entryVersion,'json','https://entry.example.invalid/'),other='file:///servers/other.json',entry=JSON.parse(input.resources[0].text);
 entry.components={schemas:{Use:{$ref:'other.json#/components/schemas/Model'}}};input.resources[0].text=JSON.stringify(entry);
 input.resources.push({id:other,generation:2,identity:'other',text:JSON.stringify({openapi:otherVersion,info:{title:'Other',version:'1'},paths:{},servers:[{url:'https://other.example.invalid/?selected=1'}],components:{schemas:{Model:{type:'string'}}}})});
 const result=analyse(input),finding=result.findings.find(f=>f.code==='server.url.query-fragment');assert.equal(result.status,'incomplete',JSON.stringify(result.findings));assert(result.findings.some(f=>f.code==='reference.family.unsupported'));assert.equal(Boolean(finding),otherVersion!=='3.0.4');if(finding){assert.equal(finding.resource,other);assert.equal(finding.pointer,'/servers/0/url');}
});
