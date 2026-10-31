const assert = require('node:assert/strict');
const {test} = require('node:test');
const YAML = require('yaml');
const {analyse, inspect, propose} = require('./dist/model.cjs');
const {SourceDocument} = require('./dist/document.cjs');

const versions = ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','2.0','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function packet(version, format, schemas = {Record: {}}) {
    const value = {...(version === '2.0' ? {swagger: version, definitions: schemas} : {openapi: version, components: {schemas}}),
        info: {title: 'Native field forms 雪😀', version: 'business'}, paths: {},
        'x-number': '@exact', 'x-payload': {$ref: 'literal.json', items: false, additionalProperties: []}};
    const root = 'file:///controlled/forms.' + format;
    const text = (format === 'yaml' ? '# Keep source\r\n' + YAML.stringify(value).replaceAll('\n', '\r\n') : JSON.stringify(value) + '\r\n').replaceAll('"@exact"', '9007199254740993.00').replaceAll('@exact', '9007199254740993.00');
    return {root, resource: root, snapshot: version + format, resources: [{id: root, text, generation: 7, identity: 'original'}]};
}
function target(input, pointer) {
    const page = inspect({...input, pointer});
    return {...page, expected: input.resources.find(item => item.id === page.resource).text.slice(...page.range)};
}
function apply(input, plan) {
    return {...input, resources: input.resources.map(resource => {
        let text = resource.text;
        for (const edit of [...plan.edits].filter(edit => edit.buffer === resource.id).sort((a, b) => b.start - a.start)) {
            assert.equal(text.slice(edit.start, edit.end), edit.expected);
            text = text.slice(0, edit.start) + edit.replacement + text.slice(edit.end);
        }
        return {...resource, text};
    })};
}

for (const version of versions) for (const format of ['yaml', 'json']) test(`${version} ${format} native schema field forms retain their own valid data shapes`, () => {
    const input = packet(version, format), before = input.resources[0].text;
    const pointer = version === '2.0' ? '/definitions/Record' : '/components/schemas/Record';
    const owner = target(input, pointer);
    const names = version === '2.0' ? ['items', 'additionalProperties'] : ['items', 'additionalProperties', 'not'];
    for (const name of names) {
        const field = owner.fields.find(field => field.name === name);
        const boolean = name === 'additionalProperties' || !['2.0', '3.0'].includes(owner.family);
        const tuple = version === '2.0' && name === 'items';
        assert.deepEqual(field.schemaValueForms, {version: 1, supported: true, forms: ['object', ...(boolean ? ['boolean'] : []), ...(tuple ? ['object-array'] : [])]});
        for (const [raw, allowed] of [['{}', true], ['{"type":"integer","minimum":9007199254740993.00,"description":"雪😀"}', true], ['true', boolean], ['false', boolean], ['[]', tuple], ['[false]', false], ['[{"type":"string"}]', tuple]]) {
            const action = {kind: 'setData', pointer: pointer + '/' + name, raw, schemaValueForms: field.schemaValueForms};
            if (!allowed) assert.throws(() => propose({...input, target: owner, actions: [action]}), error => error.code === 'edit.schema.value');
            else {
                const changed = apply(input, propose({...input, target: owner, actions: [action]}));
                assert.equal(new SourceDocument(changed.resources[0].text, input.root).dataJson(action.pointer), raw);
                const check = analyse(changed);
                assert.equal(check.status, 'complete', JSON.stringify(check.findings));
                assert.equal(check.versions.authoringFieldRules, '1');
                assert(changed.resources[0].text.includes('9007199254740993.00'));
                assert(changed.resources[0].text.includes('literal.json'));
                if (format === 'yaml') assert(changed.resources[0].text.startsWith('# Keep source\r\n'));
            }
            assert.equal(input.resources[0].text, before);
        }
    }
    assert(!owner.fields.find(field => field.name === 'example').schemaValueForms);
    assert(!analyse(input).references.some(reference => reference.value === 'literal.json'));
});

for (const version of versions.filter(version => /^3\.[12]\./.test(version))) for (const format of ['yaml', 'json']) test(`${version} ${format} explicit unsupported dialects supply no assumed schema value forms`, () => {
    const base = packet(version, format);
    for (const dialect of ['https://dialects.invalid/custom', 'urn:busyapi:schema-dialect:swagger-2.0', null]) {
        const doc = new SourceDocument(base.resources[0].text, base.root);
        const input = {...base, resources: [{...base.resources[0], text: doc.set('/jsonSchemaDialect', dialect)}]};
        const owner = target(input, '/components/schemas/Record');
        const field = owner.fields.find(field => field.name === 'items');
        assert.deepEqual(field.schemaValueForms, {version: 1, supported: false, forms: []});
        assert.throws(() => propose({...input, target: owner, actions: [{kind: 'setData', pointer: owner.pointer + '/items', raw: '{}', schemaValueForms: field.schemaValueForms}]}), error => error.code === 'edit.schema.dialect.unsupported' && error.kind === 'unsupported');
        assert.equal(input.resources[0].text, doc.set('/jsonSchemaDialect', dialect));
    }
});

for (const format of ['yaml', 'json']) test(`${format} changed containing declarations reject a pending shared-schema value form`, () => {
    const input = packet('3.1.2', format, {Record: {$ref: 'shared.' + format + '#/Shared'}});
    const shared = 'file:///controlled/shared.' + format;
    input.resources.push({id: shared, text: format === 'yaml' ? '# Keep shared\r\nShared: {}\r\n' : '{"Shared":{}}\r\n', generation: 3, identity: 'shared'});
    const captured = target({...input, resource: shared}, '/Shared');
    const items = captured.fields.find(field => field.name === 'items');
    const condition = captured.fields.find(field => field.name === 'if');
    const changed = {...input, resources: input.resources.map(resource => resource.id === input.root ? {...resource, text: resource.text.replace('3.1.2', '3.0.4'), generation: 8} : resource)};
    for (const field of [items, condition]) assert.throws(() => propose({...changed, target: captured,
        actions: [{kind: 'setData', pointer: '/Shared/' + field.name, raw: 'true', schemaValueForms: field.schemaValueForms}]}), error => error.code === 'edit.stale');
    const fresh = target({...changed, resource: shared}, '/Shared');
    const currentItems = fresh.fields.find(field => field.name === 'items');
    assert.deepEqual(currentItems.schemaValueForms.forms, ['object']);
    const action = {kind: 'setData', pointer: '/Shared/items', raw: '{}', schemaValueForms: currentItems.schemaValueForms};
    const result = apply(changed, propose({...changed, target: fresh, actions: [action]}));
    assert.equal(result.resources[0].text, changed.resources[0].text);
    assert.equal(analyse(result).status, 'complete');
    assert.equal(changed.resources[1].text, input.resources[1].text);
});

for (const format of ['yaml', 'json']) test(`${format} a staged declaration change cannot retain the old schema value forms`, () => {
    const input = packet('3.1.2', format), original = input.resources[0].text;
    const root = target(input, ''), schema = target(input, '/components/schemas/Record');
    const field = schema.fields.find(field => field.name === 'items');
    assert.throws(() => propose({...input, target: root, actions: [
        {kind: 'set', pointer: '/openapi', value: '3.0.4'},
        {kind: 'setData', pointer: schema.pointer + '/items', raw: 'true', schemaValueForms: field.schemaValueForms},
    ]}), error => error.code === 'edit.stale');
    assert.equal(input.resources[0].text, original);
});
