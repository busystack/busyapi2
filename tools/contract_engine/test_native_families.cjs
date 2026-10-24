const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs');
for(const family of ['2.0','3.0','3.1','3.2'])for(const format of ['yaml','json'])for(const valid of [true,false])test(`published ${family} ${format} ${valid?'positive':'negative'} native fixture`,async()=>{
 const text=fs.readFileSync(`${__dirname}/fixtures/native-families/${family}-${valid?'valid':'invalid'}.${format}`,'utf8'),root='file:///approved/family.'+format,input={root,snapshot:family,resources:[{id:root,text,generation:1}]};
 const a=analyse(input),b=await evaluateSchemas(input);
 if(valid){assert.equal(a.status,'complete',JSON.stringify(a.findings));assert.equal(b.complete,true,JSON.stringify(b.findings));assert(!b.findings.some(f=>f.severity==='error'));assert.equal(a.operations.length,1);}
 else assert(a.findings.some(f=>f.severity==='error')||b.findings.some(f=>f.severity==='error'));
 assert.equal(input.resources[0].text,text);
});
