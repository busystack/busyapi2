const assert = require('node:assert/strict');
const {test} = require('node:test');
const {planMigration} = require('./dist/migration.cjs');
const {requestOperation} = require('./dist/execution.cjs');
const {SourceDocument} = require('./dist/document.cjs');
const {createGraph, analyse} = require('./dist/model.cjs');
const {evaluateSchemas} = require('./dist/schema_evaluation.cjs');

const publishedTargets = ['3.0.0', '3.0.1', '3.0.2', '3.0.3', '3.0.4', '3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1'];
function capture(body, extras = [], format = 'yaml') {
  const root = 'file:///approved/api.' + format;
  const resources = [{id: root, generation: 3, text: `# Original API\nswagger: '2.0'\ninfo: {title: Media, version: '1'}\nhost: api.invalid\nschemes: [https]\nbasePath: /v1\nconsumes: [application/json]\nproduces: [application/json]\n${body}`}, ...extras];
  if (format === 'json') for (const resource of resources) resource.text = new SourceDocument(resource.text, 'file:///fixture.yaml').dataJson('');
  return {root, snapshot: 'swagger-media-capture', destination: 'file:///review/migrated/',
    resources};
}
function operations(input) {
  const {graph} = createGraph(input);
  return graph.operations().map(operation => requestOperation({...input, resource: operation.source.resource,
    pointer: operation.source.pointer, occurrence: operation.occurrence}));
}
function reopened(result) {
  return {root: result.outputRoot, snapshot: 'cold-media', resources: result.outputs.map(output => ({
    id: output.id, generation: 0, text: output.text,
    aliases: Object.entries(result.manifest.resourceMappings).filter(([, path]) => path === output.path).map(([identity]) => identity).sort()
  }))};
}
function standalone(result) {
  const destination = 'file:///relocated/without-project/';
  return {root: new URL(result.entry, destination).href, snapshot: 'standalone-media', resources: result.outputs.map(output => ({
    id: new URL(output.path, destination).href, generation: 0, text: output.text
  }))};
}
for (const targetVersion of publishedTargets) for (const format of ['yaml', 'json']) {
  test(`${format} external body fragments retain their owner and operation-specific media in ${targetVersion}`, async () => {
    const filename = 'parameters.' + format, external = 'file:///approved/' + filename;
    const input = {...capture(`paths:
  /json:
    parameters: [{$ref: '${filename}#/chain'}]
    post:
      responses: {'204': {description: ok}}
  /text:
    post:
      consumes: [text/plain]
      parameters: [{$ref: '${filename}#/body'}]
      responses: {'204': {description: ok}}
`, [{id: external, generation: 7, text: `# External organization\nchain: {$ref: '#/body'}\nbody:\n  # Parameter comment\n  in: body\n  name: payload\n  required: true\n  description: Shared body\n  x-data: {literal: false, $ref: untouched}\n  schema:\n    # Schema comment\n    type: integer\n    enum: [9007199254740993, 0]\n`}], format), targetVersion};
    const before = input.resources.map(resource => resource.text);
    const result = await planMigration(input);
    assert.equal(result.status, 'faithfully-convertible', JSON.stringify(result.problems));
    assert.equal(result.complete, true);
    assert.equal(result.outputs.length, 2);
    assert.deepEqual(input.resources.map(resource => resource.text), before);
    const migrated = reopened(result);
    assert.equal(analyse(migrated).complete, true);
    const relocated = standalone(result);
    assert.equal(analyse(relocated).complete, true);
    assert.deepEqual(operations(relocated).map(plan => plan.requestBody.content.map(item => item.mediaType)), operations(migrated).map(plan => plan.requestBody.content.map(item => item.mediaType)));
    assert.deepEqual(operations(migrated).map(plan => [plan.operation.path, plan.requestBody.required, plan.requestBody.content.map(item => item.mediaType)]),
      operations(input).map(plan => [plan.operation.path, plan.requestBody.required, plan.requestBody.content.map(item => item.mediaType)]));
    const output = result.outputs.map(output => output.text).join('\n');
    if (format === 'yaml') {
      for (const comment of ['# Original API', '# External organization', '# Parameter comment', '# Schema comment']) assert(output.includes(comment), comment);
    }
    assert(output.includes('9007199254740993'));
    const fragment = result.outputs.find(output => output.path.startsWith('resources/'));
    const document = new SourceDocument(fragment.text, fragment.id);
    assert.equal(document.dataNode('/body/name'), undefined);
    assert.equal(document.dataNode('/body/in'), undefined);
    assert(document.dataNode('/body/content'));
    assert.equal(document.dataNode('/body/x-data/$ref').value, 'untouched');
    assert.equal(document.dataNode('/body/x-data/literal').value, false);
  });
  test(`${format} shared responses specialize produces while keeping exact examples in ${targetVersion}`, async () => {
    const input = {...capture(`paths:
  /json:
    get:
      responses: {'200': {$ref: '#/responses/Shared'}}
  /text:
    get:
      produces: [text/plain]
      responses: {'200': {$ref: 'response-chain.${format}'}}
responses:
  Shared:
    description: Shared response
    # Header comment
    headers: {X-Values: {type: array, items: {type: integer}, collectionFormat: csv}}
    schema: {type: integer}
    examples:
      application/json: 9007199254740993
      application/xml: false
    x-data: {$ref: literal, zero: 0}
`, [{id: 'file:///approved/response-chain.' + format, generation: 2, text: `# Response chain\n$ref: 'api.${format}#/responses/Shared'\n`}], format), targetVersion};
    const original = input.resources[0].text;
    const result = await planMigration(input);
    assert.equal(result.complete, true, JSON.stringify(result.problems));
    assert.equal(input.resources[0].text, original);
    const migrated = reopened(result);
    assert.equal(analyse(standalone(result)).complete, true);
    assert.deepEqual(operations(standalone(result)).map(plan => plan.responses.map(response => response.content.map(item => item.mediaType).sort())), operations(migrated).map(plan => plan.responses.map(response => response.content.map(item => item.mediaType).sort())));
    assert.deepEqual(operations(migrated).map(plan => plan.responses.map(response => response.content.map(item => item.mediaType).sort())),
      operations(input).map(plan => plan.responses.map(response => response.content.map(item => item.mediaType).sort())));
    const text = result.outputs[0].text;
    assert(text.includes('9007199254740993'));
    if (format === 'yaml') assert(text.includes('# Header comment'));
    const document = new SourceDocument(text, result.outputRoot);
    assert.equal(document.dataNode('/components/responses/Shared/x-data/$ref').value, 'literal');
    assert.equal(result.invariants.requests, 'effective-url-serialization-security-and-media');
  });
}
test('an invalid reusable Swagger response is not converted by following its forbidden reference', async () => {
  const input = {...capture("paths: {}\nresponses: {Invalid: {$ref: '#/responses/Other'}, Other: {description: ok}}\n"), targetVersion: '3.0.4'};
  const result = await planMigration(input);
  assert.equal(result.complete, false);
  assert.deepEqual(result.outputs, []);
  assert(result.problems.some(problem => problem.code.startsWith('migration.validation.structure.') && problem.pointer === '/responses/Invalid'));
});
for (const targetVersion of ['3.0.4', '3.1.2', '3.2.1']) for (const format of ['yaml', 'json']) {
  test(`${format} external body pointer escaping survives migration to ${targetVersion}`, async () => {
    const name = 'body /~?#雪';
    const input = capture(`paths: {/data: {post: {parameters: [{$ref: 'parameters.${format}#/body%20~1~0%3F%23%E9%9B%AA'}], responses: {'204': {description: ok}}}}}\n`,
      [{id: 'file:///approved/parameters.' + format, generation: 5, text: JSON.stringify({[name]: {in: 'body', name: 'payload', schema: {type: 'integer'}}})}], format);
    const result = await planMigration({...input, targetVersion});
    assert.equal(result.complete, true, JSON.stringify(result.problems));
    const after = standalone(result);
    assert.equal(analyse(after).complete, true);
    assert.equal(operations(after)[0].requestBody.content[0].mediaType, 'application/json');
  });
  for (const external of [false, true]) test(`${format} ${external ? 'external root' : 'local reusable'} bodies keep recursive schemas and independent schema consumers in ${targetVersion}`, async () => {
    const address = external ? `body.${format}` : '#/parameters/Body';
    const schemaAddress = address + (external ? '#/schema' : '/schema');
    const body = {in: 'body', name: 'payload', required: true, schema: {type: 'object', properties: {
      id: {type: 'integer'}, next: {$ref: schemaAddress}
    }, additionalProperties: false, default: {id: 0}}};
    const input = capture(`paths:
  /first:
    post:
      parameters: [{$ref: '${address}'}]
      responses: {'204': {description: ok}}
  /second:
    post:
      consumes: [text/plain, application/json]
      parameters: [{$ref: '${address}'}]
      responses: {'204': {description: ok}}
definitions:
  Kept: {type: string}
  Reuse: {$ref: '${schemaAddress}'}
${external ? '' : 'parameters:\n  Body: ' + JSON.stringify(body)}
`, external ? [{id: 'file:///approved/body.' + format, generation: 8, text: JSON.stringify(body)}] : [], format);
    const result = await planMigration({...input, targetVersion});
    assert.equal(result.complete, true, JSON.stringify(result.problems));
    const after = reopened(result), samples = ['{"id":9007199254740993,"next":{"id":0}}', '{"id":"wrong"}', '{"extra":false}'];
    const instances = (resource, pointer) => samples.map(text => ({subject: 'response-body', location: 'application/json', text, schema: {resource, pointer}}));
    const beforeProof = await evaluateSchemas({...input, runtimeInstances: instances(input.root, '/definitions/Reuse')});
    const afterProof = await evaluateSchemas({...after, runtimeInstances: instances(after.root, '/components/schemas/Reuse')});
    assert.equal(beforeProof.complete, true, JSON.stringify(beforeProof.findings));
    assert.equal(afterProof.complete, true, JSON.stringify(afterProof.findings));
    assert.deepEqual(beforeProof.runtimeEvaluations.map(item => item.valid), [true, false, false]);
    assert.deepEqual(afterProof.runtimeEvaluations.map(item => item.valid), beforeProof.runtimeEvaluations.map(item => item.valid));
    assert.equal(new SourceDocument(result.outputs[0].text, result.outputRoot).dataNode('/components/schemas/Kept/type').value, 'string');
    assert.deepEqual(operations(after).map(plan => plan.requestBody.content.map(item => item.mediaType).sort()), [['application/json'], ['application/json', 'text/plain']]);
  });
  test(`${format} nested Swagger header migration to ${targetVersion} is a precise representability blocker`, async () => {
    const input = capture("paths: {/data: {get: {responses: {'200': {description: ok, headers: {X-Values: {type: array, collectionFormat: csv, items: {type: array, collectionFormat: pipes, items: {type: integer}}}}}}}}}\n", [], format);
    const result = await planMigration({...input, targetVersion});
    assert.equal(result.status, 'blocked');
    assert.deepEqual(result.outputs, []);
    const problem = result.problems.find(problem => problem.code === 'migration.header.nested-collection');
    assert(problem, JSON.stringify(result.problems));
    assert.equal(problem.reason, 'target-representation');
    assert.equal(problem.resource, input.root);
    assert.equal(problem.pointer, '/paths/~1data/get/responses/200/headers/X-Values/items');
    assert(problem.range[1] > problem.range[0]);
  });
}
