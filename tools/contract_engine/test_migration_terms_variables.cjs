const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs'),{independentTermsDestination}=require('./dist/migration_terms_base.cjs');
const root='https://contracts.example.invalid/descriptions/api.json';
function server(url,finite=false){return {url,variables:Object.fromEntries([...url.matchAll(/\{([^{}]+)\}/gu)].map(match=>[match[1],{default:finite?'0':'v1',...(finite?{enum:Array.from({length:257},(_,i)=>String(i))}:{})}]))};}
function capture(version,format,terms,servers){
 const id=root.replace('.json','.'+format),value={openapi:version,info:{title:'Terms 雪',version:'api-version',termsOfService:terms},servers,paths:{},'x-exact':'EXACT','x-payload':{termsOfService:'literal'}};
 const text=(format==='json'?JSON.stringify(value):'# Keep terms organization\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
 return {root:id,snapshot:'terms-variable-proof',resources:[{id,text,generation:1,identity:'original'}]};
}
const positive=[
 ['root-path','/terms','https://api.example.invalid/{version}/','https://api.example.invalid/terms'],
 ['retrieval-root','/terms','/v1/{version}/','https://contracts.example.invalid/terms'],
 ['retrieval-path','/terms','service/{version}/','https://contracts.example.invalid/terms'],
 ['retrieval-parent','/terms','../service/{version}/','https://contracts.example.invalid/terms'],
 ['authority','//legal.example.invalid/terms','https://{host}.example.invalid/','https://legal.example.invalid/terms'],
 ['port-variable','//legal.example.invalid/terms','https://api.example.invalid:{port}/','https://legal.example.invalid/terms'],
 ['userinfo-variable','//legal.example.invalid/terms','https://{user}@api.example.invalid/','https://legal.example.invalid/terms'],
 ['large-irrelevant-enum','/terms','https://api.example.invalid/{version}/','https://api.example.invalid/terms'],
];
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])for(const targetVersion of ['3.1.2','3.2.1'])for(const [name,terms,url,expected]of positive)test(`${version} ${format} to ${targetVersion} proves discarded Server components: ${name}`,async()=>{
 const input=capture(version,format,terms,[server(url,name==='large-irrelevant-enum')]),before=input.resources[0].text,result=await planMigration({...input,targetVersion,destination:'file:///output/review/'});
 assert.equal(result.status,'faithfully-convertible',JSON.stringify(result.problems));assert.equal(result.complete,true);const output=result.outputs.find(o=>o.id===result.outputRoot),value=YAML.parse(output.text);assert.equal(value.info.termsOfService,expected);assert.equal(value.openapi,targetVersion);assert(output.text.includes('9007199254740993.00'));assert.equal(input.resources[0].text,before);
 const convertedServer=value.servers[0];
 for(const choice of ['v1','nested/path','../escape','?query','#fragment','//other.example.invalid/',':8443','/%2F','雪😀','%20','a@b','https://other.invalid/','0']){
  const expand=template=>template.replace(/\{([^{}]+)\}/gu,()=>choice);
  let originalUrl,convertedUrl;
  try{originalUrl=new URL(expand(url),input.root);convertedUrl=new URL(expand(convertedServer.url),output.id);}catch(error){if(!(error instanceof TypeError))throw error;continue;}
  assert.equal(convertedUrl.href,originalUrl.href);assert.equal(new URL(terms,originalUrl).href,expected);
 }
});
const negative=[
 ['host','/terms','https://{host}.example.invalid/'],
 ['path','terms','https://api.example.invalid/{version}/'],
 ['empty-query','?','https://api.example.invalid/{path}/'],
 ['fragment-only','#terms','https://api.example.invalid/{path}/'],
 ['initial-form','/terms','/{first}/'],
 ['filename','terms','https://api.example.invalid/v1/{filename}'],
];
for(const format of ['yaml','json'])for(const [name,terms,url]of negative)test(`3.0 ${format} relevant unrestricted ${name} never uses its default`,async()=>{
 const input=capture('3.0.4',format,terms,[server(url)]),before=input.resources[0].text,result=await planMigration({...input,targetVersion:'3.1.2',destination:'file:///output/refused/'});assert.equal(result.status,'blocked');assert.equal(result.complete,false);assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.info.terms-server-variable'&&p.reason==='implementation'&&p.pointer==='/servers/0/url'&&p.resource===input.root&&p.range[1]>p.range[0]));assert.equal(input.resources[0].text,before);
});
for(const [name,terms,url,expected]of [
 ['query replaced by path','terms','https://api.example.invalid/v1/?{query}','https://api.example.invalid/v1/terms'],
 ['fragment discarded','terms','https://api.example.invalid/v1/#{fragment}','https://api.example.invalid/v1/terms'],
 ['explicit empty query','?','https://api.example.invalid/v1/?{query}','https://api.example.invalid/v1/?'],
 ['explicit query','?legal','https://api.example.invalid/v1/?{query}','https://api.example.invalid/v1/?legal'],
 ['empty reference','', 'https://api.example.invalid/v1/?fixed#{fragment}','https://api.example.invalid/v1/?fixed'],
 ['fragment replacement','#legal','https://api.example.invalid/v1/?fixed#{fragment}','https://api.example.invalid/v1/?fixed#legal'],
 ['query retained','', 'https://api.example.invalid/v1/?{query}',undefined],
 ['fragment retains query','#legal','https://api.example.invalid/v1/?{query}',undefined],
])test(`native Terms dependency proof: ${name}`,()=>assert.equal(independentTermsDestination(server(url),terms,root),expected));
for(const format of ['yaml','json'])test(`3.0 ${format} query/fragment Server remains a target blocker after Terms proof`,async()=>{
 for(const url of ['https://api.example.invalid/v1/?{query}','https://api.example.invalid/v1/#{fragment}']){const input=capture('3.0.4',format,'terms',[server(url)]),result=await planMigration({...input,targetVersion:'3.1.2',destination:'file:///output/refused/'});assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.validation.server.url.query-fragment'&&p.reason==='target-representation'));assert(!result.problems.some(p=>p.code==='migration.info.terms-server-variable'));}
});
for(const format of ['yaml','json'])test(`3.0 ${format} different fixed origins do not become one Terms URI`,async()=>{
 const input=capture('3.0.4',format,'/terms',[server('https://one.example.invalid/{path}/'),server('https://two.example.invalid/{path}/')]),result=await planMigration({...input,targetVersion:'3.1.2',destination:'file:///output/refused/'});assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert(result.problems.some(p=>p.code==='migration.info.terms-bases'&&p.reason==='target-representation'&&p.pointer==='/info/termsOfService'));
});

for(const [url,expected]of [['file:///C:/v1/{path}/','file:///C:/terms'],['file:///approved/{path}/',undefined]])test(`canonical file URL drive dependency is retained: ${url}`,()=>assert.equal(independentTermsDestination(server(url),'/terms',root),expected));
