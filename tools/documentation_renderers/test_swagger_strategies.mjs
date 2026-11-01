// Exact upstream strategy qualification, development tooling only.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
const engine=createRequire(new URL('../contract_engine/package.json',import.meta.url)),{build}=engine('esbuild'),{referenceDocument}=engine('./dist/reference_projection.cjs');
test('both exact upstream strategies preserve authored composition, recursion and payloads in strict read-only mode',async()=>{
  const temporary=await mkdtemp(path.join(tmpdir(),'busyapi-swagger-strategies-'));
  try {
    const output=await build({entryPoints:[fileURLToPath(new URL('./swagger_entry.mjs',import.meta.url))],nodePaths:[fileURLToPath(new URL('../probes/m2/node_modules',import.meta.url))],bundle:true,write:false,format:'esm',platform:'browser',target:'es2022',define:{'process.env.NODE_ENV':'"production"'},logLevel:'silent'});
    const module=path.join(temporary,'entry.mjs');await writeFile(module,output.outputFiles[0].text,{flag:'wx'});
    const {configuration}=await import(pathToFileURL(module));
    for(const version of ['3.1.2','3.2.1']) {
      const root='https://contracts.invalid/input.json',display='https://display.invalid/index.html',operation={responses:{200:{description:'Value',content:{'application/json':{schema:{$ref:'#/components/schemas/Composed'},example:{$ref:'literal payload'}}}}}};
      const value={openapi:version,info:{title:'Strict projection',version:'1'},paths:{'/value':version.startsWith('3.2.')?{additionalOperations:{COPY:operation}}:{get:operation}},components:{schemas:{
        Boolean:false,Composed:{allOf:[{type:'object',properties:{first:{type:'string'}}},{type:'object',properties:{second:{type:'string'}}}]},
        Recursive:{type:'object',properties:{child:{$ref:'#/components/schemas/Recursive'}}},
      }}};
      const text=JSON.stringify(value),projection=referenceDocument({root,snapshot:'strict',resources:[{id:root,text,generation:1}]}),config=configuration(text,projection,display,{labels:{previousPage:'Previous',nextPage:'Next',page:(page,pages)=>page+'/'+pages},onError:()=>{throw Error('Unexpected adapter error');}}),captured=JSON.stringify(config.spec);
      const strategy=config.busyApiResolveStrategies.find(strategy=>strategy.match(config.spec));let requests=0;
      assert.equal(strategy.name,version.startsWith('3.2.')?'openapi-3-2-apidom':'openapi-3-1-apidom');
      const result=await strategy.resolve({spec:structuredClone(config.spec),baseDoc:display,strategies:config.busyApiResolveStrategies,requestInterceptor:()=>{requests++;throw Error('Unexpected retrieval');}});
      assert.deepEqual(result.errors,[]);assert.equal(requests,0);assert.equal(result.spec.openapi,version);
      assert.equal(result.spec.components.schemas.Boolean,false);
      assert.deepEqual(result.spec.components.schemas.Composed.allOf,value.components.schemas.Composed.allOf);
      assert.equal(result.spec.components.schemas.Composed.properties,undefined);
      assert.equal(result.spec.components.schemas.Recursive.properties.child.$ref,display+'#/components/schemas/Recursive');
      const resolved=version.startsWith('3.2.')?result.spec.paths['/value'].additionalOperations.COPY:result.spec.paths['/value'].get;
      assert.deepEqual(resolved.responses[200].content['application/json'].example,{$ref:'literal payload'});
      assert.equal(JSON.stringify(config.spec),captured);assert.equal(config.busyApiPresentation().canonicalText,text);
    }
  } finally {await rm(temporary,{recursive:true,force:true});}
});
