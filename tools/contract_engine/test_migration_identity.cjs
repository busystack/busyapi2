const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs');
const {analyse,createGraph}=require('./dist/model.cjs');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const {SourceDocument}=require('./dist/document.cjs');
const {resolveUri,documentUriBase}=require('./dist/reference_graph.cjs');

const render=(value,format)=>(format==='json'?JSON.stringify(value):'# Keep identity comments 雪\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'))
    .replaceAll('"EXACT"','9007199254740993.000').replaceAll('EXACT','9007199254740993.000')+'\r\n';

function fixture(version,target,format,self,aliases=[]){
    const root='file:///identity/contracts/api.'+format,binding={$ref:'#/components/schemas/Model'};
    const value={openapi:version,$self:self,info:{title:'Document identity',version:'business',
        description:'[Guide](guide.md#start) `./literal.md`',termsOfService:'./terms',
        contact:{url:'./contact'},license:{name:'License',url:'./license'}},
        servers:[{url:'/v1'}],externalDocs:{url:'./docs'},paths:{'/value':{post:{
            requestBody:{content:{'application/json':{schema:binding}}},
            responses:{200:{description:'Reply',content:{'application/json':{schema:binding}}}},
        }}},components:{schemas:{
            Leaf:{$id:'./schemas/leaf',type:'integer',enum:['EXACT']},
            Model:{type:'object',required:['value'],properties:{value:{$ref:'./schemas/leaf'},next:{$ref:'#/components/schemas/Model'}}},
        }},'x-literal':{$self:'data identity',$id:'data id',$ref:'data ref',number:'EXACT',empty:'',flag:false,nil:null}};
    return {root,snapshot:[version,target,format,self,...aliases].join(':'),targetVersion:target,destination:'file:///reviewed/identity/',
        resources:[{id:root,text:render(value,format),generation:1,aliases}]};
}

async function outcomes(input){
    const legacy=new SourceDocument(input.resources.find(value=>value.id===input.root).text,input.root).node('').value.swagger==='2.0';
    const samples=['{}','{"value":9007199254740993}','{"value":9007199254740992}',
        '{"value":9007199254740993,"next":{"value":9007199254740993}}','{"value":null}','false','0','"雪"'];
    const runtimeInstances=['request-body','response-body'].flatMap(subject=>samples.map(text=>({subject,text,location:'application/json',
        schema:{resource:input.root,pointer:subject==='request-body'?
            (legacy?'/paths/~1value/post/parameters/0/schema':'/paths/~1value/post/requestBody/content/application~1json/schema'):
            (legacy?'/paths/~1value/post/responses/200/schema':'/paths/~1value/post/responses/200/content/application~1json/schema')}})));
    const checked=await evaluateSchemas({...input,runtimeInstances});
    assert.equal(checked.complete,true,JSON.stringify(checked.findings));
    assert(checked.runtimeEvaluations.every(value=>value.complete));
    return checked.runtimeEvaluations.map(value=>value.valid);
}

for(const version of ['3.2.0','3.2.1'])for(const target of ['3.1.0','3.1.1','3.1.2','3.0.4','2.0'])
for(const format of ['yaml','json'])for(const self of ['', './logical/api.'+format,'https://contracts.invalid/v1/api.'+format])
test(`${version} ${format} $self=${JSON.stringify(self)} lowers to ${target} with URI and instance invariants`,async()=>{
    const input=fixture(version,target,format,self,['https://retrieval.invalid/contracts/api.'+format]);
    const before=input.resources[0].text,source=createGraph(input).graph;
    const base=source.scope(input.root,'').base,validity=await outcomes(input);
    const review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));assert.equal(review.producerVersion,'35');
    const output=review.outputs.find(value=>value.id===review.outputRoot),doc=new SourceDocument(output.text,output.id);
    assert.equal(doc.dataNode('/$self'),undefined);assert.equal(doc.node('/info/version').value,'business');
    assert.equal(doc.node('/info/contact/url').value,resolveUri('./contact',base).href);
    assert.equal(doc.node('/info/license/url').value,resolveUri('./license',base).href);
    assert.equal(doc.node('/externalDocs/url').value,resolveUri('./docs',base).href);
    assert.equal(doc.node('/info/termsOfService').value,resolveUri('./terms',base).href);
    assert(doc.node('/info/description').value.includes(resolveUri('guide.md',base).href+'#start'));
    assert(doc.node('/info/description').value.includes('`./literal.md`'));
    assert.equal(doc.dataJson('/x-literal'),new SourceDocument(before,input.root).dataJson('/x-literal'));
    if(format==='yaml')assert(output.text.startsWith('# Keep identity comments 雪\r\n'));
    const converted={root:review.outputRoot,snapshot:'identity-cold',resources:review.outputs.map(value=>({id:value.id,text:value.text,generation:0}))};
    assert.equal(analyse(converted).status,'complete');assert.deepEqual(await outcomes(converted),validity);
    const targetGraph=createGraph(converted).graph;
    if(target==='2.0'){
        assert.equal(doc.node('/host').value,'retrieval.invalid');assert.equal(doc.node('/basePath').value,'/v1');
    }else{
        assert.equal(doc.node('/servers/0/url').value,'https://retrieval.invalid/v1');
        assert.equal(documentUriBase(targetGraph,targetGraph.scope(converted.root,'/info')),review.outputRoot);
    }
    const moved='file:///moved/identity/';
    const relocated={root:new URL(review.entry,moved).href,snapshot:'identity-moved',resources:review.outputs.map(value=>({
        id:new URL(value.path,moved).href,text:value.text,generation:0}))};
    assert.equal(analyse(relocated).status,'complete');assert.deepEqual(await outcomes(relocated),validity);
    assert.equal(input.resources[0].text,before);
});

for(const format of ['yaml','json'])test(`${format} document-level dynamic anchor bindings survive $self lowering`,async()=>{
    const root='file:///identity/dynamic/api.'+format;
    const value={openapi:'3.2.1',$self:'https://contracts.invalid/dynamic',info:{title:'Dynamic identity',version:'1'},paths:{},components:{schemas:{
        Tree:{$dynamicAnchor:'node',type:'object',required:['value'],properties:{value:{type:'integer'},next:{$dynamicRef:'#node'}}},
        Strict:{$id:'strict',$dynamicAnchor:'node',allOf:[{$ref:'https://contracts.invalid/dynamic#node'}],properties:{value:{minimum:2}}},
    }}};
    const text=render(value,format),input={root,snapshot:'dynamic-identity',resources:[{id:root,text,generation:1}],targetVersion:'3.1.2',destination:'file:///reviewed/dynamic-identity/'};
    async function instances(capture){
        const runtimeInstances=['Tree','Strict'].flatMap(name=>['{"value":1,"next":{"value":1}}','{"value":2,"next":{"value":1}}',
            '{"value":2,"next":{"value":2}}','{"value":false}','{}'].map(text=>({subject:'response-body',text,location:'application/json',schema:{resource:capture.root,pointer:'/components/schemas/'+name}})));
        const result=await evaluateSchemas({...capture,runtimeInstances});assert.equal(result.complete,true,JSON.stringify(result.findings));
        assert(result.runtimeEvaluations.every(value=>value.complete));return result.runtimeEvaluations.map(value=>value.valid);
    }
    const before=await instances(input),review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));
    const converted={root:review.outputRoot,snapshot:'dynamic-cold',resources:review.outputs.map(value=>({id:value.id,text:value.text,generation:0}))};
    assert.deepEqual(await instances(converted),before);
    const {graph}=createGraph(converted),dynamic=graph.references.filter(value=>value.keyword==='$dynamicRef');
    assert(dynamic.length>0);assert(dynamic.every(value=>value.resolution==='resolved'&&value.dynamic?.anchor==='node'));
    const moved='file:///moved/dynamic-identity/';
    const relocated={root:new URL(review.entry,moved).href,snapshot:'dynamic-moved',resources:review.outputs.map(value=>({id:new URL(value.path,moved).href,text:value.text,generation:0}))};
    assert.deepEqual(await instances(relocated),before);
    assert.equal(input.resources[0].text,text);
    const older=await planMigration({...input,targetVersion:'3.0.4'});
    assert.equal(older.complete,false);assert.deepEqual(older.outputs,[]);
    assert(older.problems.some(problem=>problem.pointer.includes('Tree')&&problem.code!=='migration.feature.newer'));
});

for(const format of ['yaml','json'])test(`${format} cross-document identity edges keep both defining owners`,async()=>{
    const root='file:///identity/multi/api.'+format,shared='file:///identity/multi/shared.'+format;
    const input={root,snapshot:'multi-identity',targetVersion:'3.1.2',destination:'file:///reviewed/multi-identity/',resources:[
        {id:root,generation:1,text:render({openapi:'3.2.1',$self:'https://contracts.invalid/main',info:{title:'Main',version:'1'},
            paths:{'/value':{get:{responses:{200:{$ref:'shared#/components/responses/Value'}}}}}},format)},
        {id:shared,generation:2,text:render({openapi:'3.2.1',$self:'https://contracts.invalid/shared',info:{title:'Shared',version:'1'},paths:{},
            components:{responses:{Value:{description:'Value',content:{'application/json':{schema:{$ref:'main#/components/schemas/Value'}}}}},schemas:{}}},format)},
    ]};
    const first=format==='json'?JSON.parse(input.resources[0].text):YAML.parse(input.resources[0].text);
    first.components={schemas:{Value:{type:'string',enum:['café']}}};input.resources[0].text=render(first,format);
    const originals=input.resources.map(value=>value.text),review=await planMigration(input);
    assert.equal(review.complete,true,JSON.stringify(review.problems));assert.equal(review.outputs.length,2);
    const moved='file:///moved/multi-identity/',converted={root:new URL(review.entry,moved).href,snapshot:'multi-cold',resources:review.outputs.map(value=>({id:new URL(value.path,moved).href,text:value.text,generation:0}))};
    assert.equal(analyse(converted).status,'complete');
    const {graph}=createGraph(converted);assert(graph.references.every(value=>value.resolution==='resolved'));
    assert(graph.references.some(value=>value.resource!==value.targetResource));
    assert.deepEqual(input.resources.map(value=>value.text),originals);
});

test('missing resources still block document identity conversion without outputs',async()=>{
    const input=fixture('3.2.1','3.1.2','json','https://contracts.invalid/api');
    input.resources[0].text=new SourceDocument(input.resources[0].text,input.root).set('/components/schemas/Missing',{$ref:'missing.yaml'});
    const before=input.resources[0].text,review=await planMigration(input);
    assert.equal(review.complete,false);assert.deepEqual(review.outputs,[]);assert.deepEqual(review.changes,[]);
    assert(review.problems.some(problem=>problem.reason==='source-incomplete'));assert.equal(input.resources[0].text,before);
});

test('a shared YAML identity cannot be retired by deleting its anchor owner',async()=>{
    const root='file:///identity/shared/api.yaml';
    const text='openapi: 3.2.1\r\n$self: &identity https://contracts.invalid/api\r\n'+
        'info: {title: Shared identity, version: "1"}\r\npaths: {}\r\nx-identity: *identity\r\n';
    const input={root,snapshot:'shared-identity',targetVersion:'3.1.2',destination:'file:///reviewed/shared-identity/',
        resources:[{id:root,text,generation:1}]};
    const review=await planMigration(input);
    assert.equal(review.complete,false);assert.deepEqual(review.outputs,[]);assert.deepEqual(review.changes,[]);
    assert(review.problems.some(problem=>problem.code==='edit.shared'&&problem.resource===root));
    assert.equal(input.resources[0].text,text);
});
