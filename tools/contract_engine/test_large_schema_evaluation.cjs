const assert=require('node:assert/strict'),{test}=require('node:test'),{performance}=require('node:perf_hooks');
const {createGraph}=require('./dist/model.cjs'),{evaluateSchemas}=require('./dist/schema_evaluation.cjs');

for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])test(`6400 independent ${version} schema roots fit the existing worker deadline with exact instances`,async()=>{
 const swagger=version==='2.0',value={[swagger?'swagger':'openapi']:version,info:{title:'Large captured resource',version:'1'},paths:{},...(swagger?{produces:['application/json']}:{})};
 for(let i=0;i<6400;i++){
  const precise=i%100===0,schema={type:'object',properties:{name:{type:'string'},...(precise?{exact:{type:'integer',minimum:111}}:{})}},example={name:'fixture',...(precise?{exact:111}:{})};
  value.paths['/items/'+i]={get:{summary:'Get item '+i,description:'Representative text '.repeat(10),responses:{200:{description:'OK',...(swagger?{schema,examples:{'application/json':example}}:{content:{'application/json':{schema,example}}})}}}};
 }
 const root='file:///approved/large-'+version+'.json',text=JSON.stringify(value,null,2).replaceAll('"minimum": 111','"minimum": 9007199254740993').replaceAll('"exact": 111','"exact": 9007199254740993');
 const input={root,snapshot:version,resources:[{id:root,text,generation:1}]},started=performance.now(),context=createGraph(input),result=await evaluateSchemas(input,undefined,context),elapsed=performance.now()-started;
 assert.equal(result.complete,true,JSON.stringify(result.findings));assert(!result.findings.some(f=>f.severity==='error'||f.code==='example.schema.incompatible'));assert.equal(result.schemas,6400);assert.equal(result.evaluations.length,6400);assert(result.evaluations.every(e=>e.valid));
 // The installed worker already has an eight-second operation deadline.
 // This guards the full captured production path rather than timing a helper.
 assert(elapsed<8000,`Canonical evaluation exceeded the existing worker deadline: ${elapsed.toFixed(1)} ms`);
 assert.equal(input.resources[0].text,text);
});
