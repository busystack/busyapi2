const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs');
for(const family of ['2.0','3.0','3.1','3.2'])for(const format of ['yaml','json'])for(const valid of [true,false])test(`published ${family} ${format} ${valid?'positive':'negative'} native fixture`,async()=>{
 const text=fs.readFileSync(`${__dirname}/fixtures/native-families/${family}-${valid?'valid':'invalid'}.${format}`,'utf8'),root='file:///approved/family.'+format,input={root,snapshot:family,resources:[{id:root,text,generation:1}]};
 const a=analyse(input),b=await evaluateSchemas(input);
 if(valid){assert.equal(a.status,'complete',JSON.stringify(a.findings));assert.equal(b.complete,true,JSON.stringify(b.findings));assert(!b.findings.some(f=>f.severity==='error'));assert.equal(a.operations.length,1);}
 else assert(a.findings.some(f=>f.severity==='error')||b.findings.some(f=>f.severity==='error'));
 assert.equal(input.resources[0].text,text);
});
test('modern published structures enforce path parameter names and 3.2 HTTP header tokens',()=>{
 for(const version of ['3.1.2','3.2.1']) {
  const operation={parameters:[{name:'id',in:'path',required:true,schema:{type:'string'}}],responses:{200:{description:'Pet',headers:{'X-Valid':{schema:{type:'integer'}}}}}};
  const value={openapi:version,info:{title:'Current publication',version:'1'},paths:{'/pets/{id}':{get:operation}}};
  const capture=()=>({root:'file:///approved/publication.json',snapshot:version,resources:[{id:'file:///approved/publication.json',text:JSON.stringify(value),generation:1}]});
  assert.equal(analyse(capture()).status,'complete');
  value.paths['/pets/{id}'].get.parameters[0].name='{id}';assert.equal(analyse(capture()).status,'invalid');
  value.paths['/pets/{id}'].get.parameters[0].name='id';
  if(version==='3.2.1') {
   value.paths['/pets/{id}'].get.responses[200].headers={'X Invalid':{schema:{type:'integer'}}};assert.equal(analyse(capture()).status,'invalid');
   value.paths['/pets/{id}'].get.responses[200].headers={'X-Valid':{schema:{type:'integer'}}};
   value.paths['/pets/{id}'].get.parameters[0].allowReserved=true;assert.equal(analyse(capture()).status,'complete');
  }
 }
});
