const assert = require('node:assert/strict');
const { SourceDocument } = require('./dist/document.cjs');
const { analyse, propose } = require('./dist/model.cjs');
const resource = (text, format = 'yaml') => ({ id: 'file:///tmp/contract.' + format, text, generation: 1, identity: 'x' });
const apply = (r, actions, target = '/info') => {
    const n = new SourceDocument(r.text, r.id, true).node(target);
    const proposal = propose({ root: r.id, snapshot: 's', resources: [r], target: { resource: r.id, generation: 1, pointer: target, range: n.range, expected: r.text.slice(...n.range) }, actions });
    let text = r.text;
    for (const e of proposal.edits)
        text = text.slice(0, e.start) + e.replacement + text.slice(e.end);
    return text;
};
let tests = 0;
function test(name, fn) {
    try {
        fn();
        tests++;
        console.log('PASS ' + name);
    }
    catch (e) {
        console.error('FAIL ' + name, e);
        process.exitCode = 1;
    }
}
for (const version of ['3.1.2', '3.2.1'])
    for (const format of ['yaml', 'json'])
        test('authoring ' + version + ' ' + format, () => {
            let r = resource(format === 'json' ? JSON.stringify({ openapi: version, info: { title: 'API', version: '1' }, paths: {} }) : `openapi: ${version}\ninfo:\n  title: 'API' # keep\n  version: "1"\npaths: {}\n`, format);
            r.text = apply(r, [{ kind: 'set', pointer: '/info/title', value: 'Edited' }]);
            if (format === 'yaml')
                assert(r.text.includes("title: 'Edited' # keep"));
            const op = '/paths/~1things/get';
            r.text = apply(r, [{ kind: 'set', pointer: op, value: {} }]);
            r.text = apply(r, [{ kind: 'set', pointer: op + '/summary', value: 'Find things' }, { kind: 'set', pointer: op + '/parameters', value: [{ name: 'q', in: 'query', required: false, schema: { type: 'string' } }] }, { kind: 'set', pointer: op + '/responses/200', value: { description: 'OK', content: { 'application/json': { schema: { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] }, example: { name: '😀', '$ref': 'literal' } } } } }], op);
            const result = analyse({ root: r.id, snapshot: 's', resources: [r] });
            assert.equal(result.status, 'complete');
            assert.equal(result.operations.length, 1);
            assert.equal(result.references.length, 0);
            r.text = apply(r, [{ kind: 'remove', pointer: op + '/parameters/0' }], op);
            assert.equal(new SourceDocument(r.text, r.id).node(op + '/parameters').value.length, 0);
        });
test('third identical occurrence and UTF16 ranges', () => { let r = resource('openapi: 3.2.1\ninfo: {title: "😀", version: "1"}\npaths:\n  /a:\n    get: {summary: same}\n  /b:\n    get: {summary: same}\n  /c:\n    query: {summary: same}\n'); const original = r.text; r.text = apply(r, [{ kind: 'set', pointer: '/paths/~1c/query/summary', value: 'third' }], '/paths/~1c/query'); assert.equal(r.text, original.replace('query: {summary: same}', 'query: {summary: third}')); });
test('strict duplicates and trailing comma', () => {
    for (const text of ['{"a":1,"a":2}', '{"a":1,}', '// no\n{}'])
        assert.throws(() => new SourceDocument(text, 'x.json'));
    assert.throws(() => new SourceDocument('a: 1\na: 2\n', 'x.yaml'));
});
test('BOM excluded and mixed line endings preserved', () => { let r = resource('openapi: 3.1.2\r\ninfo:\n  title: "A" # c\r\n  version: "1"\npaths: {}'); const old = r.text; r.text = apply(r, [{ kind: 'set', pointer: '/info/title', value: 'B' }]); assert.equal(r.text, old.replace('"A"', '"B"')); });
test('block scalar comments extensions and numeric lexemes', () => { let r = resource('openapi: 3.1.2\ninfo:\n  title: A\n  version: "1"\n  description: |\n    hello\n    world\nx-count: 1.00\npaths: {}\n'); const old = r.text; r.text = apply(r, [{ kind: 'set', pointer: '/info/title', value: 'B' }]); assert.equal(r.text, old.replace('title: A', 'title: B')); });
test('flow maps insert remove comma boundaries', () => {
    for (const format of ['json', 'yaml']) {
        let d = new SourceDocument(format === 'json' ? ' {"a":1,"b":2,"c":3} ' : ' {a: 1, b: 2, c: 3} ', 'x.' + format);
        for (const key of ['a', 'b', 'c']) {
            const removed = new SourceDocument(d.remove('/' + key), 'x.' + format);
            assert.equal(removed.root.children.size, 2);
        }
        d = new SourceDocument(d.set('/d', 'four'), 'x.' + format);
        assert.equal(d.node('/d').value, 'four');
    }
});
test('block insertion/removal adjacent comments', () => { let d = new SourceDocument('a: 1 # first\nb: 2 # second\n', 'x.yaml'); d = new SourceDocument(d.set('/c', { type: 'string' }), 'x.yaml'); assert.equal(d.node('/c/type').value, 'string'); assert(d.text.includes('a: 1 # first\nb: 2 # second\n')); const removed = new SourceDocument(d.remove('/b'), 'x.yaml'); assert.equal(removed.node('/a').value, 1); assert.equal(removed.node('/c/type').value, 'string'); });
test('local escaped pointer recursion, payload ref stays data', () => { let r = resource('openapi: 3.2.1\ninfo: {title: API, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    X: {$ref: "schema.yaml#/a~1b"}\n'); const fragment = { id: 'file:///tmp/schema.yaml', text: 'a/b: {type: object, properties: {self: {$ref: "#/a~1b"}}}', generation: 1, identity: 'f' }; const result = analyse({ root: r.id, snapshot: 's', resources: [r, fragment] }); assert.equal(result.status, 'complete'); assert.equal(result.references.length, 2); });
test('version aware additionalOperations', () => { const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths:\n  /a:\n    query: {}\n    additionalOperations:\n      COPY: {}\n'); const result = analyse({ root: r.id, snapshot: 's', resources: [r] }); assert.deepEqual(result.operations.map(o => o.method), ['query', 'COPY']); });
test('alias visual mutation is refused', () => { const r = resource('info: &x {title: A, version: "1"}\nother: *x\n'); assert.throws(() => apply(r, [{ kind: 'set', pointer: '/info/title', value: 'B' }])); });
test('stale generation and expected text', () => { const r = resource('info: {title: A}'); assert.throws(() => propose({ resources: [r], target: { resource: r.id, generation: 0, pointer: '/info' }, actions: [] })); });
test('block operation move preserves sibling and extension bytes', () => { const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths:\n  /old:\n    get:\n      summary: "same" # authored\n      x-number: 1.00\n    post: {summary: sibling}\n'); const text = apply(r, [{ kind: 'moveOperation', method: 'put', path: '/new' }], '/paths/~1old/get'); const d = new SourceDocument(text, r.id); assert.equal(d.node('/paths/~1old/post/summary').value, 'sibling'); assert.equal(d.node('/paths/~1new/put/summary').value, 'same'); assert(text.includes('x-number: 1.00')); assert(text.includes('# authored')); });
test('block description replacement preserves following key and style', () => { let r = resource('openapi: 3.2.1\ninfo:\n  title: A\n  description: |\n    old words\n  version: "1"\npaths: {}\n'); r.text = apply(r, [{ kind: 'set', pointer: '/info/description', value: 'new words\n' }]); const d = new SourceDocument(r.text, r.id); assert.equal(d.node('/info/version').value, '1'); assert.equal(d.node('/info/description').value, 'new words\n'); assert(r.text.includes('description: |')); });
test('renaming key preserves response schema lexemes and property siblings', () => { let r = resource('info: {}\nresponses:\n  "200":\n    description: OK # unchanged\n    x-number: 1.00\n'); const text = apply(r, [{ kind: 'rename', pointer: '/responses/200', name: '201' }]); assert.equal(text, r.text.replace('"200"', '"201"')); });
test('new YAML flow operation changes path without reserializing fields', () => { let r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {}\n'); r.text = apply(r, [{ kind: 'set', pointer: '/paths/~1old/get', value: { summary: 'Before', responses: { 200: { description: 'OK' } } } }]); r.text = apply(r, [{ kind: 'moveOperation', method: 'put', path: '/new' }], '/paths/~1old/get'); const d = new SourceDocument(r.text, r.id); assert.equal(d.node('/paths/~1new/put/summary').value, 'Before'); });
test('non-BMP scalar changes use whole UTF16 pairs', () => { const r = resource('info: {title: "😀"}'); const n = new SourceDocument(r.text, r.id).node('/info'); const p = propose({ root: r.id, snapshot: 's', resources: [r], target: { resource: r.id, generation: 1, pointer: '/info', range: n.range }, actions: [{ kind: 'set', pointer: '/info/title', value: '🠀' }] }); const e = p.edits[0]; assert.equal(e.expected, '😀'); assert.equal(e.replacement, '🠀'); });
test('referenced Path Item operations retain physical ownership', () => { const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {/things: {$ref: "paths.yaml#/Things"}}'); const fragment = { id: 'file:///tmp/paths.yaml', text: 'Things: {query: {summary: QUERY, responses: {200: {description: OK}}}}', generation: 4, identity: 'f' }; const result = analyse({ root: r.id, snapshot: 's', resources: [r, fragment] }); assert.equal(result.status, 'complete'); assert.equal(result.operations[0].resource, fragment.id); assert.equal(result.operations[0].pointer, '/Things/query'); assert.equal(result.operations[0].generation, 4); assert.equal(result.operations[0].shared, true); });
test('schema property names and default responses are interpreted by context', () => { const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {/things: {get: {responses: {default: {$ref: "#/components/responses/Missing"}}}}}\ncomponents: {schemas: {Thing: {type: object, properties: {example: {$ref: "#/components/schemas/Missing"}}}}}'); const result = analyse({ root: r.id, snapshot: 's', resources: [r] }); assert.equal(result.references.length, 2); assert.equal(result.status, 'invalid'); assert.equal(result.findings.filter(d => d.code === 'reference.missing').length, 2); });
test('semantic type errors are contract diagnostics instead of helper crashes', () => { const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {/things: {get: {parameters: wrong, responses: {200: {description: OK}}}}}'); const result = analyse({ root: r.id, snapshot: 's', resources: [r] }); assert.equal(result.status, 'invalid'); assert(result.findings.some(d => d.code === 'parameter.container.type')); });
test('multiline descriptions and block sequence fields preserve valid indentation', () => { let r = resource('info: {title: A}\nparameters:\n  - name: q\n    in: query\n    description: short\n'); r.text = apply(r, [{ kind: 'set', pointer: '/parameters/0/description', value: 'first\nsecond' }, { kind: 'set', pointer: '/parameters/0/required', value: false }]); const d = new SourceDocument(r.text, r.id); assert.equal(d.node('/parameters/0/description').value, 'first\nsecond'); assert.equal(d.node('/parameters/0/required').value, false); });
test('raw JSON examples retain numeric lexemes in both source formats', () => {
    for (const format of ['yaml', 'json']) {
        const r = resource(format === 'yaml' ? 'info: {title: A}\nexample: null\n' : '{"info":{"title":"A"},"example":null}', format);
        r.text = apply(r, [{ kind: 'setExample', pointer: '/example', raw: '{ "integer": 9007199254740993, "number": 1.00 }' }]);
        assert(r.text.includes('9007199254740993'));
        assert(r.text.includes('1.00'));
        new SourceDocument(r.text, r.id);
    }
});
test('optional operation responses are not a legacy validity requirement', () => {
    for (const version of ['3.1.2', '3.2.1']) {
        const r = resource(`openapi: ${version}\ninfo: {title: A, version: "1"}\npaths: {/things: {get: {}}}`);
        assert.equal(analyse({ root: r.id, snapshot: 's', resources: [r] }).status, 'complete');
        r.text = r.text.replace('get: {}', 'get: {responses: {}}');
        const result = analyse({ root: r.id, snapshot: 's', resources: [r] });
        assert.equal(result.status, 'invalid');
        assert(result.findings.some(d => d.code === 'operation.responses.empty'));
    }
});
test('custom operation relocation cannot mistake its additionalOperations parent for a path', () => { const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {/things: {additionalOperations: {COPY: {summary: authored}}}}'); const original = r.text; assert.throws(() => apply(r, [{ kind: 'moveOperation', method: 'get', path: '/other' }], '/paths/~1things/additionalOperations/COPY'), e => e.code === 'edit.operation.custom'); assert.equal(r.text, original); });
test('embedded schema resource pointers resolve relative to their resource root', () => {
    const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {}\ncomponents: {schemas: {Thing: {$id: "embedded.json", $ref: "#/properties/Other", examples: [{"$ref": "payload"}]}}}');
    const result = analyse({ root: r.id, snapshot: 's', resources: [r] });
    assert.equal(result.status, 'invalid');
    assert.equal(result.references.length, 1);
    assert.equal(result.references[0].resolution, 'missing');
    assert.equal(result.references[0].targetResource, r.id);
    assert.equal(result.references[0].targetRange, undefined);
    assert.equal(result.references[0].resource, r.id);
    assert(result.findings.some(d => d.code === 'reference.missing'));
    r.text = r.text.replace('$ref: "#/properties/Other",', '$ref: "#/properties/Other", properties: {Other: false},');
    const valid = analyse({ root: r.id, snapshot: 's2', resources: [r] });
    assert.equal(valid.status, 'complete');
    assert.equal(valid.references[0].targetResource, r.id);
    assert.equal(valid.references[0].targetPointer, '/components/schemas/Thing/properties/Other');
});
test('method change within the same path preserves inherited context and siblings', () => {
    const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {/things: {parameters: [{name: q, in: query, schema: {type: string}}], get: {summary: authored}, post: {summary: sibling}}}');
    const text = apply(r, [{ kind: 'moveOperation', method: 'query', path: '/things' }], '/paths/~1things/get');
    assert.equal(text, r.text.replace('get: {summary: authored}', 'query: {summary: authored}'));
});
test('referenced response and parameter fragments receive context-specific structural checks', () => {
    const r = resource('openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {/things: {get: {parameters: [{$ref: "parts.yaml#/Parameter"}], responses: {200: {$ref: "parts.yaml#/Response"}}}}}');
    const fragment = { id: 'file:///tmp/parts.yaml', text: 'Parameter: {in: query, schema: {type: string}}\nResponse: {description: 12}', generation: 1, identity: 'p' };
    const result = analyse({ root: r.id, snapshot: 's', resources: [r, fragment] });
    assert.equal(result.status, 'invalid');
    const findings = result.findings.filter(d => d.code.startsWith('reference.target.'));
    assert(findings.length >= 2);
    assert(findings.some(d => d.code === 'reference.target.required'));
    assert(findings.some(d => d.code === 'reference.target.type'));
    assert(findings.every(d => d.resource === fragment.id));
    assert(findings.some(d => d.pointer.startsWith('/Parameter')));
    assert(findings.some(d => d.pointer.startsWith('/Response')));
});
test('native example projections retain authored JSON numeric lexemes',()=>{
 for(const format of ['yaml','json']){const r=resource(format==='yaml'?'openapi: 3.2.1\ninfo: {title: A, version: "1"}\npaths: {/things: {get: {responses: {200: {content: {application/json: {example: {id: 9007199254740993, value: 1.00}}}}}}}}':'{"openapi":"3.2.1","info":{"title":"A","version":"1"},"paths":{"/things":{"get":{"responses":{"200":{"content":{"application/json":{"example":{"id":9007199254740993,"value":1.00}}}}}}}}}',format);const result=analyse({root:r.id,snapshot:'s',resources:[r]});const text=result.operations[0].exampleTexts['200']['application/json'];assert(text.includes('9007199254740993'));assert(text.includes('1.00'));}
});
test('schema reference projections preserve boolean kind, siblings and occurrence provenance', () => {
 const r=resource(JSON.stringify({openapi:'3.2.1',info:{title:'T',version:'1'},paths:{'/x':{get:{responses:{'200':{description:'OK',content:{'application/json':{schema:{$ref:'#/components/schemas/Never',description:'authored sibling',maxLength:5}}}}}}}},components:{schemas:{Never:false}},tags:[{name:'data',metadata:{$ref:'not-a-dependency.yaml'}}]}),'json');
 const result=analyse({root:r.id,snapshot:'s',resources:[r]});
 assert.equal(result.references.filter(x=>x.value==='not-a-dependency.yaml').length,0);
 const projected=result.operations[0].referenceValue.responses['200'].content['application/json'].schema;
 assert.deepEqual(projected.allOf,[false,{description:'authored sibling',maxLength:5}]);
 assert.equal(result.references[0].targetResource,r.id);
});
test('OpenAPI 3.2 self identity never guesses a retrieval-relative reference as complete', () => {
 const r=resource(JSON.stringify({openapi:'3.2.1',$self:'https://contracts.example/api/root',info:{title:'T',version:'1'},paths:{},components:{schemas:{X:{$ref:'defs.yaml#/X'}}}}),'json');
 const part={id:'file:///tmp/defs.yaml',text:'{"X":false}',generation:1,identity:'x'};
 const result=analyse({root:r.id,snapshot:'s',resources:[r,part]});
 assert.equal(result.complete,false); assert.equal(result.status,'incomplete'); assert(!result.references.some(x=>x.targetResource===part.id));
});
test('moving to a path with context requires an explicit inheritance decision', () => {
 const r=resource('openapi: 3.1.2\ninfo: {title: T, version: "1"}\npaths:\n  /a:\n    get: {summary: original}\n  /b:\n    servers: [{url: /other}]\n    parameters: [{name: q, in: query, schema: {type: string}}]\n    post: {}\n');
 assert.throws(()=>apply(r,[{kind:'moveOperation',method:'get',path:'/b'}],'/paths/~1a/get'),/context/);
 const moved=apply(r,[{kind:'moveOperation',method:'get',path:'/b',context:'destination'}],'/paths/~1a/get');
 assert(moved.includes('servers: [{url: /other}]')); assert(moved.includes('post: {}'));
});
test('current CST scope outside a malformed sibling remains surgically editable',()=>{
 const r=resource('openapi: "3.1.2"\ninfo: {title: Original, version: "1"}\npaths: {}\ncomponents:\n  schemas:\n    Broken: [unclosed\n');
 const result=analyse({root:r.id,snapshot:'partial',resources:[r]});
 assert.equal(result.info.syntaxSafe,true);assert.equal(result.status,'invalid');assert.equal(result.complete,false);
 assert(result.findings.some(d=>d.category==='syntax'));
 const changed=apply(r,[{kind:'set',pointer:'/info/title',value:'Corrected'}],'/info');
 assert(changed.includes('title: Corrected')); assert(changed.endsWith('Broken: [unclosed\n'));
 assert.throws(()=>apply(r,[{kind:'set',pointer:'/components/schemas/Broken',value:{type:'string'}}],'/components'),/scope|syntax/i);
});
test('3.2 media type components and streaming item schemas retain reference ownership',()=>{
 const r=resource(JSON.stringify({openapi:'3.2.1',info:{title:'Media',version:'1'},paths:{},components:{mediaTypes:{Stream:{itemSchema:{$ref:'item.yaml'},example:{$ref:'payload data'}}}}}),'json');
 const item={id:'file:///tmp/item.yaml',text:'type: object\nproperties: {name: {type: string}}\n',generation:1,identity:'item'};
 const result=analyse({root:r.id,snapshot:'media',resources:[r,item]});
 assert.equal(result.status,'complete');assert.equal(result.references.length,1);assert.equal(result.references[0].pointer,'/components/mediaTypes/Stream/itemSchema/$ref');assert.equal(result.references[0].targetResource,item.id);
});
test('operation insertion refuses referenced destinations and aliases retain occurrence locations',()=>{
 const r=resource('openapi: 3.1.2\ninfo: {title: A, version: "1"}\npaths:\n  /a: {$ref: path.yaml}\n');
 assert.throws(()=>apply(r,[{kind:'set',pointer:'/paths/~1a/post',value:{}}]),/ownership|reference/);
 const anchored=resource('openapi: 3.1.2\ninfo: {title: A, version: "1"}\npaths:\n  /a: &path {get: {summary: Authored}}\n  /b: *path\n');
 const result=analyse({root:anchored.id,snapshot:'alias',resources:[anchored]});
 assert(result.operations.every(o=>o.shared));assert(result.operations[1].range[0]>anchored.text.indexOf('/b:'));assert.equal(apply(r,[{kind:'set',pointer:'/info/title',value:'B'}]).includes('$ref: path.yaml'),true);
});
console.log(tests + ' engine tests passed');
