const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const os=require('node:os');
const path=require('node:path');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

test('a mock cannot report readiness with an unrelated native evaluation revision',{timeout:20000},async t=>{
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'busyapi-mock-revision-'));
 t.after(()=>fs.rm(directory,{recursive:true,force:true}));
 const engine=await fs.readFile(path.join(__dirname,'dist/engine.cjs'),'utf8');
 const marker='name: "hyperjump+busyapi-exact", version: "1.18.0+12"';
 assert.equal(engine.split(marker).length,2,'The controlled engine fixture must select exactly its schema producer identity');
 await fs.writeFile(path.join(directory,'engine.cjs'),engine.replace(marker,'name: "hyperjump+busyapi-exact", version: "obsolete-wire-evaluator"'));
 const helper=path.join(directory,'mock-server.cjs');
 await fs.copyFile(path.join(__dirname,'dist/mock-server.cjs'),helper);
 const input=mockStart({openapi:'3.0.4',info:{title:'Revision proof',version:'1'},paths:{'/p':{post:{responses:{204:{description:'Empty'}}}}}}),original=JSON.stringify(input);
 const result=await startMock(t,input,{helper,failure:true});
 assert.equal(result.event,'failed');assert.equal(result.failure.code,'mock.validation.revision');
 assert.equal(JSON.stringify(input),original);
});
