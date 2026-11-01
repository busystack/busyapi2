const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {govern}=require('./dist/governance.cjs');
for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const media of ['application/x-www-form-urlencoded','application/xml'])test(`${version} ${format} selected policy checks respect literal ${media}`,async()=>{
 const root='file:///p/policy.'+format,schema={type:'object',properties:{id:{type:'integer',enum:['EXACT']}},required:['id']};
 const good=media==='application/xml'?'<item><id>9007199254740993</id></item>':'id=9007199254740993',bad='id=9007199254740992';
 const response=version==='2.0'?{description:'Read',schema,examples:{[media]:good}}:{description:'Read',content:{[media]:{schema,examples:{Good:{value:good},...(media==='application/xml'?{}:{Bad:{value:bad}})}}}};
 const value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Keep',version:'api'},paths:{'/items':{get:{responses:{200:response}}}}};
 const render=value=>(format==='json'?JSON.stringify(value):YAML.stringify(value)).replaceAll('"EXACT"','9007199254740993').replaceAll('EXACT','9007199254740993');
 const text=render(value),input={root,snapshot:'literal-policy',resources:[{id:root,text,generation:1}],policy:{entries:['spectral:oas']}};
 const result=await govern(input),rule=version==='2.0'?'oas2-valid-media-example':'oas3-valid-media-example';
 if(media==='application/xml'){
  assert.equal(result.complete,false,JSON.stringify(result.findings));assert(result.findings.some(f=>f.code==='policy.schema.execution.incomplete'));
  assert(!result.findings.some(f=>f.code==='policy.rule.'+rule));
 }else{
  assert.equal(result.complete,true,JSON.stringify(result.findings));
  const failures=result.findings.filter(f=>f.code==='policy.rule.'+rule);
  assert.equal(failures.length,version==='2.0'?0:1,JSON.stringify(failures));if(failures.length)assert(failures[0].pointer.endsWith('/Bad/value'));
 }
 assert.equal(input.resources[0].text,text);
});
