const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {planDiagnosticFix}=require('./dist/diagnostic_fixes.cjs');

for(const openapi of ['3.1.2','3.2.1'])for(const json of [false,true])test(`source-owned path repair ${openapi} ${json?'JSON':'YAML'} preserves unrelated bytes`,()=>{
 const root='file:///fix/root.'+(json?'json':'yaml'),part='file:///fix/parameter.'+(json?'json':'yaml');
 const api={openapi,info:{title:'Repair',version:'1'},paths:{'/p/{id}':{parameters:[{$ref:part+'#/Parameter'}],get:{responses:{204:{description:'No body'}}}}}};
 const fragment=json?' {"Parameter":{"name":"id", "in":"path", "required":false, "schema":{"type":"string"}},"example":{"number":9007199254740993.00,"$ref":"literal"}}':
  '# keep 😀\r\nParameter:\r\n  name: \'id\'\r\n  in: path\r\n  required: false # keep scalar comment\r\n  schema: {type: string}\r\nexample: {number: 9007199254740993.00, $ref: literal}';
 const resources=[{id:root,text:json?JSON.stringify(api):YAML.stringify(api),generation:3,identity:'root'},{id:part,text:fragment,generation:9,identity:'parameter'}];
 const input={root,snapshot:'current',resources},diagnostic=analyse(input).findings.find(f=>f.code==='parameter.path.required');
 assert.deepEqual(diagnostic.fixes,['path-parameter-required']);
 const node=new SourceDocument(fragment,part).node('/Parameter');
 const planInput={...input,contexts:[{root,resources:[root,part]}],target:{root,resource:part,pointer:'/Parameter',range:node.range,expected:fragment.slice(...node.range),generation:9},diagnostic,fix:'path-parameter-required'};
 const plan=planDiagnosticFix(planInput);
 assert.equal(plan.kind,'diagnostic-fix');assert.equal(plan.edits.length,1);assert.equal(plan.edits[0].buffer,part);assert.equal(plan.usages[0].pointer,'/paths/~1p~1{id}/parameters/0');
 assert.equal(plan.changes[0].after,fragment.replace('false','true'));
 assert.equal(plan.changes[0].before,fragment);assert.equal(resources[1].text,fragment);
 const checked=analyse({...input,resources:resources.map(r=>r.id===part?{...r,text:plan.changes[0].after}:r)});
 assert(!checked.findings.some(f=>f.code.startsWith('parameter.')));
 assert(!JSON.stringify(checked.operations[0].value).includes('content'));
 assert.throws(()=>planDiagnosticFix({...planInput,diagnostic:{...diagnostic,range:[0,1]}}),e=>e.code==='fix.stale');
 assert.throws(()=>planDiagnosticFix({...planInput,fix:'invent-parameter'}),e=>e.code==='fix.unsupported');
 assert.throws(()=>planDiagnosticFix({...planInput,target:{...planInput.target,expected:'not the source'}}),e=>e.code==='fix.target');
 const missing=json?fragment.replace('"required":false, ',''):fragment.replace('  required: false # keep scalar comment\r\n','');
 const missingInput={...input,resources:resources.map(r=>r.id===part?{...r,text:missing}:r)};
 const missingDiagnostic=analyse(missingInput).findings.find(f=>f.code==='parameter.path.required'),missingNode=new SourceDocument(missing,part).node('/Parameter');
 const missingPlan=planDiagnosticFix({...planInput,...missingInput,diagnostic:missingDiagnostic,target:{...planInput.target,range:missingNode.range,expected:missing.slice(...missingNode.range)}});
 assert.equal(new SourceDocument(missingPlan.changes[0].after,part).node('/Parameter/required').value,true);
 assert(missingPlan.changes[0].after.includes('9007199254740993.00'));
});
test('aliased path definitions do not advertise a repair that expands shared syntax',()=>{
 const root='file:///fix/alias.yaml',text='openapi: 3.2.1\ninfo: {title: A, version: "1"}\ncomponents:\n  parameters:\n    Shared: &p {name: id, in: path, required: false, schema: {type: string}}\npaths:\n  /p/{id}:\n    get: {parameters: [*p], responses: {204: {description: None}}}\n';
 const result=analyse({root,snapshot:'alias',resources:[{id:root,text,generation:1,identity:'alias'}]});
 assert(result.findings.some(f=>f.code==='parameter.path.required'));
 assert(result.findings.filter(f=>f.code==='parameter.path.required').every(f=>!f.fixes));
});
