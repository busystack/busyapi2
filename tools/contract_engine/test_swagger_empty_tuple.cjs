const assert = require('node:assert/strict');
const {test} = require('node:test');
const YAML = require('yaml');
const {analyse} = require('./dist/model.cjs');
const {evaluateSchemas, schemaProducer} = require('./dist/schema_evaluation.cjs');
const {deriveBundle} = require('./dist/derived_bundle.cjs');
const {referenceDocument} = require('./dist/reference_projection.cjs');
const {planMigration} = require('./dist/migration.cjs');
const {SourceDocument} = require('./dist/document.cjs');

const samples = ['[]', '[null,false,0,"",{},[],{"$ref":"literal","n":9007199254740993.00}]', 'null', 'false', '0', '{}'];
const expected = [true, true, false, false, false, false];
function capture(format, kind = 'definition') {
    const root = 'file:///controlled/tuple.' + format, schema = {type: 'array', items: []};
    const value = {swagger: '2.0', info: {title: 'Keep empty tuple', version: 'business'}, host: 'api.example.invalid', basePath: '/v1', schemes: ['https'], paths: {}, 'x-number': '@exact', 'x-payload': {$ref: 'literal.json'}};
    let pointer = '/definitions/List';
    if (kind === 'body') {
        value.paths['/data'] = {post: {parameters: [{name: 'body', in: 'body', schema}], responses: {204: {description: 'No content'}}}};
        pointer = '/paths/~1data/post/parameters/0/schema';
    } else if (kind === 'response') {
        value.paths['/data'] = {get: {responses: {200: {description: 'Array', schema}}}};
        pointer = '/paths/~1data/get/responses/200/schema';
    } else value.definitions = {List: kind === 'composition' ? {allOf: [schema]} : kind === 'shared' ? {$ref: 'shared.' + format + '#/first'} : schema};
    const emit = value => (format === 'yaml' ? '# Keep tuple source\r\n' + YAML.stringify(value).replaceAll('\n', '\r\n') : JSON.stringify(value) + '\r\n').replaceAll('"@exact"', '9007199254740993.00').replaceAll('@exact', '9007199254740993.00');
    const resources = [{id: root, text: emit(value), generation: 3, identity: 'original'}];
    if (kind === 'shared') resources.push({id: 'file:///controlled/shared.' + format, text: emit({first: {$ref: '#/a~1b'}, 'a/b': schema}), generation: 5, identity: 'shared'});
    return {root, snapshot: format + kind, resources, pointer};
}
const instances = (root, pointer) => samples.map(text => ({subject: 'response-body', location: 'application/json', text, schema: {resource: root, pointer}}));

for (const format of ['yaml', 'json']) for (const kind of ['definition', 'body', 'response', 'composition', 'shared']) test(`Swagger ${format} ${kind} empty items tuple validates, evaluates, renders and bundles without source conversion`, async () => {
    const input = capture(format, kind), original = input.resources.map(resource => resource.text);
    const structural = analyse(input);
    assert.equal(structural.status, 'complete', JSON.stringify(structural.findings));
    assert.equal(structural.versions.swaggerSchemaRules, '1');
    const result = await evaluateSchemas({...input, runtimeInstances: instances(input.root, input.pointer)});
    assert.equal(result.complete, true, JSON.stringify(result.findings));
    assert(!result.findings.some(finding => finding.severity === 'error'), JSON.stringify(result.findings));
    assert.deepEqual(result.runtimeEvaluations.map(row => row.valid), expected);
    assert(result.runtimeEvaluations.every(row => row.complete));
    assert.equal(referenceDocument(input).complete, true);
    const bundle = deriveBundle({...input, outputId: 'https://output.invalid/tuple.json'});
    const value = JSON.parse(bundle.output.text);
    assert.equal(value.swagger, '2.0');
    assert(!Object.hasOwn(value, 'openapi'));
    const bundledSource = new SourceDocument(bundle.output.text, bundle.output.id);
    assert([...bundledSource.nodes.values()].some(node => node.pointer.endsWith('/items') && Array.isArray(node.value) && node.value.length === 0));
    assert(bundle.output.text.includes('9007199254740993.00'));
    const bundled = {root: bundle.output.id, snapshot: 'bundled', resources: [{id: bundle.output.id, text: bundle.output.text, generation: 0}]};
    assert.equal(analyse(bundled).status, 'complete');
    const checked = await evaluateSchemas({...bundled, runtimeInstances: instances(bundle.output.id, input.pointer)});
    assert.equal(checked.complete, true, JSON.stringify(checked.findings));
    assert.deepEqual(checked.runtimeEvaluations.map(row => row.valid), expected);
    assert.deepEqual(input.resources.map(resource => resource.text), original);
});

for (const format of ['yaml', 'json']) for (const kind of ['flat-parameter', 'flat-header', 'flat-items', 'empty-composition', 'boolean-member', '3.0.4', '3.1.2', '3.2.1']) test(`${format} ${kind} keeps its existing items/composition restrictions`, async () => {
    const input = capture(format), doc = new SourceDocument(input.resources[0].text, input.root);
    let value = doc.root.value;
    if (/^3\./.test(kind)) value = {openapi: kind, info: value.info, paths: {}, components: {schemas: {List: {type: 'array', items: []}}}};
    else if (kind === 'empty-composition') value.definitions.List = {allOf: []};
    else if (kind === 'boolean-member') value.definitions.List.items = [false];
    else {
        delete value.definitions;
        if (kind === 'flat-header') value.responses = {Data: {description: 'Header', headers: {'X-Data': {type: 'array', items: []}}}};
        else value.parameters = {Data: {name: 'data', in: 'query', type: 'array', items: kind === 'flat-items' ? {type: 'array', items: []} : []}};
    }
    const text = format === 'yaml' ? '# Keep negative source\r\n' + YAML.stringify(value).replaceAll('\n', '\r\n') : JSON.stringify(value) + '\r\n';
    const packet = {...input, resources: [{...input.resources[0], text}]};
    const structural = analyse(packet);
    assert.equal(structural.status, 'invalid');
    assert(structural.findings.some(finding => finding.severity === 'error' && /\/(items|allOf)(?:\/|$)/.test(finding.pointer)), JSON.stringify(structural.findings));
    const semantic = await evaluateSchemas(packet);
    assert(semantic.findings.some(finding => finding.severity === 'error'), JSON.stringify(semantic.findings));
    assert.equal(packet.resources[0].text, text);
});

for (const format of ['yaml', 'json']) for (const targetVersion of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1']) test(`${format} empty Swagger tuple migrates faithfully through 3.0 to ${targetVersion} and back`, async () => {
    const input = capture(format), original = input.resources[0].text;
    const result = await planMigration({...input, targetVersion, destination: 'file:///output/review/'});
    assert.equal(result.status, 'faithfully-convertible', JSON.stringify(result.problems));
    assert.equal(result.complete, true);
    assert.equal(result.producerVersion, '26');
    const entry = result.outputs.find(output => output.id === result.outputRoot), doc = new SourceDocument(entry.text, entry.id);
    assert.equal(doc.root.value.openapi, targetVersion);
    assert.equal(doc.root.value.info.version, 'business');
    assert.equal(doc.dataJson('/components/schemas/List/items'), '{}');
    assert(entry.text.includes('9007199254740993.00'));
    const target = {root: result.outputRoot, snapshot: 'target', resources: result.outputs.map(output => ({id: output.id, text: output.text, generation: 0}))};
    assert.equal(analyse(target).status, 'complete');
    const evaluated = await evaluateSchemas({...target, runtimeInstances: instances(target.root, '/components/schemas/List')});
    assert.equal(evaluated.complete, true, JSON.stringify(evaluated.findings));
    assert.deepEqual(evaluated.runtimeEvaluations.map(row => row.valid), expected);
    const returned = await planMigration({...target, targetVersion: '2.0', destination: 'file:///output/returned/'});
    assert.equal(returned.status, 'faithfully-convertible', JSON.stringify(returned.problems));
    const back = {root: returned.outputRoot, snapshot: 'back', resources: returned.outputs.map(output => ({id: output.id, text: output.text, generation: 0}))};
    assert.equal(analyse(back).status, 'complete');
    const restored = await evaluateSchemas({...back, runtimeInstances: instances(back.root, '/definitions/List')});
    assert.equal(restored.complete, true, JSON.stringify(restored.findings));
    assert.deepEqual(restored.runtimeEvaluations.map(row => row.valid), expected);
    const nonempty = {...input, resources: [{...input.resources[0], text: new SourceDocument(original, input.root).set('/definitions/List/items', [{type: 'integer'}])}]};
    const blocked = await planMigration({...nonempty, targetVersion, destination: 'file:///output/blocked/'});
    assert.equal(blocked.status, 'blocked');
    assert.equal(blocked.outputs.length, 0);
    assert(blocked.problems.some(problem => problem.code === 'migration.schema.tuple' && problem.pointer.endsWith('/items')));
    assert.equal(input.resources[0].text, original);
});

test('tuple schema bindings and migrations have distinct captured proof identities', () => {
    assert.equal(schemaProducer.version, '1.18.0+45');
    assert(schemaProducer.configuration.includes('swagger-schema-rules-v1'));
    assert(schemaProducer.configuration.includes('compound-unicode-v1'));
});
