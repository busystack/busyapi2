const {test}=require('node:test');
const assert=require('node:assert/strict');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');

const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const outside=[
    'x-type: &kind string # keep outside definition',
    'x-type-copy: *kind # keep outside consumer',
    'x-values: &values ["", "café", "東京"]',
    'x-values-copy: *values',
    'x-shape: &shape {type: *kind, enum: *values}',
    'x-shape-copy: *shape',
    'x-record: &record {number: 9007199254740993.00, empty: "", false: false, null: null, ref: {$ref: "literal-only"}}',
    'x-record-copy: *record',
    'x-false: &flag false',
    'x-false-copy: *flag',
    'x-zero: &zero 0',
    'x-zero-copy: *zero',
    'x-null: &nil null',
    'x-null-copy: *nil',
    'x-empty: &empty ""',
    'x-empty-copy: *empty',
].join('\r\n')+'\r\n';
const suffix='x-later-type: &kind integer # keep reused name\r\nx-later-copy: *kind\r\nx-spelling: "*kind &kind $ref are literal text"\r\n';
function render(text,id,format){return format==='yaml'?text:new SourceDocument(text,id).dataJson('')+'\n';}
function entry(version,schemas){return `openapi: "${version}"\r\ninfo: {title: Descendant aliases, version: "business"}\r\n`+
    'servers: [{url: "https://api.invalid"}]\r\npaths: {}\r\n'+schemas;}
function capture(version,format,external=false){
    const root='file:///descendant-aliases/api.'+format,models='file:///descendant-aliases/models.'+format;
    const scalar='type: *kind # keep type use\r\n      enum: *values\r\n      x-captured: *record\r\n'+
        '      x-false: *flag\r\n      x-zero: *zero\r\n      x-null: *nil\r\n      x-empty: *empty\r\n';
    let text,shared;
    if(external){
        text=entry(version,'components:\r\n  schemas:\r\n'+
            `    Scalar: {$ref: "models.${format}#/Scalar"}\r\n`+
            `    Object: {$ref: "models.${format}#/Object"}\r\n`+
            '    Alias: {$ref: "#/components/schemas/Scalar"}\r\n');
        shared=outside+'Scalar:\r\n  type: *kind\r\n  enum: *values\r\nObject:\r\n  type: object\r\n  required: [value]\r\n'+
            '  $defs:\r\n    Field:\r\n      '+scalar+
            '  properties:\r\n    value: {$ref: "#/Object/$defs/Field"}\r\n  additionalProperties: false\r\n'+suffix;
    }else{
        text=entry(version,outside+'components:\r\n  schemas:\r\n    Scalar:\r\n      '+scalar+
            '    Object:\r\n      type: object\r\n      required: [value]\r\n      properties:\r\n'+
            '        value: *shape # keep nested collection use\r\n      additionalProperties: false\r\n'+
            '    Alias: {$ref: "#/components/schemas/Scalar"}\r\n'+suffix);
    }
    return {root,snapshot:version+format+external,targetVersion:external?'3.0.4':'2.0',destination:'file:///reviewed/descendant-aliases/',
        resources:[{id:root,text:render(text,root,format),generation:2},
            ...(external?[{id:models,text:render(shared,models,format),generation:4}]:[])]};
}
function delivered(review){return {root:review.outputRoot,snapshot:'cold:'+review.identity,
    resources:review.outputs.map(output=>({id:output.id,text:output.text,generation:0}))};}
async function outcomes(input){
    const source=input.resources.find(resource=>resource.id===input.root),swagger=new SourceDocument(source.text,source.id).dataNode('/swagger')?.value==='2.0';
    const prefix=swagger?'/definitions':'/components/schemas';
    const strings=['null','false','0','""','"café"','"東京"','"other"','{}','[]'];
    const objects=['{}','{"value":""}','{"value":"café"}','{"value":false}','{"value":null}',
        '{"value":"other"}','{"value":"café","extra":0}','[]','null'];
    const cases=[...['Scalar','Alias'].flatMap(name=>strings.map(text=>({name,text}))),...objects.map(text=>({name:'Object',text}))];
    const scalarExpected=[false,false,false,true,true,true,false,false,false];
    const expected=[...scalarExpected,...scalarExpected,false,true,true,false,false,false,false,false,false];
    const checked=await evaluateSchemas({...input,runtimeInstances:['request-body','response-body'].flatMap(subject=>cases.map(({name,text})=>({
        subject,text,location:'application/json',schema:{resource:input.root,pointer:prefix+'/'+name},
    })))});
    assert.equal(checked.complete,true,JSON.stringify(checked.findings));assert(checked.runtimeEvaluations.every(value=>value.complete));
    assert.deepEqual(checked.runtimeEvaluations.map(value=>value.valid),[...expected,...expected]);
    return checked.runtimeEvaluations.map(value=>value.valid);
}
function outsidePreserved(before,after,format){
    for(const name of ['x-type','x-type-copy','x-values','x-values-copy','x-shape','x-shape-copy','x-record','x-record-copy',
        'x-false','x-false-copy','x-zero','x-zero-copy','x-null','x-null-copy','x-empty','x-empty-copy','x-later-type','x-later-copy','x-spelling'])
        assert.equal(after.dataJson('/'+name),before.dataJson('/'+name),name);
    assert.equal(after.dataNode('/x-type-copy').value,'string');assert.equal(after.dataNode('/x-later-copy').value,'integer');
    assert.equal(after.dataJson('/x-record/number'),'9007199254740993.00');
    if(format==='yaml'){assert(after.text.includes(outside));assert(after.text.includes(suffix));}
}

for(const version of versions)for(const format of ['yaml','json'])
test(`${version} ${format} descendant aliases with outside definitions survive native Swagger downgrade`,async()=>{
    const input=capture(version,format),original=input.resources[0].text,before=new SourceDocument(original,input.root);
    if(format==='yaml')assert.throws(()=>before.assertUnshared('/components/schemas',true),error=>error.code==='edit.shared');
    const sourceAnalysis=analyse(input);assert.equal(sourceAnalysis.status,'complete',JSON.stringify(sourceAnalysis.findings));
    const expected=await outcomes(input),review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));assert.equal(review.producerVersion,'40');
    assert.equal(review.status,'faithfully-convertible');assert.deepEqual(review.acceptedDecisions,[]);
    const output=delivered(review),checked=analyse(output);assert.equal(checked.status,'complete',JSON.stringify(checked.findings));
    assert.deepEqual(await outcomes(output),expected);
    const doc=new SourceDocument(output.resources.find(resource=>resource.id===output.root).text,output.root);
    outsidePreserved(before,doc,format);
    assert.equal(doc.dataNode('/components'),undefined);assert.equal(doc.dataNode('/definitions/Scalar/type').value,'string');
    assert.equal(doc.dataJson('/definitions/Scalar/x-captured'),before.dataJson('/components/schemas/Scalar/x-captured'));
    assert.deepEqual(doc.dataNode('/definitions/Object/properties/value').value,{type:'string',enum:['','café','東京']});
    const {graph}=createGraph(output),alias=graph.referenceAs(output.root,'/definitions/Alias','$ref','schema');
    assert.equal(alias.resolution,'resolved');assert.equal(alias.targetPointer,'/definitions/Scalar');
    if(format==='yaml'){
        doc.assertUnshared('/definitions',true);
        assert(doc.text.includes('# keep type use'));assert(doc.text.includes('# keep nested collection use'));
        assert(review.presentationChanges.some(change=>change.resource===input.root&&change.pointer==='/components/schemas/Scalar/type'));
        assert(review.presentationChanges.some(change=>change.resource===input.root&&change.pointer==='/components/schemas/Object/properties/value'));
    }
    assert.equal(input.resources[0].text,original);
});

for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} cross-resource schema copies materialize only nested aliases in the copied subtree`,async()=>{
    const input=capture(version,format,true),original=input.resources.map(resource=>resource.text),expected=await outcomes(input);
    const review=await planMigration(input);assert.equal(review.complete,true,JSON.stringify(review.problems));
    const output=delivered(review),checked=analyse(output);assert.equal(checked.status,'complete',JSON.stringify(checked.findings));
    assert.deepEqual(await outcomes(output),expected);
    const changed=review.changes.find(change=>change.resource===input.resources[1].id);
    const doc=new SourceDocument(changed.after,changed.destination);
    outsidePreserved(new SourceDocument(original[1],input.resources[1].id),doc,format);
    const {graph}=createGraph(output),field=graph.referenceAs(changed.destination,'/Object/properties/value','$ref','schema');
    assert.equal(field.resolution,'resolved');assert.equal(field.targetResource,output.root);
    assert(field.targetPointer.startsWith('/components/schemas/_migrated_'));
    const target=graph.docs.get(field.targetResource);assert.equal(target.dataNode(field.targetPointer+'/type').value,'string');
    assert.equal(target.dataJson(field.targetPointer+'/x-captured'),doc.dataJson('/x-record'));
    if(format==='yaml'){
        target.assertUnshared(field.targetPointer,true);
        assert(doc.text.includes('Scalar:\r\n  type: *kind\r\n  enum: *values\r\n'));
        assert(review.presentationChanges.some(change=>change.resource===input.resources[1].id&&change.pointer==='/Object/$defs/Field/type'));
    }
    assert.deepEqual(input.resources.map(resource=>resource.text),original);
});

test('a declaration-only upgrade leaves unrelated nested aliases and their ordinary edit guards intact',async()=>{
    const input={...capture('3.0.4','yaml'),targetVersion:'3.1.2'},original=input.resources[0].text;
    const before=new SourceDocument(original,input.root),schema=before.text.slice(...before.node('/components/schemas').range);
    const review=await planMigration(input);assert.equal(review.complete,true,JSON.stringify(review.problems));
    const output=review.outputs.find(output=>output.id===review.outputRoot),after=new SourceDocument(output.text,output.id);
    assert(after.text.includes(schema));outsidePreserved(before,after,'yaml');
    assert.throws(()=>after.assertUnshared('/components/schemas',true),error=>error.code==='edit.shared');
    assert.throws(()=>after.set('/components/schemas/Scalar/type','integer'),error=>error.code==='edit.shared');
    assert.equal(input.resources[0].text,original);
});
