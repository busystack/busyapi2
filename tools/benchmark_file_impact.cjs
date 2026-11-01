// Headless worker/serialization diagnosis, not native input or a 50-ms gate.
// No files are read/written by the measured production plans; only immutable
// synthetic approved snapshots are supplied to the canonical graph/CST API.
const assert=require('node:assert/strict');
const {performance}=require('node:perf_hooks');
const {planFileMove,planFileDeletion}=require('./contract_engine/dist/refactoring_file.cjs');
const options={resources:100,examples:10,samples:12};
for(let i=2;i<process.argv.length;i+=2){
 const name=process.argv[i].replace(/^--/,''),value=Number(process.argv[i+1]);
 if(!Object.hasOwn(options,name)||!Number.isInteger(value)||value<1||value>({resources:400,examples:50,samples:100}[name]))throw Error('Usage: node tools/benchmark_file_impact.cjs [--resources 1..400] [--examples 1..50] [--samples 1..100]');
 options[name]=value;
}
assert.equal(process.versions.node,'24.15.0');
const started=performance.now(),root='file:///benchmark/root.json',source='file:///benchmark/payload.json',destination='file:///benchmark/new.json';
const examples={},resources=[];
for(let i=0;i<options.resources;i++){
 const values={},id='file:///benchmark/part-'+i+'.json';
 for(let j=0;j<options.examples;j++){
  examples['R'+i+'_'+j]={$ref:'part-'+i+'.json#/E'+j};
  values['E'+j]={externalValue:'payload.json#opaque%7E%2F'+j,description:'Captured serialized data 雪😀',...((i+j)%2?{}:{summary:'Exact source ownership'})};
 }
 resources.push({id,text:JSON.stringify(values),generation:1});
}
resources.unshift({id:root,text:JSON.stringify({openapi:'3.2.1',info:{title:'Impact diagnostic',version:'1'},paths:{},components:{examples},'x-data':{externalValue:'literal payload.json',$ref:'literal'}}),generation:1});
const opaque={id:source,text:'{"openapi":"payload only", "invalid": [ 雪😀 900719925474099312345678901',generation:2};
const input={snapshot:'headless-impact',resources,contexts:[{root,resources:resources.map(value=>value.id)}],target:{resource:source,generation:2}},captureMs=performance.now()-started;
const manifest={id:'file:///benchmark/busyapi.yaml',generation:1,text:'version: 1\nroots: [{name: Main, path: root.json}]\n'};
const stats=values=>{values.sort((a,b)=>a-b);return {samples:values.length,p50Ms:values[Math.floor(values.length*.5)],p95Ms:values[Math.ceil(values.length*.95)-1],maxMs:values.at(-1)};};
const results=[];
for(const mode of ['deletion-impact','retained-opaque-move']){
 const plans=[],handling=[];let bytes=0;
 for(let sample=-4;sample<options.samples;sample++){
  const start=performance.now(),plan=mode==='deletion-impact'?planFileDeletion({...input,deletionSource:opaque}):planFileMove({...input,moveSource:opaque,destinationResource:destination,retainIdentity:true,manifest}),planned=performance.now();
  const result=JSON.parse(JSON.stringify(plan)),handled=performance.now();
  assert.equal(result.usages.length,options.resources*options.examples);
  assert.equal(result.changes.find(change=>change.resource===source).before,opaque.text);
  if(mode==='deletion-impact')assert.equal(result.blockers.length,result.usages.length);
  else {assert.equal(result.file.opaque,true);assert(result.edits.every(edit=>edit.buffer===manifest.id));assert.equal(result.changes.find(change=>change.resource===source).after,opaque.text);}
  if(sample>=0){plans.push(planned-start);handling.push(handled-planned);bytes=Buffer.byteLength(JSON.stringify(result));}
 }
 results.push({mode,worker:stats(plans),resultSerialization:stats(handling),resultBytes:bytes});
}
process.stdout.write(JSON.stringify({kind:'headless-file-impact-diagnostic',node:process.versions.node,...options,warmups:4,captureMs,inputBytes:Buffer.byteLength(JSON.stringify({...input,moveSource:opaque,manifest})),results},null,2)+'\n');
