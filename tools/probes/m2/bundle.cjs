// Development qualification on trusted fixtures. Never called by the app.
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const assert=require('node:assert/strict');
const {analyse}=require('../../contract_engine/dist/model.cjs');
const fixtures=path.resolve(__dirname,'../../../fixtures/compatibility');
const output=fs.mkdtempSync(path.join(os.tmpdir(),'busyapi-m2-bundle-'));
const adapter=process.argv.includes('--adapter');
const cli=process.argv[2]&&!process.argv[2].startsWith('--')?path.resolve(process.argv[2]):path.join(__dirname,'node_modules/@redocly/cli/bin/cli.js');
const version=JSON.parse(fs.readFileSync(path.join(path.dirname(cli),'../package.json'),'utf8')).version;
const resolve=(document,ref)=>{
 assert(ref.startsWith('#/'));
 return ref.slice(2).split('/').map(s=>s.replaceAll('~1','/').replaceAll('~0','~')).reduce((v,k)=>v[k],document);
};
(async()=>{try{
 const {probeBundle}=await import('./bundle_adapter.mjs');
 const structural=(bundle)=>{
  for(const [group,entries] of Object.entries(bundle.components??{}))if(!group.startsWith('x-'))for(const name of Object.keys(entries))assert.match(name,/^[A-Za-z0-9._-]+$/,'Invalid derived Components map name');
  const id='https://contracts.invalid/bundle.json',text=JSON.stringify(bundle);
  const checked=analyse({root:id,snapshot:'probe',resources:[{id,text,generation:1,identity:'probe'}]});
  assert.deepEqual(checked.findings.filter(f=>f.severity==='error'),[],'Derived OpenAPI structural/reference checks failed');
  assert(checked.references.every(r=>r.resolution==='resolved'),'Every semantic reference must resolve');
 };
 for(const family of ['31','32'])for(const minimal of [false,true]){
  const name=`oas${family}${minimal?'-minimal':''}.json`,source=path.join(fixtures,name),destination=path.join(output,name);
  try {
  const original=JSON.parse(fs.readFileSync(source,'utf8'));
  let bundle,provenance;
  if(adapter){
   const resources=new Map([[`https://contracts.invalid/${name}`,JSON.stringify(original)],['https://contracts.invalid/schema.json',fs.readFileSync(path.join(fixtures,'schema.json'),'utf8')]]);
   ({document:bundle,provenance}=await probeBundle(`https://contracts.invalid/${name}`,resources));
  }else{
   const run=spawnSync(process.execPath,[cli,'bundle',source,'--config',path.join(__dirname,'redocly.yaml'),'--output',destination,'--ext','json'],{env:{...process.env,REDOCLY_TELEMETRY:'off',REDOCLY_SUPPRESS_UPDATE_NOTICE:'true'},encoding:'utf8',timeout:30000,maxBuffer:2*1024*1024});
   assert.equal(run.status,0,run.stderr);
   bundle=JSON.parse(fs.readFileSync(destination,'utf8'));
  }
  const text=JSON.stringify(bundle);
  structural(bundle);
  assert.equal(bundle.openapi,original.openapi);
  const operation=bundle.paths['/things'].get;
  assert.equal(operation.operationId,'listThings');
  assert(text.includes('Schema property sentinel'));
  if(family==='32'){
   assert.equal(bundle.paths['/things'].query.operationId,'queryThings');
   assert.equal(bundle.paths['/things'].additionalOperations.COPY.operationId,'copyThings');
  }
  if(!minimal){
   assert.deepEqual(operation.responses['200'].content['application/json'].example,original.paths['/things'].get.responses['200'].content['application/json'].example);
   let escaped=bundle.components.schemas.Escaped;const seen=new Set();
   while(escaped?.$ref){assert(!seen.has(escaped.$ref));seen.add(escaped.$ref);escaped=resolve(bundle,escaped.$ref);assert(escaped,'Derived escaped JSON Pointer does not identify its bundled component');}
   assert.equal(escaped.type,'string');
   const schema=resolve(bundle,operation.responses['200'].content['application/json'].schema.$ref);
   assert.equal(schema.properties.name.description,'Schema property sentinel');
   assert.equal(resolve(bundle,schema.properties.self.$ref),schema);
   assert.equal(bundle.components.schemas.Boolean,true);
   assert.equal(bundle.components.schemas.Composed.allOf.length,2);
   if(adapter){
    const mapped=provenance.find(p=>p.source==='https://contracts.invalid/schema.json#/a~1b');
    assert(mapped,'Source-target provenance must identify the escaped external source');
    assert.equal(resolve(bundle,'#'+mapped.derived).type,'string');
   }
  }
  console.log(JSON.stringify({tool:adapter?'Redocly core / bounded namespace adapter':'Redocly CLI',version,fixture:name,status:'working',assertions:['version','operations','schema','structural-validity','legal-component-names',...(minimal?[]:['literal-example','escaped-pointer','recursive','boolean','composition','source-provenance'])]}));
  }catch(error){process.exitCode=2;console.log(JSON.stringify({tool:'Redocly CLI',version,fixture:name,status:'failing',detail:error.message.slice(0,500)}));}
 }
 if(adapter){
  for(const family of ['3.1.2','3.2.1']){
   const keys=['a/b','a~1b','a~01b','a_b','a-b','a.b','a~b','雪/😀'];
   const schemas=Object.fromEntries(keys.map((key,i)=>[key,{type:'string',description:`target-${i}`} ]));
   schemas.boolean=true;schemas.recursive={type:'object',properties:{self:{$ref:'#/recursive'}}};
   const definitions=Object.fromEntries([...keys,'boolean','recursive'].map((key,i)=>[`Schema${i}`,{$ref:'schemas.json#/'+key.replaceAll('~','~0').replaceAll('/','~1')}]));
   const original={openapi:family,info:{title:'Adversarial names',version:'1'},paths:{},components:{schemas:definitions},'x-payload':{$ref:'literal extension data'}};
   const {document,provenance}=await probeBundle('https://contracts.invalid/root.json',new Map([['https://contracts.invalid/root.json',JSON.stringify(original)],['https://contracts.invalid/schemas.json',JSON.stringify(schemas)]]));
   structural(document);
   for(let i=0;i<keys.length;i++){
    const ref=document.components.schemas[`Schema${i}`].$ref;
    assert.equal(resolve(document,ref).description,`target-${i}`);
    assert(provenance.some(p=>p.source==='https://contracts.invalid/schemas.json#/'+keys[i].replaceAll('~','~0').replaceAll('/','~1')&&'#'+p.derived===ref));
   }
   assert.deepEqual(document['x-payload'],original['x-payload']);
   assert.equal(resolve(document,document.components.schemas.Schema8.$ref),true);
   const recursive=resolve(document,document.components.schemas.Schema9.$ref);
   assert.equal(resolve(document,recursive.properties.self.$ref),recursive);
   console.log(JSON.stringify({tool:'Redocly core / bounded namespace adapter',version,fixture:`adversarial-${family}`,status:'working',assertions:['distinct-source-targets','legal-names','tilde-slash-unicode','naive-sanitization-collisions','boolean','recursive','extension-payload']}));
  }
  for(const family of ['3.1.2','3.2.1'])for(const name of ['external-example','numeric-lexemes','nested-schema-resource']){
   try{
    const root='https://contracts.invalid/api/root.json';
    const document={openapi:family,info:{title:'Semantic qualification',version:'1'},paths:{},components:{schemas:{},examples:{}}};
    const resources=new Map();
    if(name==='external-example'){
     document.components.examples.Serialized={summary:'Authored reference, not permission to fetch',externalValue:'https://unapproved.invalid/payload.txt'};
     resources.set(root,JSON.stringify(document));
     const result=await probeBundle(root,resources);
     assert.deepEqual(result.document.components.examples.Serialized,document.components.examples.Serialized,'Bundling must not fetch or materialize externalValue');
    }else if(name==='numeric-lexemes'){
     const text=JSON.stringify(document).replace('"examples":{}','"examples":{"Big":{"value":{"integer":9007199254740993,"decimal":1.00000000000000000001,"zero":-0}}}');
     resources.set(root,text);
     const result=await probeBundle(root,resources),serialized=JSON.stringify(result.document);
     for(const lexeme of ['9007199254740993','1.00000000000000000001','-0'])assert(serialized.includes(lexeme),`Derived output lost authored numeric lexeme ${lexeme}`);
    }else{
     document.components.schemas.Node={$ref:'../schemas/model.json#/Node'};
     resources.set(root,JSON.stringify(document));
     resources.set('https://contracts.invalid/schemas/model.json',JSON.stringify({Node:{$id:'nested/Node',$dynamicAnchor:'node',type:'object',properties:{self:{$dynamicRef:'#node'},child:{$ref:'child'}}}}));
     resources.set('https://contracts.invalid/schemas/nested/child',JSON.stringify({type:'string',description:'nested child sentinel'}));
     const result=await probeBundle(root,resources);
     const target=resolve(result.document,result.document.components.schemas.Node.$ref);
     assert.equal(new URL(target.$id,root).href,'https://contracts.invalid/schemas/nested/Node','A derived schema resource must retain its original identity');
     assert.equal(target.properties.self.$dynamicRef,'#node');
     structural(result.document);
    }
    console.log(JSON.stringify({tool:'Redocly core / bounded namespace adapter',version,fixture:`${name}-${family}`,status:'working'}));
   }catch(error){process.exitCode=2;console.log(JSON.stringify({tool:'Redocly core / bounded namespace adapter',version,fixture:`${name}-${family}`,status:'failing',detail:error.message.slice(0,700)}));}
  }
 }
}finally{fs.rmSync(output,{recursive:true});}})().catch(error=>{console.error(error.message);process.exitCode=2;});
