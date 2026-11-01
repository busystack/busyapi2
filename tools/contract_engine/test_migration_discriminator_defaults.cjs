const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');

function fixture(version,format,composition,required=false){
    const root='file:///fallback/api.'+format;
    const mapped=['Cat','cat','OtherOne','OtherTwo'];
    const fallback=(field,schema)=>({type:'object',required:[field],properties:{
        kind:{type:'string',not:{enum:mapped}},[field]:schema,
    },additionalProperties:false});
    const schemas={
        Parent:{type:'object',discriminator:{propertyName:'kind',mapping:{cat:'Cat'}},example:{value:'EXACT'}},
        Cat:{type:'object',required:['kind','cats'],properties:{kind:{enum:['Cat','cat']},cats:{type:'integer',minimum:1}},additionalProperties:false},
        OtherOne:fallback('value',{type:'integer',minimum:'EXACT'}),
        OtherTwo:fallback('note',{type:'string'}),
    };
    if(required){
        schemas.Parent.required=['kind'];
        schemas.Parent.properties={kind:{type:'string'}};
        schemas.Parent.example={kind:'future',value:'EXACT'};
    }
    if(composition==='allOf'){
        schemas.Parent.properties={kind:{type:'string'}};
        for(const name of ['Cat','OtherOne','OtherTwo'])schemas[name]={allOf:[{$ref:'#/components/schemas/Parent'},schemas[name]]};
    }else schemas.Parent[composition]=['Cat','OtherOne','OtherTwo'].map(name=>({$ref:'#/components/schemas/'+name}));
    const schema={$ref:'#/components/schemas/Parent'},document={openapi:version,info:{title:'Fallback alternatives 雪',version:'business'},
        servers:[{url:'https://api.invalid'}],paths:{'/value':{post:{requestBody:{content:{'application/json':{schema}}},
            responses:{200:{description:'Reply',content:{'application/json':{schema}}}}}}},components:{schemas},
        'x-literal':{defaultMapping:'payload only',kind:false,empty:'',nil:null}};
    const text=(format==='json'?JSON.stringify(document):'# Preserve original source\r\n'+YAML.stringify(document).replaceAll('\n','\r\n'))
        .replaceAll('"EXACT"','9007199254740993.000').replaceAll('EXACT','9007199254740993.000');
    return {root,snapshot:version+format+composition,targetVersion:'3.2.1',destination:'file:///reviewed/fallback/',resources:[{id:root,text,generation:3}]};
}
function delivered(review){return {root:review.outputRoot,snapshot:'cold:'+review.identity,resources:review.outputs.map(output=>({id:output.id,text:output.text,generation:0}))};}
const payloads=['{"value":9007199254740993}','{"value":9007199254740992}','{"kind":"future","value":9007199254740993}',
    '{"kind":"Cat","value":9007199254740993}','{"note":"café 雪"}','{"kind":"future","note":"café 雪"}',
    '{"kind":"Cat","cats":1}','{"kind":"cat","cats":0}','{}','false','null'];
async function evaluate(input,schema){
    const result=await evaluateSchemas({...input,runtimeInstances:payloads.map(text=>({subject:'response-body',location:'application/json',text,schema}))});
    assert.equal(result.complete,true,JSON.stringify(result.findings));
    assert(result.runtimeEvaluations.every(value=>value.complete));
    return result.runtimeEvaluations.map(value=>value.valid);
}

for(const format of ['yaml','json'])for(const composition of ['oneOf','anyOf','allOf'])
test(`3.0.4 ${format} ${composition} optional discriminator stays an invalid source and cannot request fallback migration`,async()=>{
    const input=fixture('3.0.4',format,composition),original=input.resources[0].text;
    const result=analyse(input);
    assert.equal(result.complete,true);assert.equal(result.status,'invalid');
    const findings=result.findings.filter(finding=>finding.code==='discriminator.required');
    assert.equal(findings.length,1,JSON.stringify(result.findings));
    const [finding]=findings;
    assert.equal(finding.resource,input.root);assert.equal(finding.pointer,'/components/schemas/Parent/discriminator/propertyName');
    assert.equal(finding.severity,'error');assert(finding.range[1]>finding.range[0]);
    const review=await planMigration(input);
    assert.equal(review.status,'blocked');assert.equal(review.complete,false);
    assert(review.problems.some(problem=>problem.code==='migration.validation.discriminator.required'&&problem.reason==='source-incomplete'),JSON.stringify(review.problems));
    assert(!review.problems.some(problem=>problem.code==='migration.discriminator.default'));
    assert.deepEqual(review.acceptedDecisions,[]);assert.deepEqual(review.outputs,[]);assert.deepEqual(review.changes,[]);
    assert.equal(input.resources[0].text,original);
});

for(const format of ['yaml','json'])for(const composition of ['oneOf','anyOf','allOf'])
test(`3.0.4 ${format} ${composition} required discriminator upgrades without inventing an optional fallback decision`,async()=>{
    const input=fixture('3.0.4',format,composition,true),original=input.resources[0].text;
    const sourceAnalysis=analyse(input);assert.equal(sourceAnalysis.status,'complete',JSON.stringify(sourceAnalysis.findings));
    const before=await evaluate(input,{resource:input.root,pointer:'/components/schemas/Parent'});
    const review=await planMigration(input);
    assert.equal(review.status,'faithfully-convertible',JSON.stringify(review.problems));assert.equal(review.complete,true);
    assert.deepEqual(review.problems,[]);assert.deepEqual(review.acceptedDecisions,[]);
    const output=delivered(review),{graph}=createGraph(output);
    const targetAnalysis=analyse(output);assert.equal(targetAnalysis.status,'complete',JSON.stringify(targetAnalysis.findings));
    assert(!graph.references.some(reference=>reference.keyword==='defaultMapping'));
    const doc=new SourceDocument(output.resources[0].text,output.root);
    assert.equal(doc.dataNode('/openapi').value,'3.2.1');
    assert.equal(doc.dataJson('/components/schemas/Parent/required'),'["kind"]');
    assert.equal(doc.dataNode('/components/schemas/Parent/discriminator/defaultMapping'),undefined);
    const mapping=graph.references.find(reference=>reference.connection==='discriminator'&&reference.keyword==='cat');
    assert.equal(mapping?.resolution,'resolved');assert.equal(mapping.targetResource,output.root);assert.equal(mapping.targetPointer,'/components/schemas/Cat');
    assert.deepEqual(await evaluate(output,{resource:output.root,pointer:'/components/schemas/Parent'}),before);
    assert.deepEqual(await evaluate(output,{resource:mapping.targetResource,pointer:mapping.targetPointer}),
        await evaluate(input,{resource:input.root,pointer:'/components/schemas/Cat'}));
    assert.equal(doc.dataJson('/x-literal'),new SourceDocument(original,input.root).dataJson('/x-literal'));
    assert.equal(input.resources[0].text,original);
});

for(const version of ['3.1.2'])for(const format of ['yaml','json'])for(const composition of ['oneOf','anyOf','allOf'])
test(`${version} ${format} ${composition} offers only eligible proved alternatives and honors each selected target`,async()=>{
    const input=fixture(version,format,composition),original=input.resources[0].text;
    const before=await evaluate(input,{resource:input.root,pointer:'/components/schemas/Parent'});
    const review=await planMigration(input);
    assert.equal(review.status,'requires-decision',JSON.stringify(review.problems));assert.equal(review.producerVersion,'36');
    assert.deepEqual(review.outputs,[]);assert.deepEqual(review.changes,[]);
    assert.equal(review.problems.length,1);
    const [problem]=review.problems;
    assert.equal(problem.code,'migration.discriminator.default');
    assert.deepEqual(problem.choiceDetails.map(choice=>choice.label).sort(),['OtherOne','OtherTwo']);
    assert.equal(problem.choices.length,2);assert(!problem.choices.includes('use-schema-as-default'));
    for(const choice of problem.choiceDetails){
        assert(problem.choices.includes(choice.value));assert.equal(choice.target.resource,input.root);
        assert.equal(choice.target.pointer,'/components/schemas/'+choice.label);assert(choice.target.range[1]>choice.target.range[0]);
        const applied=await planMigration({...input,decisions:{[problem.id]:choice.value}});
        assert.equal(applied.complete,true,JSON.stringify(applied.problems));assert.deepEqual(applied.acceptedDecisions,[problem.id]);
        const output=delivered(applied),analysis=analyse(output);assert.equal(analysis.status,'complete',JSON.stringify(analysis.findings));
        assert.deepEqual(await evaluate(output,{resource:output.root,pointer:'/components/schemas/Parent'}),before,
            'A discriminator selection must not replace or weaken parent validation');
        const {graph}=createGraph(output),fallback=graph.references.find(reference=>reference.keyword==='defaultMapping');
        assert.equal(fallback?.resolution,'resolved');assert.equal(fallback.targetResource,output.root);
        assert.equal(fallback.targetPointer,'/components/schemas/'+choice.label);assert.notEqual(fallback.targetPointer,'/components/schemas/Parent');
        const actual=await evaluate(output,{resource:fallback.targetResource,pointer:fallback.targetPointer});
        const source=await evaluate(input,{resource:input.root,pointer:choice.target.pointer});
        assert.deepEqual(actual,source);
        assert.deepEqual(actual,choice.label==='OtherOne'?[true,false,true,false,false,false,false,false,false,false,false]:
            [false,false,false,false,true,true,false,false,false,false,false]);
        assert.equal(new SourceDocument(output.resources[0].text,output.root).dataJson('/x-literal'),new SourceDocument(original,input.root).dataJson('/x-literal'));
    }
    await assert.rejects(()=>planMigration({...input,decisions:{[problem.id]:'use-schema-as-default'}}),error=>error.code==='migration.decisions.choice');
    const changed=JSON.parse(JSON.stringify(input));
    changed.resources[0].text=new SourceDocument(original,input.root).set('/components/schemas/OtherOne'+(composition==='allOf'?'/allOf/1':'')+'/properties/value/maximum',9007199254740992);
    await assert.rejects(()=>planMigration({...changed,decisions:{[problem.id]:problem.choices[0]}}),error=>error.code==='migration.decisions.stale');
    assert.equal(input.resources[0].text,original);
});

for(const format of ['yaml','json'])test(`${format} an inline alternative keeps reference sibling constraints`,async()=>{
    const input=fixture('3.1.2',format,'oneOf');let doc=new SourceDocument(input.resources[0].text,input.root);
    doc=new SourceDocument(doc.set('/components/schemas/Parent/oneOf/1',{$ref:'#/components/schemas/OtherOne',required:['extra'],properties:{extra:{const:'雪'}}}),input.root);
    doc=new SourceDocument(doc.set('/components/schemas/OtherOne/additionalProperties',true),input.root);
    doc=new SourceDocument(doc.remove('/components/schemas/Parent/example'),input.root);input.resources[0].text=doc.text;
    const review=await planMigration(input);assert.equal(review.status,'requires-decision',JSON.stringify(review.problems));
    const [problem]=review.problems,choice=problem.choiceDetails.find(choice=>choice.target.pointer==='/components/schemas/Parent/oneOf/1');
    assert(choice,'The listed schema includes its own modern reference siblings');
    const result=await planMigration({...input,decisions:{[problem.id]:choice.value}});assert.equal(result.complete,true,JSON.stringify(result.problems));
    const output=delivered(result),{graph}=createGraph(output),fallback=graph.references.find(reference=>reference.keyword==='defaultMapping');
    assert.equal(fallback.targetPointer,'/components/schemas/Parent/oneOf/1');
    const checked=await evaluateSchemas({...output,runtimeInstances:['{"value":9007199254740993}','{"value":9007199254740993,"extra":"雪"}'].map(text=>({
        subject:'response-body',text,location:'application/json',schema:{resource:fallback.targetResource,pointer:fallback.targetPointer},
    }))});
    assert(checked.runtimeEvaluations.every(value=>value.complete));assert.deepEqual(checked.runtimeEvaluations.map(value=>value.valid),[false,true]);
});

for(const mode of ['circular','unrelated-mapping','unsupported-dialect'])test(`a ${mode} target cannot become a successful default mapping`,async()=>{
    const input=fixture('3.1.2','json','oneOf');let doc=new SourceDocument(input.resources[0].text,input.root);
    if(mode==='circular'){
        doc=new SourceDocument(doc.set('/components/schemas/Parent/oneOf',[{$ref:'#/components/schemas/Alias'}]),input.root);
        doc=new SourceDocument(doc.set('/components/schemas/Alias',{$ref:'#/components/schemas/Parent'}),input.root);
    }else if(mode==='unrelated-mapping'){
        doc=new SourceDocument(doc.remove('/components/schemas/Parent/oneOf'),input.root);
        doc=new SourceDocument(doc.set('/components/schemas/Parent/allOf',[{type:'object'}]),input.root);
    }else doc=new SourceDocument(doc.set('/components/schemas/OtherOne/$schema','https://dialects.invalid/unknown'),input.root);
    input.resources[0].text=doc.text;const before=doc.text,review=await planMigration(input);
    assert.equal(review.complete,false);assert.deepEqual(review.outputs,[]);assert.deepEqual(review.changes,[]);
    assert.notEqual(review.status,'faithfully-convertible');assert(review.problems.length>0);
    assert.equal(input.resources[0].text,before);
});
