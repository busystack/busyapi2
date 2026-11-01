const assert = require('node:assert/strict');
const { test } = require('node:test');
const { assistSource, sourceFolds, semanticSearch } = require('./dist/source_assistance.cjs');
const YAML = require('yaml');
const fixture = (text, json = false) => {
    const caret = text.indexOf('§');
    assert(caret >= 0);
    text = text.replace('§', '');
    const root = 'file:///project/root.' + (json ? 'json' : 'yaml');
    return { root, resource: root, caret, snapshot: 'captured', resources: [{ id: root, text, generation: 7, identity: 'source' }] };
};
const apply = (input, suggestion) => {
    let text = input.resources[0].text;
    for (const edit of suggestion.edits) {
        assert.equal(edit.generation, 7);
        assert.equal(text.slice(edit.start, edit.end), edit.expected);
        text = text.slice(0, edit.start) + edit.replacement + text.slice(edit.end);
    }
    return text;
};
for(const version of ['3.1.2','3.2.1'])for(const json of [false,true])test(`Source assistance uses the containing document's legal fields ${version} ${json?'JSON':'YAML'}`,()=>{
 const family=version.slice(0,3),entry=family==='3.1'?'3.2.1':'3.1.2',suffix=json?'json':'yaml';
 const root='file:///approved/entry.'+suffix,part='file:///approved/part.'+suffix;
 const render=value=>json?JSON.stringify(value,null,2):YAML.stringify(value);
 const document={openapi:version,info:{title:'Part',version:'1'},paths:{},components:{pathItems:{Shared:{get:{responses:{'204':{description:'None'}}}}}}};
 const text=render(document),caret=json?text.indexOf('"get"')-1:text.indexOf('      get:')+6;
 const resources=[{id:root,text:render({openapi:entry,info:{title:'Entry',version:'1'},paths:{'/owned':{$ref:'part.'+suffix+'#/components/pathItems/Shared'}}}),generation:1},{id:part,text,generation:2}];
 const input={root,resource:part,caret,snapshot:'version-fields',resources};
 const result=assistSource(input);
 // YAML is positioned at the existing method key; JSON is between entries.
 // Both completion lists belong to its containing Path Item, not entry OAS.
 assert.equal(result.kind,json?'path-item':'operation');
 assert.equal(result.completions.some(item=>item.label==='query'),family==='3.2');
 assert.equal(result.completions.some(item=>item.label==='additionalOperations'),family==='3.2');
 assert(result.completions.every(item=>item.standard.includes('/v'+(family==='3.2'?'3.2.1':'3.1.2')+'.html#')));
 const help=assistSource({...input,caret:text.indexOf('description')+2,action:'help'});
 assert(help.help.standard.includes('/v'+(family==='3.2'?'3.2.1':'3.1.2')+'.html#'));
 assert.equal(help.help.dialect,`https://spec.openapis.org/oas/${family}/dialect/base`);
 assert.equal(resources[1].text,text);
});
test('folding is bounded by physical viewport and retains only requested collapsed ancestors',()=>{
 for(const json of [false,true]){
  const value={openapi:'3.2.1',info:{title:'Fold',version:'1'},paths:{},components:{schemas:{Model:{type:'object',properties:{one:{type:'string'},two:{type:'number'}}},Other:{type:'array',items:{type:'boolean'}}}}};
  const input=fixture((json?JSON.stringify(value,null,2):YAML.stringify(value))+'§',json);
  const all=sourceFolds(input);
  assert.equal(all.generation,7);assert.equal(all.complete,true);
  const model=all.folds.find(f=>f.pointer==='/components/schemas/Model');assert(model);
  const child=all.folds.find(f=>f.pointer==='/components/schemas/Model/properties');assert(child);
  const other=all.folds.find(f=>f.pointer==='/components/schemas/Other');assert(other);
  for(const f of all.folds){assert(f.header<=f.start);assert(f.start<f.end);assert(f.end<=input.resources[0].text.length);}
  const page=sourceFolds({...input,from:other.header,to:other.header+1,folded:[model.pointer]});
  assert.deepEqual(new Set(page.folds.map(f=>f.pointer)),new Set([model.pointer,other.pointer]));
  const hidden=sourceFolds({...input,from:child.header,to:child.header+1,folded:[model.pointer]});
  assert.deepEqual(hidden.folds.map(f=>f.pointer),[model.pointer]);
  for(const request of [{from:-1},{to:input.resources[0].text.length+1},{folded:['x'.repeat(16385)]},{folded:[null]}]){
   assert.throws(()=>sourceFolds({...input,...request}),e=>e.code==='assist.folds.range');
  }
 }
});
test('fold metadata includes block scalar/data structure without treating its payload as references',()=>{
 const input=fixture('openapi: 3.1.2\ninfo:\n  title: Fold\n  version: "1"\n  description: |\n    first 雪😀\n    second\npaths: {}\nx-data:\n  $ref: literal-data\n  lines:\n    - one\n    - two\n§');
 const found=sourceFolds(input).folds;
 assert(found.some(f=>f.pointer==='/info/description'&&f.kind==='scalar'));
 assert(found.some(f=>f.pointer==='/x-data/lines'&&f.kind==='array'));
 assert(!found.some(f=>f.pointer==='/x-data/$ref'));
 assert.equal(input.resources[0].text.includes('$ref: literal-data'),true);
});
for (const version of ['3.1.2', '3.2.1'])
    for (const json of [false, true]) {
        test(`contextual completion ${version} ${json ? 'JSON' : 'YAML'}`, () => {
            const input = fixture(json ? `{"openapi":"${version}","info":{"title":"Kept", § "version":"1"},"paths":{}}` : `# Kept\r\nopenapi: ${version}\r\ninfo:\r\n  title: Kept\r\n  version: '1'\r\n  §\r\npaths: {}`, json);
            const result = assistSource(input), summary = result.completions.find(c => c.label === 'summary');
            assert(summary);
            assert(!result.completions.some(c => c.label === 'title' || c.label === 'version'));
            const changed = apply(input, summary), value = json ? JSON.parse(changed) : YAML.parse(changed);
            assert.equal(value.info.summary, '');
            assert.equal(value.info.title, 'Kept');
            assert.equal(value.openapi, version);
            assert.equal(summary.edits[0].start, input.caret);
            assert.equal(summary.edits[0].end, input.caret);
            if (!json) {
                assert(changed.startsWith('# Kept\r\n'));
                assert(changed.includes("version: '1'"));
                assert(!/(?<!\r)\n/.test(changed));
            }
        });
        test(`located enum, definition and data help ${version} ${json ? 'JSON' : 'YAML'}`, () => {
            const value = { openapi: version, info: { title: 'Help', version: '1' }, paths: { '/things': { get: { responses: { '200': { description: 'None', content: { 'application/json': { schema: { $ref: '#/components/schemas/Model§' }, example: { $ref: 'literal payload data' } } } } } } } }, components: { schemas: { Model: { type: 'string' }, Another: false }, parameters: { P: { in: 'query', name: 'q', schema: { type: 'string' } } } } };
            const input = fixture(json ? JSON.stringify(value) : YAML.stringify(value), json);
            const help = assistSource({ ...input, action: 'help' });
            assert.equal(help.definition.pointer, '/components/schemas/Model');
            assert.equal(help.definition.resource, input.root);
            const suggestions = assistSource(input).completions;
            assert(suggestions.some(c => c.label === 'Another'));
            assert(!suggestions.some(c => c.label === 'P'));
            const valueType = json ? input.resources[0].text.indexOf('"type":"string"') + 9 : input.resources[0].text.indexOf('type: string') + 7;
            const enums = assistSource({ ...input, caret: valueType }).completions;
            assert(enums.some(c => c.label === 'null'));
            const payload = input.resources[0].text.indexOf('literal payload') + 3;
            const literal = assistSource({ ...input, caret: payload });
            assert.equal(literal.help.kind, 'data');
            assert.equal(literal.definition, undefined);
            assert.deepEqual(literal.completions, []);
            const usages = assistSource({ ...input, caret: valueType, action: 'usages' });
            assert.equal(usages.usages.length, 1);
            assert.equal(usages.usages[0].resource, input.root);
            const search = semanticSearch({ ...input, query: 'Model' });
            assert(search.matches.some(m => m.pointer === '/components/schemas/Model'));
        });
    }
test('JSON separators are derived from the actual gap, not a template', () => {
    for (const gap of [' §, ', ', § ', ' §,\n']) {
        const input = fixture('{"openapi":"3.2.1","info":{"title":"T"' + gap + '"version":"1"},"paths":{}}', true);
        const suggestion = assistSource(input).completions.find(c => c.label === 'summary');
        assert(suggestion);
        assert.equal(JSON.parse(apply(input, suggestion)).info.summary, '');
    }
});
test('completion and help honor versioned representation and location restrictions',()=>{
 for(const json of [false,true]){
  for(const version of ['3.1.2','3.2.1']){
   const value={openapi:version,info:{title:'T',version:'1'},paths:{},components:{examples:{E:{value:'authored§'}}}};
   let input=fixture(json?JSON.stringify(value):YAML.stringify(value),json);
   let help=assistSource({...input,action:'help'});assert.equal(help.help.kind,'example');
   // A blank line within the Example Object has no alternate representation
   // suggestions while the authored value remains, even when false or null.
   const text=json?`{"openapi":"${version}","info":{"title":"T","version":"1"},"paths":{},"components":{"examples":{"E":{"value":null, §}}}}`:`openapi: ${version}\ninfo: {title: T, version: '1'}\npaths: {}\ncomponents:\n  examples:\n    E:\n      value: false\n      §\n`;
   input=fixture(text,json);let result=assistSource(input);
   assert(!result.completions.some(c=>['externalValue','dataValue','serializedValue'].includes(c.label)));
  }
  const value={openapi:'3.2.1',info:{title:'T',version:'1'},paths:{},components:{parameters:{Q:{in:'querystring',name:'all',content:{'text/plain':{}},schema:{type:'string§'}}}}};
  let input=fixture(json?JSON.stringify(value):YAML.stringify(value),json);
  const at=input.resources[0].text.indexOf(json?'"schema"':'schema:')+3;
  const help=assistSource({...input,caret:at,action:'help'});
  assert.equal(help.help.prohibited,true);assert(help.help.blockedBy.includes('in'));
  assert.deepEqual(assistSource({...input,caret:at}).completions,[]);
  value.components.parameters.Q={in:'cookie',name:'all',style:'cookie',explode:false,schema:{}};
  const text=json?JSON.stringify(value).replace('"explode":false','"explode":fal§se'):YAML.stringify(value).replace('explode: false','explode: fal§se');
  input=fixture(text,json);
  const suggestions=assistSource(input).completions;
  assert.deepEqual(suggestions.map(c=>c.label),['true']);
 }
});
test('partial legal-key completion preserves values, quoting and unknown siblings', () => {
    for (const json of [false,true]) {
        const input=fixture(json?' {"openapi":"3.2.1","info":{"title":"T","version":"1","summ§":"kept","x-number":1.00},"paths":{}}':'# kept\nopenapi: 3.2.1\ninfo:\n  title: T\n  version: "1"\n  \'summ§\': kept\n  x-number: 1.00\npaths: {}',json);
        const suggestion=assistSource(input).completions.find(c=>c.label==='summary');assert(suggestion);
        const text=apply(input,suggestion), value=json?JSON.parse(text):YAML.parse(text);
        assert.equal(value.info.summary,'kept');assert(!Object.hasOwn(value.info,'summ'));assert(text.includes('1.00'));
        if(!json)assert(text.includes("'summary': kept"));
    }
});
test('an unfamiliar schema dialect is preserved without invented keyword assistance',()=>{
    const input=fixture('{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{},"components":{"schemas":{"Model":{"$schema":"https://custom.invalid/dialect","type":"str§ing"}}}}',true);
    const result=assistSource(input);assert.equal(result.help.dialectKnown,false);assert.deepEqual(result.completions,[]);
});
test('unfinished YAML and JSON keys use a proved local syntax repair, not whole-document serialization',()=>{
 for(const [text,json] of [
  ['# retained\r\nopenapi: 3.2.1\r\ninfo:\r\n  title: T\r\n  version: "1"\r\n  summ§\r\n  x-kept: 1.00\r\npaths: {}',false],
  ['{"openapi":"3.2.1","info":{"title":"T","version":"1","summ§},"paths":{},"x-kept":1.00}',true],
  ['{"openapi":"3.2.1","info":{"title":"T","version":"1","summ§"},"paths":{},"x-kept":1.00}',true],
  ['{"openapi":"3.2.1","info":{"title":"T","version":"1","summ§\n "x-kept":1.00},"paths":{}}',true],
 ]) {
  const input=fixture(text,json), result=assistSource(input), suggestion=result.completions.find(c=>c.label==='summary');
  assert(suggestion,JSON.stringify(result));
  const after=apply(input,suggestion), parsed=json?JSON.parse(after):YAML.parse(after);
  assert.equal(parsed.info.summary,'');assert(after.includes('1.00'));if(!json)assert(after.startsWith('# retained\r\n'));
 }
 const literal=fixture('{"openapi":"3.2.1","info":{"title":"summ§"},"paths":{},"x-data":{"summ":1}}',true);
 assert.deepEqual(assistSource(literal).completions,[]);
 const payload=fixture('{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{},"x-data":{"summ§}}',true);
 assert.deepEqual(assistSource(payload).completions,[]);
});
test('semantic search preserves repeated labels and physical definitions across resources', () => {
    const input = fixture('{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{§},"components":{"schemas":{"A":{"$ref":"models.json#/Model"},"B":{"type":"object","title":"Model"}}}}', true);
    input.resources.push({ id: 'file:///project/models.json', text: '{"Model":false}', generation: 3, identity: 'fragment' });
    const found = semanticSearch({ ...input, query: 'Model' }).matches;
    assert(found.some(m => m.resource === 'file:///project/models.json' && m.pointer === '/Model'));
    assert.equal(new Set(found.map(m => m.semanticId)).size, found.length);
    const folds = assistSource({ ...input, action: 'folds', from: 0, to: 100 }).folds;
    assert(Array.isArray(folds));
});
test('semantic operations use canonical Path Item occurrences, including callbacks and additional methods',()=>{
 const input=fixture('{"openapi":"3.2.1","info":{"title":"T","version":"1"},"paths":{§"/one":{"$ref":"paths.json#/Shared"},"/two":{"$ref":"paths.json#/Shared"}},"webhooks":{"updated":{"post":{"summary":"Event"}}}}',true);
 input.resources.push({id:'file:///project/paths.json',generation:2,identity:'paths',text:JSON.stringify({Shared:{get:{operationId:'repeated',tags:['group'],callbacks:{done:{'{$request.query.callback}':{post:{summary:'Callback'}}}}},additionalOperations:{COPY:{summary:'Copy'}}}})});
 const all=semanticSearch({...input,query:'',category:'operations'});
 assert.equal(all.complete,true);
 assert.equal(all.matches.length,7);
 assert.equal(all.matches.filter(m=>m.pointer==='/Shared/get').length,2);
 assert.equal(new Set(all.matches.map(m=>m.semanticId)).size,7);
 assert.equal(all.matches.filter(m=>m.label.startsWith('COPY')).length,2);
 assert.equal(all.matches.filter(m=>m.role==='callback').length,2);
 assert.equal(semanticSearch({...input,query:'group',category:'operations'}).matches.length,2);
 assert.equal(semanticSearch({...input,query:'',category:'usages'}).matches.length,2);
 input.resources[1].text=JSON.stringify({Shared:{$ref:'missing.json#/No'}});
 const missing=semanticSearch({...input,query:'',category:'usages'});
 assert.equal(missing.complete,false);
 assert(missing.matches.some(m=>m.resolution!=='resolved'));
});
