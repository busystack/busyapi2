const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');

const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
function fixture(version,format,booleanOwner=false){
    const name=booleanOwner?'value/~雪':'value',root='file:///inactive/api.'+format;
    const field='/components/schemas/Model/properties/'+escape(name)+'/writeOnly';
    const reserved='_migrated_annotation_'+createHash('sha256').update(JSON.stringify([root,field])).digest('hex').slice(0,24);
    const property={type:'string',enum:['','雪'],default:'',writeOnly:false,deprecated:false,readOnly:false};
    const schema={$ref:'#/components/schemas/Model'};
    const document={openapi:version,info:{title:'Inactive annotations',version:'business'},servers:[{url:'https://api.invalid'}],
        paths:{'/value':{post:{requestBody:{content:{'application/json':{schema}}},responses:{200:{description:'Reply',content:{'application/json':{schema}}}}}}},
        components:{schemas:{Model:{type:'object',required:[name],properties:{[name]:property},additionalProperties:false},
            ...(booleanOwner?{False:{$ref:'#'+field},[reserved]:{type:'number'}}:{})}},'x-exact':'EXACT'};
    let text=format==='json'?JSON.stringify(document):'# Keep source organization\r\n'+YAML.stringify(document).replaceAll('\n','\r\n');
    text=text.replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
    if(format==='yaml'){
        text=text.replace('Model:\r\n','Model: &model\r\n').replace('writeOnly: false','writeOnly: false # keep inactive comment');
        text+='x-literal: *model # keep literal use\r\n';
    }
    return {root,snapshot:version+format+booleanOwner,targetVersion:'2.0',destination:'file:///reviewed/inactive/',
        resources:[{id:root,text,generation:4}],name,field,reserved};
}
function delivered(review){return {root:review.outputRoot,snapshot:'cold:'+review.identity,
    resources:review.outputs.map(output=>({id:output.id,text:output.text,generation:0}))};}
async function outcomes(input,name){
    const legacy=new SourceDocument(input.resources[0].text,input.root).dataNode('/swagger')?.value==='2.0';
    const samples=['{}',JSON.stringify({[name]:''}),JSON.stringify({[name]:'雪'}),JSON.stringify({[name]:false}),JSON.stringify({[name]:null}),'[]','null'];
    const instances=['request-body','response-body'].flatMap(subject=>samples.map(text=>({subject,text,location:'application/json',schema:{resource:input.root,
        pointer:'/paths/~1value/post/'+(subject==='request-body'?legacy?'parameters/0/schema':'requestBody/content/application~1json/schema':
            legacy?'responses/200/schema':'responses/200/content/application~1json/schema')},
    })));
    const result=await evaluateSchemas({...input,runtimeInstances:instances});
    assert.equal(result.complete,true,JSON.stringify(result.findings));assert(result.runtimeEvaluations.every(value=>value.complete));
    return result.runtimeEvaluations.map(value=>value.valid);
}
for(const version of versions)for(const format of ['yaml','json'])
test(`${version} ${format} inactive annotations downgrade to Swagger without changing directional behavior`,async()=>{
    const input=fixture(version,format),original=input.resources[0].text;
    const before=await outcomes(input,input.name);
    assert.deepEqual(before,[false,true,true,false,false,false,false,false,true,true,false,false,false,false]);
    const review=await planMigration(input);assert.equal(review.complete,true,JSON.stringify(review.problems));
    assert.equal(review.producerVersion,'39');assert.deepEqual(review.acceptedDecisions,[]);
    const output=delivered(review),analysis=analyse(output);assert.equal(analysis.status,'complete',JSON.stringify(analysis.findings));
    assert.deepEqual(await outcomes(output,input.name),before);
    const doc=new SourceDocument(output.resources[0].text,output.root),property=doc.dataNode('/definitions/Model/properties/'+escape(input.name)).value;
    assert.equal(Object.hasOwn(property,'writeOnly'),false);assert.equal(Object.hasOwn(property,'deprecated'),false);
    assert.equal(property.readOnly,false);assert.equal(property.default,'');assert.deepEqual(property.enum,['','雪']);
    assert.equal(doc.dataJson('/x-exact'),'9007199254740993.00');
    if(format==='yaml'){
        assert.equal(doc.dataJson('/x-literal'),new SourceDocument(original,input.root).dataJson('/x-literal'));
        assert(doc.text.includes('# keep inactive comment'));assert(doc.text.includes('# keep literal use'));
    }
    assert.equal(input.resources[0].text,original);
});

for(const version of ['3.1.2','3.2.1'])for(const format of ['yaml','json'])
test(`${version} ${format} an independently referenced false annotation retains its schema owner and avoids naming collisions`,async()=>{
    const input=fixture(version,format,true),original=input.resources[0].text;
    const review=await planMigration(input);assert.equal(review.complete,true,JSON.stringify(review.problems));
    const output=delivered(review),{graph}=createGraph(output);
    const reference=graph.referenceAs(output.root,'/definitions/False','$ref','schema');
    assert.equal(reference.resolution,'resolved');assert.equal(reference.targetPointer,'/definitions/'+input.reserved+'_1');
    const doc=new SourceDocument(output.resources[0].text,output.root);
    assert.equal(doc.dataNode('/definitions/'+input.reserved+'/type').value,'number');
    assert.equal(doc.dataNode('/definitions/Model/properties/'+escape(input.name)+'/writeOnly'),undefined);
    const checks=async(input,pointer)=>{
        const result=await evaluateSchemas({...input,runtimeInstances:['null','false','0','"雪"','{}','[]'].map(text=>({
            subject:'response-body',location:'application/json',text,schema:{resource:input.root,pointer},
        }))});
        assert.equal(result.complete,true,JSON.stringify(result.findings));assert(result.runtimeEvaluations.every(value=>value.complete));
        return result.runtimeEvaluations.map(value=>value.valid);
    };
    assert.deepEqual(await checks(output,'/definitions/False'),Array(6).fill(false));
    assert.deepEqual(await checks(output,'/definitions/False'),await checks(input,'/components/schemas/False'));
    assert.equal(input.resources[0].text,original);
});

for(const field of ['writeOnly','deprecated'])for(const format of ['yaml','json'])
test(`${format} an active ${field} rule is not discarded by inactive-annotation lowering`,async()=>{
    const input=fixture('3.0.4',format),doc=new SourceDocument(input.resources[0].text,input.root);
    // Build a separate authored neighbor, preserving the negative production
    // case rather than asking a shared-node editor to bypass its guard.
    const value=YAML.parse(doc.text);value.components.schemas.Model.properties.value[field]=true;
    input.resources[0].text=format==='json'?JSON.stringify(value):YAML.stringify(value);
    const original=input.resources[0].text,review=await planMigration(input);
    assert.equal(review.complete,false);assert.equal(review.status,'blocked');assert.deepEqual(review.outputs,[]);assert.deepEqual(review.changes,[]);
    assert(review.problems.some(problem=>problem.pointer.endsWith('/'+field)),JSON.stringify(review.problems));
    assert.equal(input.resources[0].text,original);
});
