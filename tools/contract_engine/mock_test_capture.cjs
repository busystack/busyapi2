const {createHash}=require('node:crypto');
const {deriveBundle}=require('./dist/derived_bundle.cjs');

function mockStart(document,options={},root='file:///mock-fixture/api.json') {
 const text=typeof document==='string'?document:JSON.stringify(document);
 const capture={root,snapshot:'0'.repeat(64),resources:[{id:root,text,generation:1,identity:createHash('sha256').update(text).digest('hex')}]};
 return capturedMockStart(capture,options);
}
function capturedMockStart(capture,options={}) {
 const derived=deriveBundle({...capture,outputId:'file:///mock-fixture/busyapi-mock.json'});
 if(derived.complete!==true)throw Error('The synthetic mock fixture did not form one complete bundle');
 return {version:1,snapshot:capture.snapshot,capture,derived:{id:derived.output.id,identity:derived.output.identity},...options};
}
module.exports={mockStart,capturedMockStart};
