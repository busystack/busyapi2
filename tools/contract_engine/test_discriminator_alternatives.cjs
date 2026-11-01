const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {referenceChoices}=require('./dist/reference_choices.cjs');
const {planReference}=require('./dist/reference_selection.cjs');
const {assistSource}=require('./dist/source_assistance.cjs');
const {SourceDocument}=require('./dist/document.cjs');

const parentPointer='/components/schemas/Parent';
const defaultPointer=parentPointer+'/discriminator/defaultMapping';
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
function capture(version,format,mode){
    const root='file:///alternatives/api.'+format;
    const parent={type:'object',discriminator:{propertyName:'kind',defaultMapping:'Fallback'}};
    const schemas={Parent:parent,Fallback:{type:'object',properties:{value:{type:'string'}}},
        Cat:{type:'object',required:['kind'],properties:{kind:{const:'cat'}}}};
    if(['oneOf','anyOf','alias','inline','sibling','unrelated','self','circular','unsupported'].includes(mode)){
        parent[mode==='anyOf'?'anyOf':'oneOf']=[{$ref:'#/components/schemas/Fallback'},{$ref:'#/components/schemas/Cat'}];
    }else schemas.Fallback.allOf=[{$ref:'#/components/schemas/Parent'}];
    if(mode==='alias'){
        schemas.Alias={$ref:'#/components/schemas/Fallback'};schemas.AliasTwo={$ref:'#/components/schemas/Alias'};
        parent.oneOf[0]={$ref:'#/components/schemas/Alias'};parent.discriminator.defaultMapping='AliasTwo';
    }
    if(mode==='inline'||mode==='sibling'){
        parent.oneOf[0]={$ref:'#/components/schemas/Fallback',required:['extra'],properties:{extra:{const:'雪'}}};
        parent.discriminator.defaultMapping=mode==='inline'?'#'+parentPointer+'/oneOf/0':'Fallback';
    }
    if(mode==='unrelated'){
        schemas.Unrelated={type:'object'};parent.discriminator.defaultMapping='Unrelated';
    }
    if(mode==='self')parent.discriminator.defaultMapping='Parent';
    if(mode==='circular'){
        schemas.Alias={$ref:'#/components/schemas/Parent'};parent.discriminator.defaultMapping='Alias';
    }
    if(mode==='unsupported')schemas.Fallback.$schema='https://dialects.invalid/unknown';
    if(mode==='external'){
        parent.discriminator.defaultMapping='models.'+format+'#/Child~1~0%E9%9B%AA';
        delete schemas.Fallback;
    }
    if(mode==='dynamic'||mode==='dynamic-peer'){
        parent.$dynamicAnchor='parent';schemas.Fallback.allOf=[{$dynamicRef:'#parent'}];
        if(mode==='dynamic-peer')schemas.Peer={$id:'peer',$dynamicAnchor:'parent',type:'object'};
    }
    if(mode==='missing')schemas.Fallback.allOf=[{$ref:'missing.'+format+'#/Parent'}];
    const value={openapi:version,info:{title:'Composition alternatives',version:'business'},paths:{},components:{schemas},
        'x-literal':{discriminator:{defaultMapping:'literal.json'},oneOf:[{$ref:'not-a-reference'}]},'x-exact':'EXACT'};
    const encode=value=>(format==='yaml'?'# Keep original source\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)+'\r\n')
        .replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
    const resources=[{id:root,text:encode(value),generation:1}];
    if(mode==='external')resources.push({id:'file:///alternatives/models.'+format,text:encode({
        'Child/~雪':{type:'object',allOf:[{$ref:'api.'+format+'#'+parentPointer}]},
    }),generation:2});
    return {root,snapshot:[version,format,mode].join(':'),resources};
}
async function checked(input){
    const original=input.resources.map(resource=>resource.text);
    const structural=analyse(input),schema=await evaluateSchemas({...input,runtimeInstances:[
        '{}','{"value":"café"}','{"value":false}','{"extra":"雪"}',
    ].map(text=>({subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer:parentPointer}}))});
    assert.deepEqual(input.resources.map(resource=>resource.text),original);
    assert(original[0].includes('9007199254740993.00'));
    for(const result of [structural,schema])assert(!result.findings.some(finding=>finding.pointer.startsWith('/x-literal')));
    return {structural,schema};
}
const fallbackFindings=result=>result.findings.filter(finding=>finding.code.startsWith('discriminator.default-mapping.'));

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])
for(const mode of ['oneOf','anyOf','alias','inline','allOf','external','dynamic'])
test(`${version} ${format} defaultMapping selects its actual ${mode} alternative`,async()=>{
    const input=capture(version,format,mode),{structural,schema}=await checked(input);
    assert.equal(structural.status,'complete',JSON.stringify(structural.findings));
    assert.equal(schema.complete,true,JSON.stringify(schema.findings));
    assert.deepEqual(fallbackFindings(structural),[]);assert.deepEqual(fallbackFindings(schema),[]);
    assert(schema.runtimeEvaluations.every(value=>value.complete));
    const reference=structural.references.find(reference=>reference.keyword==='defaultMapping');
    assert.equal(reference.resolution,'resolved');
    assert.equal(reference.targetPointer,mode==='external'?'/'+escape('Child/~雪'):
        mode==='inline'?parentPointer+'/oneOf/0':mode==='alias'?'/components/schemas/AliasTwo':'/components/schemas/Fallback');
});

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])
for(const mode of ['self','circular','unrelated','sibling'])
test(`${version} ${format} ${mode} fallback is a located specification error without changing instance validity`,async()=>{
    const input=capture(version,format,mode),{structural,schema}=await checked(input);
    assert.equal(structural.status,'invalid',JSON.stringify(structural.findings));
    assert.equal(structural.complete,true);assert.equal(schema.complete,true,JSON.stringify(schema.findings));
    for(const result of [structural,schema]){
        const findings=fallbackFindings(result);assert.equal(findings.length,1,JSON.stringify(result.findings));
        const [finding]=findings;assert.equal(finding.code,'discriminator.default-mapping.alternative');
        assert.equal(finding.resource,input.root);assert.equal(finding.pointer,defaultPointer);
        assert.equal(finding.severity,'error');assert(finding.range[1]>finding.range[0]);
    }
    const control=capture(version,format,mode==='sibling'?'inline':'oneOf');
    const valid=await checked(control);
    assert.deepEqual(schema.runtimeEvaluations.map(value=>[value.complete,value.valid]),
        valid.schema.runtimeEvaluations.map(value=>[value.complete,value.valid]),'Metadata errors do not become payload assertions');
});

for(const format of ['yaml','json'])for(const mode of ['missing','unsupported','dynamic-peer'])
test(`3.2.1 ${format} ${mode} inheritance cannot establish a complete fallback relationship`,async()=>{
    const input=capture('3.2.1',format,mode),{structural,schema}=await checked(input);
    for(const result of [structural,schema]){
        const findings=fallbackFindings(result);assert.equal(findings.length,1,JSON.stringify(result.findings));
        assert.equal(findings[0].code,'discriminator.default-mapping.incomplete');
        assert.equal(findings[0].pointer,defaultPointer);assert.equal(findings[0].severity,'warning');
        assert(!result.findings.some(finding=>finding.code==='discriminator.default-mapping.alternative'));
    }
    assert.equal(structural.complete,false);assert.equal(schema.complete,false);
});

for(const version of ['3.0.4','3.1.2'])for(const format of ['yaml','json'])
test(`${version} ${format} does not acquire 3.2 fallback semantics`,async()=>{
    const input=capture(version,format,'unrelated'),result=analyse(input);
    assert.deepEqual(fallbackFindings(result),[]);
    assert.equal(result.status,'invalid','The newer field remains invalid under this specification family');
});

for(const version of ['3.2.0','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} Design selection and Source completions share composition eligibility`,async()=>{
    const input=capture(version,format,'unrelated'),original=input.resources[0].text;
    input.contexts=[{root:input.root,resources:[input.root]}];
    const source=pointer=>{
        const doc=new SourceDocument(original,input.root),node=doc.node(pointer);
        return {root:input.root,resource:input.root,pointer,generation:1,range:node.range,expected:original.slice(...node.range)};
    };
    const pointer=parentPointer+'/discriminator',choices=referenceChoices({...input,resource:input.root,pointer,keyword:'defaultMapping',query:''});
    assert.equal(choices.complete,true);assert.equal(choices.targetKind,'schema');
    assert.deepEqual(choices.entries.map(choice=>choice.label).sort(),['Cat','Fallback']);
    const plan=planReference({...input,target:source(pointer),choice:source('/components/schemas/Fallback'),keyword:'defaultMapping'});
    let after=original;
    for(const edit of [...plan.edits].reverse()){
        assert.equal(after.slice(edit.start,edit.end),edit.expected);
        after=after.slice(0,edit.start)+edit.replacement+after.slice(edit.end);
    }
    assert.equal(after,original.replace('Unrelated','Fallback'),'Only the fallback value changes');
    const delivered={...input,resources:[{...input.resources[0],text:after,generation:2}]};
    assert.equal((await checked(delivered)).structural.status,'complete');
    assert.throws(()=>planReference({...input,target:source(pointer),choice:source('/components/schemas/Parent'),keyword:'defaultMapping'}),
        error=>error.code==='reference.choice.context');
    assert.throws(()=>planReference({...input,target:source(pointer),choice:{...source('/components/schemas/Fallback'),expected:'stale'},keyword:'defaultMapping'}),
        error=>error.code==='edit.stale');
    const parsed=new SourceDocument(original,input.root),node=parsed.dataNode(defaultPointer);
    const completions=assistSource({...input,resource:input.root,caret:node.range[0]+1}).completions;
    assert.deepEqual(completions.map(value=>value.label).sort(),['Cat','Fallback']);
    assert(completions.every(value=>value.target.pointer!=='/components/schemas/Unrelated'));
    for(const value of completions)assert.equal(value.edits[0].start,node.range[0]);
    const older={...input,resources:[{...input.resources[0],text:original.replace(version,'3.1.2'),generation:2}]};
    assert.throws(()=>referenceChoices({...older,resource:input.root,pointer,keyword:'defaultMapping',query:''}),error=>error.code==='reference.choice.context');
    assert.equal(input.resources[0].text,original);
});
