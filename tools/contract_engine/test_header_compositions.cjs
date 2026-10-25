const {test} = require('node:test');
const assert = require('node:assert/strict');
const YAML = require('yaml');
const {evaluateSchemas} = require('./dist/schema_evaluation.cjs');

const versions = ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function fixture(version, format, headers, schemas = {}) {
  const root = 'file:///header-compositions/api.' + format;
  const document = {openapi: version, info: {title: 'Header compositions', version: '1'}, paths: {'/data': {get: {responses: {'204': {description: 'Values', headers}}}}}, components: {schemas}};
  const text = (format === 'yaml' ? YAML.stringify(document) : JSON.stringify(document)).replaceAll(format === 'yaml' ? 'EXACT' : '"EXACT"', '9007199254740993.00');
  const wire = (name, values, location = name) => ({subject: 'response-header', location, text: '', header: {resource: root, pointer: '/paths/~1data/get/responses/204/headers/' + name, name, values}});
  return {root, snapshot: 'header-compositions', resources: [{id: root, text, generation: 3}], wire};
}
for (const version of versions) for (const format of ['yaml', 'json']) {
  test(`${version} ${format} captured scalar/array/object compositions use whole original-schema proofs`, async () => {
    const primitive = {anyOf: [{type: 'integer', enum: [0, 'EXACT']}, {type: 'boolean', enum: [false]}, {type: 'string', enum: ['雪', '']}]};
    const input = fixture(version, format, {
      'X-Scalar': {schema: primitive},
      'X-Array': {schema: {type: 'array', minItems: 3, items: primitive}},
      'X-Object': {explode: true, schema: {type: 'object', required: ['a', 'b'], properties: {a: primitive, b: primitive}, additionalProperties: false}},
      'X-Choice': {schema: {oneOf: [{type: 'array', minItems: 2, items: {type: 'integer'}}, {type: 'object', required: ['a'], properties: {a: {type: 'boolean'}}, additionalProperties: false}]}},
    });
    const original = input.resources[0].text;
    const result = await evaluateSchemas({...input, runtimeInstances: [
      input.wire('X-Scalar', ['9007199254740993'], 'scalar-good'), input.wire('X-Scalar', ['wrong'], 'scalar-bad'),
      input.wire('X-Array', ['0,9007199254740993,false,雪'], 'array-good'), input.wire('X-Array', ['0,9007199254740992,false'], 'array-bad'),
      input.wire('X-Object', ['a=0,b=false'], 'object-good'), input.wire('X-Object', ['a=0,b=wrong'], 'object-bad'),
      input.wire('X-Choice', ['0,1'], 'choice-array'), input.wire('X-Choice', ['a,false'], 'choice-object'), input.wire('X-Choice', ['a,wrong'], 'choice-bad'),
    ]});
    assert.equal(result.complete, true, JSON.stringify(result.runtimeFindings));
    assert.deepEqual(result.runtimeEvaluations.map(value => [value.location, value.complete, value.valid]), [
      ['scalar-good', true, true], ['scalar-bad', true, false], ['array-good', true, true], ['array-bad', true, false],
      ['object-good', true, true], ['object-bad', true, false], ['choice-array', true, true], ['choice-object', true, true], ['choice-bad', true, false],
    ]);
    assert(result.runtimeFindings.every(finding => finding.location.endsWith('bad') && finding.schema.resource === input.root && finding.schema.range[1] > finding.schema.range[0]));
    assert.equal(input.resources[0].text, original);
  });
  test(`${version} ${format} reference siblings, extension annotations and empty collections retain native semantics`, async () => {
    const modern = !version.startsWith('3.0.');
    const input = fixture(version, format, {
      'X-Ref': {schema: {$ref: '#/components/schemas/Integer', type: 'string'}},
      'X-RefNot': {schema: {$ref: '#/components/schemas/Integer', not: {}}},
      'X-Extension': {schema: {'x-data': {$ref: 'literal'}}},
      'X-Empty': {schema: {type: 'array', maxItems: 0, items: {type: 'integer'}}},
      'X-OneEmpty': {schema: {type: 'array', minItems: 1, maxItems: 1, items: {type: 'string', enum: ['']}}},
      'X-FalseProperty': {schema: {type: 'object', required: ['a'], properties: {a: modern ? false : {not: {}}}}},
      'X-Null': {schema: modern ? {type: 'null'} : {type: 'string', nullable: true, enum: [null]}},
      'X-ExcludedNull': {schema: modern ? {type: ['null', 'string'], enum: ['allowed']} : {type: 'string', nullable: true, enum: ['allowed']}},
    }, {Integer: {type: 'integer'}});
    const result = await evaluateSchemas({...input, runtimeInstances: [
      input.wire('X-Ref', ['0'], 'ref'), input.wire('X-RefNot', ['0'], 'ref-not'), input.wire('X-Extension', ['literal'], 'extension'),
      input.wire('X-Empty', [''], 'empty'), input.wire('X-OneEmpty', [''], 'one-empty'), input.wire('X-FalseProperty', ['a,0'], 'false-property'),
      input.wire('X-Null', ['null'], 'null'), input.wire('X-ExcludedNull', ['null'], 'excluded-null'),
    ]});
    assert.equal(result.complete, true, JSON.stringify(result.runtimeFindings));
    assert.deepEqual(result.runtimeEvaluations.map(value => [value.location, value.complete, value.valid]), [
      ['ref', true, !modern], ['ref-not', true, !modern], ['extension', true, true], ['empty', true, true], ['one-empty', true, true], ['false-property', true, false],
      ['null', true, true], ['excluded-null', true, false],
    ]);
  });
}
for (const version of versions.filter(version => !version.startsWith('3.0.'))) test(`${version} type unions retain numeric precision and string assertions`, async () => {
  const input = fixture(version, 'json', {'X-Union': {schema: {type: ['integer', 'string'], minimum: 'EXACT', pattern: '^x'}}});
  const result = await evaluateSchemas({...input, runtimeInstances: [input.wire('X-Union', ['9007199254740993'], 'number'), input.wire('X-Union', ['x-value'], 'string'), input.wire('X-Union', ['9007199254740992'], 'bad')]});
  assert.equal(result.complete, true, JSON.stringify(result.runtimeFindings));
  assert.deepEqual(result.runtimeEvaluations.map(value => value.valid), [true, true, false]);
});
for (const version of ['3.1.2','3.2.1']) for (const format of ['yaml','json']) {
  test(`${version} ${format} wide primitive arrays do not consume the JavaScript call stack`, async () => {
    const input = fixture(version, format, {'X-Wide': {schema: {type: 'array', minItems: 2048, maxItems: 2048, items: {type: 'integer'}}}});
    const result = await evaluateSchemas({...input, runtimeInstances: [input.wire('X-Wide', [Array(2048).fill('0').join(',')])]});
    assert.equal(result.complete, true, JSON.stringify(result.runtimeFindings));
    assert.equal(result.runtimeEvaluations[0].valid, true);
  });
  test(`${version} ${format} candidate diagnostics preserve ordinary field errors`, async () => {
    const input = fixture(version, format, {'X-Value': {schema: {anyOf: [{type: 'integer'}, {type: 'string', pattern: '^x'}]}}}, {Body: {type: 'object', properties: {a: {type: 'integer'}, b: {type: 'string'}}}});
    const result = await evaluateSchemas({...input, runtimeInstances: [input.wire('X-Value', ['0'], 'header'), {subject: 'response-body', location: 'body', text: '{"a":"x","b":0}', schema: {resource: input.root, pointer: '/components/schemas/Body'}}]});
    assert.equal(result.complete, true, JSON.stringify(result.runtimeFindings));
    assert.equal(result.runtimeEvaluations.find(value => value.location === 'header').valid, true);
    for (const pointer of ['/a', '/b']) assert(result.runtimeFindings.some(finding => finding.location === 'body' && finding.pointer === pointer));
    assert(!result.runtimeFindings.some(finding => finding.location === 'header'));
  });
  test(`${version} ${format} untyped constraints include null and unsupported dialects never become annotation success`, async () => {
    const input = fixture(version, format, {'X-Null': {schema: {const: null}}});
    const result = await evaluateSchemas({...input, runtimeInstances: [input.wire('X-Null', ['null'])]});
    assert.equal(result.complete, true, JSON.stringify(result.runtimeFindings));
    assert.equal(result.runtimeEvaluations[0].valid, true);
    const document = {openapi: version, jsonSchemaDialect: 'https://unsupported.invalid/dialect', info: {title: 'Unsupported dialect', version: '1'}, paths: {'/data': {get: {responses: {'204': {description: 'Value', headers: {'X-Null': {schema: {'x-data': true}}}}}}}}};
    const unsupported = {...input, resources: [{id: input.root, generation: 4, text: format === 'json' ? JSON.stringify(document) : YAML.stringify(document)}]};
    const rejected = await evaluateSchemas({...unsupported, runtimeInstances: [input.wire('X-Null', ['null'])]});
    assert.equal(rejected.complete, false);
    assert(rejected.runtimeEvaluations.every(value => value.complete === false && value.valid === false));
  });
  test(`${version} ${format} primitive tuples keep positional schemas and closed tails`, async () => {
    const input = fixture(version, format, {'X-Tuple': {schema: {type: 'array', prefixItems: [{type: 'integer', enum: ['EXACT']}, {type: 'boolean'}, {type: 'string', enum: ['x']}], items: false}}});
    const result = await evaluateSchemas({...input, runtimeInstances: [input.wire('X-Tuple', ['9007199254740993,false,x'], 'good'), input.wire('X-Tuple', ['9007199254740992,false,x'], 'bad'), input.wire('X-Tuple', ['9007199254740993,false,x,extra'], 'tail')]});
    assert.equal(result.complete, true, JSON.stringify(result.runtimeFindings));
    assert.deepEqual(result.runtimeEvaluations.map(value => value.valid), [true, false, false]);
  });
  test(`${version} ${format} incomplete enumeration cannot establish invalidity or hide a complete schema proof`, async () => {
    const item = {anyOf: [{type: 'integer'}, {type: 'string'}]};
    const input = fixture(version, format, {
      'X-Proven': {schema: {type: 'array', minItems: 10, maxItems: 10, items: item}},
      'X-Limited': {schema: {type: 'array', minItems: 10, maxItems: 10, items: item, contains: {type: 'string'}, minContains: 10}},
    });
    const result = await evaluateSchemas({...input, runtimeInstances: [input.wire('X-Proven', [Array(10).fill('0').join(',')], 'proven'), input.wire('X-Limited', [Array(10).fill('0').join(',')], 'limited')]});
    assert.equal(result.complete, false);
    assert.deepEqual(result.runtimeEvaluations.map(value => [value.location, value.complete, value.valid]), [['proven', true, true], ['limited', false, false]]);
    assert(result.runtimeFindings.some(finding => finding.location === 'limited' && finding.code === 'runtime.response.header.unchecked' && finding.schema.range[1] > finding.schema.range[0]));
    assert(!result.runtimeFindings.some(finding => finding.location === 'proven'));
  });
}
