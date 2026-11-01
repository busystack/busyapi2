const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const {capturedMockStart,startMock}=require('./mock_test_capture.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');

const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const markers={HIGH:'9007199254740993.00',LOW:'-9007199254740993.00',TINY:'1.23e-400',HUGE:'1e400',NEXT:'1.01e400',STEP:'1e-100000'};
const send=(port,path)=>new Promise((resolve,reject)=>{
    const request=http.get({host:'127.0.0.1',port,path},response=>{
        const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);
        response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,bytes:Buffer.concat(chunks)}));
    });
    request.once('error',reject);
});
function encode(value,format){
    let text=format==='json'?JSON.stringify(value):YAML.stringify(value);
    for(const [key,raw]of Object.entries(markers))text=text.replaceAll('"'+key+'"',raw).replaceAll(key,raw);
    return text;
}
for(const version of versions)for(const format of ['yaml','json'])
test(`${version} ${format} generated numeric response bytes satisfy the original exact constraints`,{timeout:45000},async t=>{
    const swagger=version==='2.0',modern=version.startsWith('3.1')||version.startsWith('3.2');
    const exclusive=(minimum,maximum)=>modern?{exclusiveMinimum:minimum,exclusiveMaximum:maximum}:
        {minimum,maximum,exclusiveMinimum:true,exclusiveMaximum:true};
    const cases=[
        ['minimum',{type:'integer',minimum:'HIGH'},'9007199254740993'],
        ['maximum',{type:'integer',maximum:'LOW'},'-9007199254740993'],
        ['integer-ceiling',{type:'integer',minimum:1.1,maximum:2.1},'2'],
        ['exclusive',{type:'number',...exclusive(0.1,0.11)},'101e-3'],
        ['integer-lattice',{type:'integer',multipleOf:2.5,minimum:3,maximum:6},'5'],
        ['composed-lattice',{type:'number',minimum:0.61,maximum:1.3,allOf:[{multipleOf:0.2},{multipleOf:0.3}]},'12e-1'],
        ['underflow',{type:'number',minimum:'TINY',maximum:'TINY'},'1.23e-400'],
        ['overflow',{type:'number',minimum:'HUGE'},'1e400'],
        ['overflow-exclusive',{type:'number',...exclusive('HUGE','NEXT')},'1001e397'],
        ['zero-lattice',{type:'number',minimum:0,multipleOf:'STEP'},'0'],
    ];
    const root='file:///numeric-samples/api.'+format,model='file:///numeric-samples/models.'+format;
    const response=schema=>({description:'Generated',...(swagger?{schema}:{content:{'application/json':{schema}}})});
    const paths=Object.fromEntries(cases.map(([name,schema])=>['/'+name,{get:{responses:{200:response(schema)}}}]));
    paths['/nested']={get:{responses:{200:response({type:'object',required:['number'],properties:{number:{$ref:'models.'+format+'#/Number'}}})}}};
    paths['/impossible']={get:{responses:{200:response({type:'integer',minimum:1.1,maximum:1.9})}}};
    const document={[swagger?'swagger':'openapi']:version,info:{title:'Exact constrained samples',version:'business'},
        ...(swagger?{produces:['application/json']}:{}),paths};
    const capture={root,snapshot:'0'.repeat(64),resources:[
        {id:root,text:encode(document,format)},
        {id:model,text:encode({Number:{type:'integer',minimum:'HIGH',maximum:'HIGH'}},format)},
    ].map(resource=>({...resource,generation:1,identity:createHash('sha256').update(resource.text).digest('hex')}))};
    const original=capture.resources.map(resource=>resource.text),input=capturedMockStart(capture);
    const ready=await startMock(t,input);
    assert.equal(ready.nativeGeneration.version,'3');
    const instanceChecks=[];
    for(const [name,,expected]of [...cases,['nested',{},'{"number":9007199254740993}']]){
        const response=await send(ready.port,'/'+name);
        assert.equal(response.status,200,name+': '+response.bytes.toString());
        assert.deepEqual(response.bytes,Buffer.from(expected),name);
        assert.equal(response.headers['busyapi-response-validation-complete'],'true',name);
        assert.equal(response.headers['content-type'].split(';')[0],'application/json');
        assert.deepEqual(JSON.parse(response.headers['sl-violations']??'[]'),[],name);
        const pointer='/paths/~1'+name+'/get/responses/200'+(swagger?'/schema':'/content/application~1json/schema');
        instanceChecks.push({subject:'response-body',location:'/'+name,text:response.bytes.toString(),schema:{resource:root,pointer}});
    }
    const proof=await evaluateSchemas({...capture,runtimeInstances:instanceChecks});
    assert.equal(proof.complete,true,JSON.stringify(proof.findings));
    assert.deepEqual(proof.runtimeEvaluations.map(value=>[value.complete,value.valid]),instanceChecks.map(()=>[true,true]));
    const failed=await send(ready.port,'/impossible');
    assert(failed.status>=500,'An invalid generated response cannot be a successful mock response');
    assert.equal(failed.headers['busyapi-response-validation-complete'],'false');
    assert.equal(JSON.parse(failed.bytes.toString()).complete,false);
    assert.deepEqual(capture.resources.map(resource=>resource.text),original);
});
