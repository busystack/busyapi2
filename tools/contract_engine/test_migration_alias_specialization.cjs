const {test}=require('node:test');
const assert=require('node:assert/strict');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');

const payloads=['{}','{"value":"café"}','{"value":false}','{"value":null}',
    '{"next":{}}','{"value":"root","next":{"value":"nested"}}','false','null'];
function fixture(version,target,flag,format){
    const legacy=version==='2.0',root='file:///shared-owners/api.yaml',model='file:///shared-owners/models.yaml';
    const body=legacy?'parameters: [{name: body, in: body, schema: {$ref: "models.yaml#/Model"}}]':
        'requestBody: {content: {application/json: {schema: {$ref: "models.yaml#/Model"}}}}';
    const response=legacy?'schema: {$ref: "models.yaml#/AliasModel"}':
        'content: {application/json: {schema: {$ref: "models.yaml#/AliasModel"}}}';
    const text=[
        '# Preserve entry source',legacy?'swagger: "2.0"':`openapi: "${version}"`,
        'info: {title: Shared ownership, version: "business"}',
        ...(legacy?['host: api.invalid','schemes: [https]','consumes: [application/json]','produces: [application/json]']:
            ['servers: [{url: "https://api.invalid"}]']),
        'paths:','  /value:','    post:',`      ${body}`,
        `      responses: {"200": {description: Reply, ${response}}}`,'',
    ].join('\r\n');
    const definitions=[
        '# Preserve schema comments and exact literals',
        `Flag: &flag {type: string, ${flag}: true}`,
        'Model: &model','  type: object',...(legacy?[]:['  required: [value]']),
        '  properties:','    value: *flag # retain property use','    next: {$ref: "#/Model"}',
        '  additionalProperties: false','  example: {value: neutral}',
        'AliasModel: *model # retain second semantic use',
        'x-model: *model # retain literal consumer','x-flag: *flag',
        'x-exact: &exact {number: 9007199254740993.000, empty: "", false: false, null: null}',
        'x-exact-copy: *exact','',
    ].join('\r\n');
    const input={root,snapshot:version+target+flag+format,targetVersion:target,destination:'file:///reviewed/owners/',
        resources:[{id:root,text,generation:3},{id:model,text:definitions,generation:5}]};
    if(format==='json'){
        input.root=root.replace('.yaml','.json');
        input.resources=input.resources.map(resource=>({id:resource.id.replace('.yaml','.json'),generation:resource.generation,
            text:new SourceDocument(resource.text,resource.id).dataJson('').replaceAll('models.yaml','models.json')}));
    }
    return input;
}
function delivered(review){return {root:review.outputRoot,snapshot:'cold:'+review.identity,
    resources:review.outputs.map(output=>({id:output.id,text:output.text,generation:0}))};}
async function outcomes(input,samples=payloads){
    const legacy=new SourceDocument(input.resources[0].text,input.root).dataNode('/swagger')?.value==='2.0';
    const instances=['request-body','response-body'].flatMap(subject=>samples.map(text=>({subject,text,location:'application/json',
        schema:{resource:input.root,pointer:'/paths/~1value/post/'+(subject==='request-body'?
            legacy?'parameters/0/schema':'requestBody/content/application~1json/schema':
            legacy?'responses/200/schema':'responses/200/content/application~1json/schema')},
    })));
    const checked=await evaluateSchemas({...input,runtimeInstances:instances});
    assert.equal(checked.complete,true,JSON.stringify(checked.findings));
    assert(checked.runtimeEvaluations.every(value=>value.complete),JSON.stringify(checked.runtimeFindings));
    return checked.runtimeEvaluations.map(value=>value.valid);
}

for(const [version,target]of [['2.0','3.0.4'],['2.0','3.2.1'],['3.0.4','3.1.2'],['3.0.4','3.2.1'],['3.1.2','3.0.4'],['3.2.1','3.0.4']])
for(const format of ['yaml','json'])for(const flag of version==='2.0'?['readOnly']:['readOnly','writeOnly'])
test(`${version} ${format} ${flag} shared directional owners migrate to ${target} without changing literal consumers`,async()=>{
    const input=fixture(version,target,flag,format),before=input.resources.map(resource=>resource.text),expected=await outcomes(input);
    const sourceAnalysis=analyse(input);assert.equal(sourceAnalysis.status,'complete',JSON.stringify(sourceAnalysis.findings));
    const review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));assert.equal(review.status,'faithfully-convertible');
    const output=delivered(review),checked=analyse(output);assert.equal(checked.status,'complete',JSON.stringify(checked.findings));
    assert.deepEqual(await outcomes(output),expected);
    const model=input.resources[1],change=review.changes.find(change=>change.resource===model.id);
    const source=new SourceDocument(model.text,model.id),copy=new SourceDocument(change.after,change.destination);
    for(const pointer of ['/x-model','/x-flag','/x-exact','/x-exact-copy'])assert.equal(copy.dataJson(pointer),source.dataJson(pointer),pointer);
    if(format==='yaml'){
        assert(change.after.includes('# Preserve schema comments and exact literals'));
        assert(change.after.includes('# retain property use'));assert(change.after.includes('# retain literal consumer'));
        assert(change.after.includes('x-exact: &exact'));assert(change.after.includes('x-exact-copy: *exact'));
        assert(review.presentationChanges.some(change=>change.resource===model.id&&change.pointer==='/x-model'));
    }
    assert.deepEqual(input.resources.map(resource=>resource.text),before);
    const repeated=await planMigration(input);assert.equal(repeated.identity,review.identity);assert.deepEqual(repeated.outputs,review.outputs);
});

for(const version of ['3.1.2','3.2.1'])test(`${version} aliased schema definitions and exact const values lower with captured reference owners`,async()=>{
    const input=fixture(version,'3.0.4','readOnly','yaml');
    input.resources[1].text=[
        '# Preserve definitions and literal source',
        'Model: &model','  type: object','  required: [value]','  $defs:',
        '    Field: &field {type: integer, const: 9007199254740993.000}',
        '  properties:','    value: {$ref: "#/Model/$defs/Field"}',
        'AliasModel: *model','x-model: *model','x-field: *field','',
    ].join('\r\n');
    const original=input.resources.map(resource=>resource.text),samples=['{}','{"value":9007199254740993}','{"value":9007199254740992}','false'];
    const expected=await outcomes(input,samples),review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));
    const output=delivered(review);assert.deepEqual(await outcomes(output,samples),expected);
    const changed=review.changes.find(change=>change.resource===input.resources[1].id);
    const copy=new SourceDocument(changed.after,changed.destination),before=new SourceDocument(original[1],input.resources[1].id);
    for(const pointer of ['/x-model','/x-field'])assert.equal(copy.dataJson(pointer),before.dataJson(pointer));
    const {graph}=createGraph(output);assert(graph.references.every(reference=>reference.resolution==='resolved'));
    assert.deepEqual(input.resources.map(resource=>resource.text),original);
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} a root anchor and aliased key retain independent values in the migrated copy`,async()=>{
    const root='file:///root-owner/api.yaml';
    const text=`--- &root\r\n# Keep root anchor context\r\nopenapi: &version "${version}"\r\ninfo: {&title title: Kept, version: "business"}\r\npaths: {}\r\nx-version: *version\r\nx-key: *title\r\n`;
    const input={root,snapshot:'root-'+version,targetVersion:'3.2.1',destination:'file:///reviewed/root/',resources:[{id:root,text,generation:1}]};
    const review=await planMigration(input);assert.equal(review.complete,true,JSON.stringify(review.problems));
    const output=review.outputs.find(output=>output.id===review.outputRoot),doc=new SourceDocument(output.text,output.id);
    assert.equal(doc.dataNode('/openapi').value,'3.2.1');assert.equal(doc.dataNode('/x-version').value,version);
    assert.equal(doc.dataNode('/x-key').value,'title');assert.equal(doc.dataNode('/info/title').value,'Kept');
    assert(output.text.includes('# Keep root anchor context'));assert.equal(input.resources[0].text,text);
});
