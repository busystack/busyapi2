const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');

const versions=['3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function fixture(version,format,policy,targetVersion,external=false){
    const root='file:///boolean-owners/api.'+format,models='file:///boolean-owners/models.'+format;
    const owner=external?models:root;
    const field=(external?'/Model':'/components/schemas/Model')+'/additionalProperties';
    const reserved='_migrated_additional_'+createHash('sha256').update(JSON.stringify([owner,field])).digest('hex').slice(0,24);
    const model={type:'object',properties:{known:{type:'string',enum:['','café']}},additionalProperties:policy};
    const document={openapi:version,info:{title:'Boolean owners',version:'business'},servers:[{url:'https://api.invalid'}],paths:{},
        components:{schemas:{Model:external?{$ref:'models.'+format+'#/Model'}:model,
            Detached:{$ref:(external?'models.'+format:'')+'#'+field},Chained:{$ref:'#/components/schemas/Detached'},
            NamedField:{type:'object',properties:{additionalProperties:policy},additionalProperties:false},
            // This name is not the additionalProperties keyword context.
            additionalProperties:policy,[reserved]:{type:'number'}}},'x-exact':'EXACT'};
    const render=value=>(format==='json'?JSON.stringify(value,null,2)+'\n':'# Keep boolean owners\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'))
        .replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
    const resources=[{id:root,text:render(document),generation:3},...(external?[{id:models,text:render({Model:model,'x-exact':'EXACT'}),generation:5}]:[])];
    if(format==='yaml'){
        const resource=resources.find(resource=>resource.id===owner);
        resource.text=resource.text.replace('Model:\r\n','Model: &model\r\n')
            .replace('additionalProperties: '+policy,'additionalProperties: &policy '+policy+' # keep policy');
        resource.text+='x-literal: *model # keep literal\r\nx-policy: *policy\r\n';
    }
    return {root,snapshot:version+format+policy+targetVersion+external,targetVersion,destination:'file:///reviewed/boolean-owners/',
        resources,owner,field,reserved};
}
function delivered(review){return {root:review.outputRoot,snapshot:'cold:'+review.identity,
    resources:review.outputs.map(output=>({id:output.id,text:output.text,generation:0}))};}
async function outcomes(input,policy){
    const swagger=new SourceDocument(input.resources.find(resource=>resource.id===input.root).text,input.root).dataNode('/swagger')?.value==='2.0';
    const prefix=swagger?'/definitions':'/components/schemas';
    const objectSamples=['{}','{"known":""}','{"known":"café"}','{"known":false}',
        '{"extra":9007199254740993.00}','{"extra":null}','null','false','0','[]'];
    const scalarSamples=['null','false','0','""','"雪"','[]','{}'];
    const cases=[...objectSamples.map(text=>({name:'Model',text})),
        ...['{}','{"additionalProperties":null}','{"additionalProperties":false}','{"extra":0}','null'].map(text=>({name:'NamedField',text})),
        ...['Detached','Chained','additionalProperties'].flatMap(name=>scalarSamples.map(text=>({name,text})))];
    const expected=[true,true,true,false,policy,policy,false,false,false,false,true,policy,policy,false,false,...Array(21).fill(policy)];
    const checked=await evaluateSchemas({...input,runtimeInstances:['request-body','response-body'].flatMap(subject=>
        cases.map(({name,text})=>({subject,text,location:'application/json',schema:{resource:input.root,pointer:prefix+'/'+name}})))});
    assert.equal(checked.complete,true,JSON.stringify(checked.findings));
    assert(checked.runtimeEvaluations.every(value=>value.complete));
    assert.deepEqual(checked.runtimeEvaluations.map(value=>value.valid),[...expected,...expected]);
    return checked.runtimeEvaluations.map(value=>value.valid);
}

for(const version of versions)for(const format of ['yaml','json'])for(const policy of [false,true])
for(const targetVersion of ['3.0.4','2.0'])
test(`${version} ${format} additionalProperties ${policy} retains field and standalone behavior in ${targetVersion}`,async()=>{
    const input=fixture(version,format,policy,targetVersion),original=input.resources.map(resource=>resource.text);
    const before=await outcomes(input,policy),review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));assert.equal(review.producerVersion,'40');
    assert.deepEqual(review.acceptedDecisions,[]);assert(review.changes.length>0);
    const output=delivered(review),checked=analyse(output);
    assert.equal(checked.status,'complete',JSON.stringify(checked.findings));
    assert.deepEqual(await outcomes(output,policy),before);
    const {graph}=createGraph(output),prefix=targetVersion==='2.0'?'/definitions':'/components/schemas';
    const detached=graph.referenceAs(output.root,prefix+'/Detached','$ref','schema');
    assert.equal(detached.resolution,'resolved');assert.equal(detached.targetResource,output.root);
    assert.equal(detached.targetPointer,prefix+'/'+input.reserved+'_1');
    const doc=graph.docs.get(output.root);
    assert.equal(doc.dataNode(prefix+'/Model/additionalProperties').value,policy);
    assert.equal(doc.dataNode(prefix+'/'+input.reserved+'/type').value,'number');
    assert.equal(doc.dataNode(prefix+'/additionalProperties').kind,'object');
    assert.equal(doc.dataNode(prefix+'/NamedField/properties/additionalProperties').kind,'object');
    assert.equal(doc.dataJson('/x-exact'),'9007199254740993.00');
    if(format==='yaml'){
        assert.equal(doc.dataJson('/x-literal'),new SourceDocument(original[0],input.root).dataJson('/x-literal'));
        assert.equal(doc.dataNode('/x-policy').value,policy);assert(doc.text.includes('# keep policy'));assert(doc.text.includes('# keep literal'));
    }
    assert.deepEqual(input.resources.map(resource=>resource.text),original);
    const repeated=await planMigration(input);assert.equal(repeated.identity,review.identity);assert.deepEqual(repeated.outputs,review.outputs);
});

for(const format of ['yaml','json'])for(const policy of [false,true])for(const targetVersion of ['3.0.4','2.0'])
test(`${format} a referenced external boolean field has a target-owned definition in ${targetVersion}`,async()=>{
    const input=fixture('3.2.1',format,policy,targetVersion,true),original=input.resources.map(resource=>resource.text);
    const before=await outcomes(input,policy),review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));
    const output=delivered(review);assert.deepEqual(await outcomes(output,policy),before);
    const {graph}=createGraph(output),prefix=targetVersion==='2.0'?'/definitions':'/components/schemas';
    const model=graph.referenceAs(output.root,prefix+'/Model','$ref','schema');assert.equal(model.resolution,'resolved');
    const doc=graph.docs.get(model.targetResource);
    assert.equal(doc.dataNode(model.targetPointer+'/additionalProperties').value,policy);
    const detached=graph.referenceAs(output.root,prefix+'/Detached','$ref','schema');
    assert.equal(detached.targetResource,output.root);assert.equal(detached.targetPointer,prefix+'/'+input.reserved+'_1');
    if(format==='yaml')assert.equal(doc.dataJson('/x-literal'),new SourceDocument(original[1],input.owner).dataJson('/x-literal'));
    assert.deepEqual(input.resources.map(resource=>resource.text),original);
});

for(const format of ['yaml','json'])test(`${format} missing external boolean owners remain incomplete with no migrated publication`,async()=>{
    const input=fixture('3.1.2',format,false,'3.0.4',true);input.resources.pop();const original=input.resources[0].text;
    const review=await planMigration(input);
    assert.equal(review.complete,false);assert.equal(review.status,'blocked');assert.deepEqual(review.outputs,[]);assert.deepEqual(review.changes,[]);
    assert(review.problems.some(problem=>problem.code.startsWith('migration.validation.')),JSON.stringify(review.problems));
    assert.equal(input.resources[0].text,original);
});
