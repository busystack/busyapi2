const assert = require('node:assert/strict');
const {test} = require('node:test');
const {createHash} = require('node:crypto');
const YAML = require('yaml');
const {analyse} = require('./dist/model.cjs');
const {evaluateSchemas} = require('./dist/schema_evaluation.cjs');
const {requestOperation} = require('./dist/execution.cjs');
const {planMigration} = require('./dist/migration.cjs');

const versions = ['3.0.0', '3.0.1', '3.0.2', '3.0.3', '3.0.4', '3.1.0', '3.1.1', '3.1.2', '3.2.0', '3.2.1'];
const formats = ['yaml', 'json'];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const render = (value, format) => (format === 'yaml' ? '# Keep Unicode 雪\r\n' + YAML.stringify(value).replaceAll('\n', '\r\n') : JSON.stringify(value)) + '\r\n';
const packet = (id, bytes, aliases = []) => ({version: 1, id, generation: 3, aliases, state: 'available', identity: hash(bytes), base64: bytes.toString('base64'), byteLength: bytes.length});

function fixture(version, format, kind = 'json') {
  const root = 'file:///approved/api.' + format, id = 'file:///approved/data/example.bin';
  const mediaType = {json: 'application/json', latin1: 'text/plain; charset=iso-8859-1', empty: 'text/plain', mime: 'multipart/form-data; boundary=Test'}[kind];
  const bytes = kind === 'json' ? Buffer.from('{"n":9007199254740993.00,"empty":"","null":null,"false":false,"zero":0,"unicode":"雪😀","$ref":"payload-only"}') :
    kind === 'empty' ? Buffer.alloc(0) : kind === 'latin1' ? Buffer.from([99, 97, 102, 233]) :
      Buffer.from('--Test\r\nContent-Disposition: form-data; name="label"\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\ncafé\r\n--Test--\r\n', 'latin1');
  const schema = kind === 'json' ? {type: 'object', required: ['n'], properties: {n: {type: 'integer', minimum: 9007199254740992}}} :
    kind === 'mime' ? {type: 'object', required: ['label'], properties: {label: {type: 'string', enum: ['café']}}} :
      {type: 'string', enum: [kind === 'empty' ? '' : 'café']};
  const media = {schema, examples: {Local: {externalValue: './data/example.bin'}}};
  const value = {openapi: version, info: {title: 'Original', version: 'business'}, servers: [{url: 'https://api.invalid'}],
    paths: {'/echo': {post: {requestBody: {required: true, content: {[mediaType]: media}}, responses: {200: {description: 'Reply', content: {[mediaType]: media}}}}}},
    'x-literal': {externalValue: 'data-only', $ref: 'data-only.json', n: 0, nil: null, flag: false}};
  const input = {root, snapshot: 'same-caller-tag', resources: [{id: root, generation: 2, text: render(value, format)}],
    exampleResources: [packet(id, bytes)], targetVersion: version.startsWith('3.2') ? '3.0.4' : version.startsWith('3.1') ? '3.2.1' : '3.1.2', destination: 'file:///separate/review/'};
  return {input, value, id, bytes, mediaType, schema};
}

function delivered(plan, destination = 'file:///separate/moved%20%E9%9B%AA/') {
  const aliases = path => Object.entries(plan.manifest.resourceMappings).filter(([, mapped]) => mapped === path).map(([uri]) => uri).sort();
  const resources = plan.outputs.map(output => ({id: new URL(output.path, destination).href, text: output.text, generation: 0, aliases: aliases(output.path)}));
  const exampleResources = plan.exampleOutputs.map(output => ({...packet(new URL(output.path, destination).href, Buffer.from(output.base64, 'base64'), aliases(output.path)), generation: 0}));
  return {root: new URL(plan.entry, destination).href, snapshot: 'cold-output', resources, exampleResources};
}

async function assertPortable(f, input = f.input) {
  const original = JSON.stringify(input);
  const plan = await planMigration(input);
  assert.equal(plan.complete, true, JSON.stringify(plan.problems));
  assert.equal(plan.producerVersion, '32');
  assert.equal(plan.exampleOutputs.length, 1);
  const copy = plan.exampleOutputs[0];
  if(input.resources[0].id.endsWith('.yaml'))assert(plan.outputs.find(value => value.id === plan.outputRoot).text.includes('# Keep Unicode 雪'));
  assert.equal(copy.identity, hash(f.bytes));
  assert.equal(copy.byteLength, f.bytes.length);
  assert.deepEqual(Buffer.from(copy.base64, 'base64'), f.bytes);
  assert.equal(copy.source.resource, f.id);
  assert.equal(copy.source.generation, 3);
  assert(copy.occurrences.length >= 1);
  assert(copy.occurrences.every(occurrence => occurrence.source.resource.startsWith('file:///approved/') && occurrence.source.pointer.endsWith('/externalValue')));
  assert(plan.manifest.resourceMappings && Object.values(plan.manifest.resourceMappings).includes(copy.path));
  assert.equal(copy.path, 'examples/' + hash(Buffer.from(f.id)).slice(0, 24) + '.bin');
  const reopened = delivered(plan);
  assert(reopened.resources.every(value => !value.aliases.some(alias => alias.startsWith('file:///approved/'))));
  const analysis = analyse(reopened);
  assert.equal(analysis.complete, true, JSON.stringify(analysis.findings));
  const checked = await evaluateSchemas(reopened);
  assert.equal(checked.complete, true, JSON.stringify(checked.findings));
  assert(checked.serializedEvaluations.length >= 2);
  assert(checked.serializedEvaluations.every(value => value.complete && value.valid), JSON.stringify(checked.findings));
  assert(checked.serializedEvaluations.every(value => value.external.identity === hash(f.bytes)));
  assert(!analysis.references.some(value => value.value === 'payload-only' || value.value === 'data-only.json'));
  const operation = requestOperation({...reopened, resource: reopened.root, pointer: '/paths/~1echo/post'});
  if(!f.mediaType.startsWith('multipart/')) {
    const selected = operation.requestBody.content.find(value => value.mediaType === f.mediaType).examples[0];
    assert.equal(selected.wireBase64, f.bytes.toString('base64'));
  }
  assert.deepEqual(YAML.parse(plan.outputs.find(value => value.id === plan.outputRoot).text)['x-literal'], f.value['x-literal']);
  assert.equal(JSON.stringify(input), original);
  const repeat = await planMigration(input);
  assert.equal(repeat.identity, plan.identity);
  assert.deepEqual(repeat.exampleOutputs, plan.exampleOutputs);
  return plan;
}

for(const version of versions) for(const format of formats) for(const kind of ['json', 'latin1', 'mime', 'empty']) {
  test(`${version} ${format} ${kind} migration publishes exact examples and cold reopens after relocation`, async () => {
    await assertPortable(fixture(version, format, kind));
  });
}
for(const targetVersion of versions) for(const format of formats) test(`${format} available example copy uses target ${targetVersion} rules`, async () => {
  const f = fixture('3.0.4', format);
  await assertPortable(f, {...f.input, targetVersion});
});
for(const format of formats) for(const logical of [false, true]) test(`${format} referenced Example defining base ${logical ? 'with $self' : 'with retrieval aliases'} survives changed output base`, async () => {
  const f = fixture(logical ? '3.2.1' : '3.1.2', format, 'latin1');
  f.input.targetVersion = '3.2.1';
  if(logical) f.value.$self = 'https://contracts.invalid/api.' + format;
  const fragment = 'file:///approved/definitions/examples.' + format;
  const alias = 'https://contracts.invalid/definitions/examples.' + format;
  const example = {externalValue: '../data/example.bin'};
  for(const media of [f.value.paths['/echo'].post.requestBody.content[f.mediaType], f.value.paths['/echo'].post.responses[200].content[f.mediaType]])
    media.examples = {Local: {$ref: './definitions/examples.' + format + '#/Example'}};
  f.input.resources = [{...f.input.resources[0], text: render(f.value, format)}, {id: fragment, text: render({Example: example}, format), generation: 0, aliases: [alias]}];
  f.input.exampleResources = [packet(f.id, f.bytes, ['https://contracts.invalid/data/example.bin'])];
  const plan = await assertPortable(f);
  assert(plan.exampleOutputs[0].occurrences.every(value => value.source.resource === fragment));
});
for(const format of formats) for(const condition of ['invalid', 'missing', 'denied', 'unsupported']) test(`${format} ${condition} example prevents every migration output`, async () => {
  const f = fixture('3.0.4', format);
  if(condition === 'invalid') f.input.exampleResources = [packet(f.id, Buffer.from('{"n":0}'))];
  if(condition === 'missing') f.input.exampleResources = [];
  if(condition === 'denied') f.input.exampleResources = [{version: 1, id: f.id, aliases: [], generation: 0, identity: hash(Buffer.from('denied')), state: 'unavailable', problem: {code: 'example.external-value.denied', message: 'Controlled denial', condition: 'unavailable'}}];
  if(condition === 'unsupported') {
    f.value.paths['/echo'].post.requestBody.content = {'application/xml': {schema: f.schema, examples: {Local: {externalValue: './data/example.bin'}}}};
    f.input.resources[0].text = render(f.value, format);
  }
  const before = JSON.stringify(f.input), plan = await planMigration(f.input);
  assert.equal(plan.complete, false);
  assert.deepEqual(plan.outputs, []);assert.deepEqual(plan.exampleOutputs, []);
  assert(plan.problems.some(value => value.code.startsWith('migration.validation.')));
  assert.equal(JSON.stringify(f.input), before);
});
for(const format of formats) test(`${format} byte identity changes invalidate a review even with a repeated caller snapshot tag`, async () => {
  const f = fixture('3.0.4', format);
  const first = await planMigration(f.input);
  const second = await planMigration({...f.input, exampleResources: [packet(f.id, Buffer.from('{"n":9007199254740994.00}'))]});
  assert.equal(first.complete, true);assert.equal(second.complete, true, JSON.stringify(second.problems));
  assert.notEqual(first.identity, second.identity);
  assert.notEqual(first.exampleOutputs[0].identity, second.exampleOutputs[0].identity);
});
for(const format of formats) test(`${format} inline and Swagger examples do not acquire or copy payload-looking keys`, async () => {
  const root = 'file:///approved/swagger.' + format;
  const payload = {externalValue: './data-only.bin', $ref: 'literal', empty: '', nil: null, flag: false, zero: 0};
  const value = {swagger: '2.0', info: {title: 'Payload', version: '1'}, host: 'api.invalid', schemes: ['https'], produces: ['application/json'], paths: {'/': {get: {responses: {200: {description: 'Reply', schema: {type: 'object'}, examples: {'application/json': payload}}}}}}};
  const plan = await planMigration({root, snapshot: 'swagger-control', resources: [{id: root, text: render(value, format), generation: 0}], targetVersion: '3.2.1', destination: 'file:///separate/review/'});
  assert.equal(plan.complete, true, JSON.stringify(plan.problems));assert.deepEqual(plan.exampleOutputs, []);
  const checked = await evaluateSchemas(delivered(plan));
  assert.equal(checked.complete, true, JSON.stringify(checked.findings));
});
for(const format of formats) {
  test(`${format} mixed-version roots share one approved byte copy and reopen each occurrence`, async () => {
    const f = fixture('3.0.4', format), secondary = 'file:///approved/secondary.' + format;
    const other = {...f.value, openapi: '3.2.1', info: {title: 'Secondary', version: 'business'}};
    f.input.resources.push({id: secondary, text: render(other, format), generation: 0});
    f.input.targetVersion = '3.2.1';
    const plan = await assertPortable(f), reopened = delivered(plan);
    assert.equal(plan.exampleOutputs[0].occurrences.length, 4);
    for(const entry of plan.manifest.roots) {
      const result = await evaluateSchemas({...reopened, root: new URL(entry.path, 'file:///separate/moved%20%E9%9B%AA/').href});
      assert.equal(result.complete, true, JSON.stringify(result.findings));
      assert(result.serializedEvaluations.every(value => value.complete && value.valid));
    }
  });
  test(`${format} unused captured bytes are owned inputs but never become output files`, async () => {
    const f = fixture('3.0.4', format);
    f.input.exampleResources.push(packet('file:///approved/unused.bin', Buffer.from('Keep unused')));
    const plan = await assertPortable(f);
    assert.equal(plan.affectedExampleResources.length, 2);
    assert.equal(plan.exampleOutputs.length, 1);
  });
  test(`${format} separate byte owners with equal contents retain separate copied provenance`, async () => {
    const f = fixture('3.0.4', format), other = 'file:///approved/data/other.bin';
    f.value.paths['/echo'].post.responses[200].content[f.mediaType] = {
      schema: f.schema, examples: {Other: {externalValue: './data/other.bin'}},
    };
    // The fixture shares one in-memory media value; replace just the response
    // occurrence before rendering, as two authored owners are distinct.
    f.value.paths['/echo'].post.requestBody.content = {[f.mediaType]: {
      schema: f.schema, examples: {Local: {externalValue: './data/example.bin'}},
    }};
    f.input.resources[0].text = render(f.value, format);
    f.input.exampleResources.push(packet(other, f.bytes));
    const plan = await planMigration(f.input);
    assert.equal(plan.complete, true, JSON.stringify(plan.problems));assert.equal(plan.exampleOutputs.length, 2);
    assert.deepEqual(plan.exampleOutputs.map(value => value.source.resource).sort(), [f.id, other].sort());
    assert.equal(new Set(plan.exampleOutputs.map(value => value.path)).size, 2);
    const checked = await evaluateSchemas(delivered(plan));
    assert.equal(checked.complete, true, JSON.stringify(checked.findings));
    assert(checked.serializedEvaluations.every(value => value.complete && value.valid));
  });
  test(`${format} a retained 3.2 document identity still reports its missing downgrade mapping`, async () => {
    const f = fixture('3.2.1', format, 'latin1');
    f.value.$self = 'https://contracts.invalid/api.' + format;
    f.input.resources[0].text = render(f.value, format);
    f.input.exampleResources[0].aliases = ['https://contracts.invalid/data/example.bin'];
    const original = JSON.stringify(f.input), plan = await planMigration(f.input);
    assert.equal(plan.complete, false);assert.deepEqual(plan.outputs, []);assert.deepEqual(plan.exampleOutputs, []);
    assert(plan.problems.some(value => value.code === 'migration.feature.newer' && value.pointer === '/$self'), JSON.stringify(plan.problems));
    assert.equal(JSON.stringify(f.input), original);
  });
}
test('example routes retain the established 256-mapping publication bound', async () => {
  const f = fixture('3.0.4', 'json', 'empty'), examples = {};
  f.input.exampleResources = [];
  for(let index = 0; index < 257; index++) {
    const path = './data/payload-' + index + '.bin';
    examples['E' + index] = {externalValue: path};
    f.input.exampleResources.push(packet(new URL(path, f.input.root).href, Buffer.alloc(0)));
  }
  for(const media of [f.value.paths['/echo'].post.requestBody.content[f.mediaType], f.value.paths['/echo'].post.responses[200].content[f.mediaType]]) media.examples = examples;
  f.input.resources[0].text = render(f.value, 'json');
  const plan = await planMigration(f.input);
  assert.equal(plan.complete, false);assert.deepEqual(plan.outputs, []);assert.deepEqual(plan.exampleOutputs, []);
  assert(plan.problems.some(value => value.code === 'limit.migration.mappings'), JSON.stringify(plan.problems));
});
