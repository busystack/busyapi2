const {test}=require('node:test');
const assert=require('node:assert/strict');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {resolveUri,documentUriBase}=require('./dist/reference_graph.cjs');
const {Parser}=require('commonmark');

function destinations(value,base){
    const walker=new Parser().parse(value).walker(),result=[];
    let event;
    while((event=walker.next()))if(event.entering&&['link','image'].includes(event.node.type))
        result.push(event.node.destination.startsWith('#')?event.node.destination:resolveUri(event.node.destination,base).href);
    return result;
}
function fixture(version,body){
    const root='file:///source/deep/api.yaml';
    const text=[`# Preserve original comments`,version==='2.0'?'swagger: "2.0"':`openapi: "${version}"`,body,'paths: {}',''].join('\r\n');
    return {root,snapshot:version+body,targetVersion:'3.2.1',destination:'file:///reviewed/copied/',resources:[{id:root,text,generation:3}]};
}
const cases=[
    'info: {title: Shared, version: "business", description: &docs "[Guide](../guide.md)"}\r\nx-literal: *docs # keep literal comment',
    'info: &info {title: Shared, version: "business", description: "[Guide](../guide.md)", x-exact: 9007199254740993.00}\r\nx-literal: *info # keep collection comment',
    'x-literal: &docs "![図](../image.svg) [Guide](?q=one#part) [local](#intro) `literal(../guide)`"\r\ninfo: {title: Shared, version: "business", description: *docs}',
    'x-keys: {&docs "[Guide](../guide.md)": 0}\r\nx-literal: *docs\r\ninfo: {title: Shared, version: "business", description: *docs}',
    'x-first: &docs "[First](../first)"\r\nx-literal: *docs\r\nx-second: &docs "[Second](../second)"\r\ninfo: {title: Shared, version: "business", description: *docs}',
    'info:\r\n  title: Shared\r\n  version: "business"\r\n  description: &docs |- # preserve block comment\r\n    [Guide](../guide)\r\n    `literal(../guide)`\r\nx-literal: *docs # keep block use',
];
for(const version of ['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])
for(const [index,body]of cases.entries())test(`${version} shared Markdown ${index} retains each literal value and rendered destination`,async()=>{
    const input=fixture(version,body),original=input.resources[0].text;
    const review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));assert.equal(review.producerVersion,'38');
    const output=review.outputs.find(output=>output.id===review.outputRoot);
    const before=new SourceDocument(original,input.root),after=new SourceDocument(output.text,output.id);
    assert.equal(before.dataJson('/x-literal'),after.dataJson('/x-literal'));
    for(const pointer of ['/x-first','/x-second','/x-keys'])if(before.nodes.has(pointer))assert.equal(before.dataJson(pointer),after.dataJson(pointer));
    assert(output.text.startsWith('# Preserve original comments\r\n'));
    if(body.includes('# keep'))assert(output.text.includes(body.slice(body.indexOf('# keep'))));
    if(body.includes('# preserve block comment'))assert(output.text.includes('# preserve block comment'));
    const source=createGraph(input).graph,targetInput={root:output.id,snapshot:'cold:'+review.identity,
        resources:review.outputs.map(output=>({id:output.id,text:output.text,generation:0}))},target=createGraph(targetInput).graph;
    const wanted=destinations(before.dataNode('/info/description').value,documentUriBase(source,source.scope(input.root,'/info')));
    const actual=destinations(after.dataNode('/info/description').value,documentUriBase(target,target.scope(output.id,'/info')));
    assert.deepEqual(actual,wanted);
    assert(review.presentationChanges.some(change=>change.resource===input.root&&change.pointer==='/info/description'));
    assert.equal(analyse(targetInput).status,'complete');
    const schemas=await evaluateSchemas(targetInput);assert.equal(schemas.complete,true,JSON.stringify(schemas.findings));
    assert.equal(input.resources[0].text,original);
});

for(const version of ['3.1.2','3.2.1'])test(`${version} a virtual alias descendant gets its own Markdown base without rounding schema values`,async()=>{
    const input=fixture(version,[
        'info: {title: Shared, version: "business"}',
        'components:',
        '  schemas:',
        '    A:',
        '      $id: https://models.invalid/a',
        '      type: object',
        '      properties:',
        '        value: &model',
        '          type: integer',
        '          enum: [9007199254740993.000]',
        '          default: 9007199254740993.000',
        '          description: "[Guide](../guide.md)"',
        '    B:',
        '      type: object',
        '      properties:',
        '        value: *model # keep use comment',
        'x-literal: *model',
    ].join('\r\n'));
    const before=input.resources[0].text,review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));
    const output=review.outputs.find(output=>output.id===review.outputRoot),original=new SourceDocument(before,input.root),after=new SourceDocument(output.text,output.id);
    const prefix='/components/schemas/';
    assert.equal(after.dataJson(prefix+'A'),original.dataJson(prefix+'A'));
    assert.equal(after.dataJson('/x-literal'),original.dataJson('/x-literal'));
    assert(output.text.includes('&model'));assert(output.text.includes('x-literal: *model'));
    assert(output.text.includes('# keep use comment'));
    assert(after.dataNode(prefix+'B/properties/value/description').value.includes('file:///source/guide.md'));
    assert.equal(after.dataJson(prefix+'B/properties/value/enum'),original.dataJson(prefix+'B/properties/value/enum'));
    assert(review.presentationChanges.some(change=>change.pointer===prefix+'B/properties/value'));
    const capture={root:output.id,snapshot:'cold:'+review.identity,resources:review.outputs.map(output=>({id:output.id,text:output.text,generation:0}))};
    const evaluated=await evaluateSchemas({...capture,runtimeInstances:['9007199254740993','9007199254740992'].flatMap(text=>['A','B'].map(name=>({
        subject:'response-body',location:'application/json',text:'{"value":'+text+'}',schema:{resource:output.id,pointer:prefix+name},
    })))});
    assert.equal(evaluated.complete,true,JSON.stringify(evaluated.findings));
    assert.deepEqual(evaluated.runtimeEvaluations.map(value=>value.valid),[true,true,false,false]);
    assert.equal(input.resources[0].text,before);
});

for(const value of ['','[Local](#intro)','[Guide](https://docs.invalid/guide)'])
test(`an unchanged shared Markdown value ${JSON.stringify(value)} retains its authored aliases`,async()=>{
    const body='info: {title: Shared, version: "business", description: &docs '+JSON.stringify(value)+'}\r\nx-literal: *docs';
    const input=fixture('3.2.1',body),review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));
    const output=review.outputs.find(output=>output.id===review.outputRoot);
    assert(output.text.includes(body));assert.deepEqual(review.presentationChanges,[]);
    assert.equal(input.resources[0].text,fixture('3.2.1',body).resources[0].text);
});
