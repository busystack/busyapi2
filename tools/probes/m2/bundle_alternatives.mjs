// Focused maintained-library comparison, not a production bundler. All parser
// and retrieval plugins are disabled except canonical immutable snapshots.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {$RefParser} from '@apidevtools/json-schema-ref-parser';
import {addMediaTypePlugin,addUriSchemePlugin} from '@hyperjump/browser';
import {registerSchema,unregisterSchema} from '@hyperjump/json-schema/draft-2020-12';
import {loadDialect} from '@hyperjump/json-schema/experimental';
import '@hyperjump/json-schema/openapi-3-1';
import '@hyperjump/json-schema/openapi-3-2';
import {bundle as compoundBundle} from '@hyperjump/json-schema/bundle';
import {typedSchemaDocument} from './typed_schema.mjs';
const {createGraph}=createRequire(import.meta.url)('../../contract_engine/dist/model.cjs');
const root='https://contracts.invalid/api/root.json';
for(const family of ['3.1','3.2']) {
 const stem=family==='3.1'?'oas31':'oas32';
 const dialect=JSON.parse(fs.readFileSync(new URL(`../../contract_engine/schemas/${stem}-dialect.json`,import.meta.url),'utf8'));
 const vocabulary=JSON.parse(fs.readFileSync(new URL(`../../contract_engine/schemas/${stem}-vocabulary.json`,import.meta.url),'utf8'));
 registerSchema(vocabulary);const alias=`https://spec.openapis.org/oas/${family}/dialect/base`;
 unregisterSchema(alias);registerSchema(dialect,alias);registerSchema(dialect);loadDialect(alias,dialect.$vocabulary,true);
}
const fixture=name=>fs.readFileSync(new URL('../../../fixtures/compatibility/'+name,import.meta.url),'utf8');
const pointer=(value,path)=>path===''?value:path.slice(1).split('/').map(t=>t.replaceAll('~1','/').replaceAll('~0','~')).reduce((at,key)=>at?.[key],value);
function input(version,schema,entries=[]) {
 const text=JSON.stringify({openapi:version,info:{title:'Candidate',version:'1'},paths:{},components:{schemas:{Model:schema}}});
 return new Map([[root,text],...entries]);
}
function snapshot(resources) {
 return {root,snapshot:'alternative-probe',resources:[...resources].map(([id,text])=>({id,text,identity:'probe',generation:1}))};
}
async function refParser(resources) {
 const before=[...resources],{docs,graph}=createGraph(snapshot(resources));
 const copies=new Map(),allowed=new WeakSet(),attempts=[];
 for(const [id,doc]of docs) {
  const value=structuredClone(doc.root.value);copies.set(id,value);
  for(const ref of graph.references)if(ref.resource===id&&ref.keyword==='$ref'&&!ref.connection) {
   const occurrence=pointer(value,ref.pointer);if(occurrence&&typeof occurrence==='object')allowed.add(occurrence);
  }
 }
 const excluded=(_path,value)=>value&&typeof value==='object'&&typeof value.$ref==='string'&&!allowed.has(value);
 const result=await new $RefParser().bundle(root,{
  mutateInputSchema:true,
  resolve:{file:false,http:false,snapshot:{order:1,canRead:true,read:file=>{
   const uri=new URL(file.url);uri.hash='';attempts.push(uri.href);
   if(!resources.has(uri.href))throw Error('Not an approved resource: '+uri.href);
   return resources.get(uri.href);
  }}},
  parse:{json:false,yaml:false,text:false,binary:false,snapshot:{order:1,canParse:true,parse:file=>{
   const uri=new URL(file.url);uri.hash='';if(!copies.has(uri.href))throw Error('No canonical parsed snapshot');return copies.get(uri.href);
  }}},
  resolveExcludedPathMatcher:excluded,
  bundle:{excludedPathMatcher:excluded,optimizeInternalRefs:false},
 });
 assert.deepEqual([...resources],before,'Immutable canonical input must not change');
 return {value:result,text:JSON.stringify(result),attempts};
}
async function hyperjump(resources) {
 const {docs,graph}=createGraph(snapshot(resources)),attempts=[];
 for(const scheme of ['file','http','https'])addUriSchemePlugin(scheme,{retrieve:async reference=>{
  const uri=new URL(reference);uri.hash='';attempts.push(uri.href);
  const targets=graph.identities.get(uri.href);if(targets?.length!==1)throw Error('Not an approved identity');
  const doc=docs.get(targets[0].resource);
  const response=new Response(doc.text,{headers:{'content-type':'application/vnd.busyapi.alternative+json'}});
  Object.defineProperty(response,'url',{value:uri.href});return response;
 }});
 addMediaTypePlugin('application/vnd.busyapi.alternative+json',{fileMatcher:async()=>false,parse:async response=>{
  const target=graph.identities.get(response.url)?.[0],doc=target&&docs.get(target.resource);
  if(!doc)throw Error('No canonical parsed snapshot');
  const document=typedSchemaDocument(structuredClone(doc.root.value),doc.id,graph,graph.scope(doc.id,'').dialect);
  return document.embedded[graph.scope(doc.id,target.pointer).base];
 }});
 const value=await compoundBundle(root,{alwaysIncludeDialect:true});
 return {value,text:JSON.stringify(value),attempts};
}
let failures=0;
for(const [candidate,version,run]of [['@apidevtools/json-schema-ref-parser','16.0.5',refParser],['@hyperjump/json-schema','1.18.0',hyperjump]]) {
 for(const versionOas of ['3.1.2','3.2.1'])for(const name of ['rich','external-value','numeric-lexemes','nested-resource']) {
  let resources;
  if(name==='rich')resources=new Map([[root,fixture(versionOas.startsWith('3.1')?'oas31.json':'oas32.json')],['https://contracts.invalid/api/schema.json',fixture('schema.json')]]);
  else if(name==='external-value')resources=new Map([[root,JSON.stringify({openapi:versionOas,info:{title:'Example',version:'1'},paths:{},components:{examples:{Data:{externalValue:'https://unapproved.invalid/payload.txt'}}}})]]);
  else if(name==='numeric-lexemes')resources=new Map([[root,'{"openapi":"'+versionOas+'","info":{"title":"Numbers","version":"1"},"paths":{},"components":{"examples":{"Data":{"value":{"large":9007199254740993,"fraction":1.00000000000000000001,"zero":-0}}}}}']]);
  else resources=input(versionOas,{$ref:'../schemas/model.json#/Node'},[
   ['https://contracts.invalid/schemas/model.json',JSON.stringify({Node:{$id:'nested/Node',$dynamicAnchor:'node',type:'object',properties:{self:{$dynamicRef:'#node'},child:{$ref:'child'}}}})],
   ['https://contracts.invalid/schemas/nested/child',JSON.stringify({type:'string',description:'nested-child-sentinel'})],
  ]);
  try {
   const {value,text,attempts}=await run(resources);
   assert.equal(value.openapi,versionOas);
   if(name==='numeric-lexemes')for(const lexeme of ['9007199254740993','1.00000000000000000001','-0'])assert(text.includes(lexeme),'Lost exact numeric lexeme '+lexeme);
   if(name==='external-value')assert.equal(value.components.examples.Data.externalValue,'https://unapproved.invalid/payload.txt');
   if(name==='nested-resource') {
    const {graph}=createGraph(snapshot(new Map([[root,text]])));
    assert.equal(graph.identities.get('https://contracts.invalid/schemas/nested/Node')?.length,1,'Original nested schema identity was lost');
    assert(graph.references.every(ref=>ref.resolution==='resolved'),'Derived recursive/dynamic references must resolve without original files');
    assert(text.includes('nested-child-sentinel'));
   }
   if(name==='rich') {
    assert.equal(value.paths['/things'].get.operationId,'listThings');
    assert(text.includes('Schema property sentinel'));
    if(versionOas.startsWith('3.2')){assert.equal(value.paths['/things'].query.operationId,'queryThings');assert.equal(value.paths['/things'].additionalOperations.COPY.operationId,'copyThings');}
    assert.deepEqual(value.paths['/things'].get.responses['200'].content['application/json'].example,JSON.parse(resources.get(root)).paths['/things'].get.responses['200'].content['application/json'].example);
    const {graph}=createGraph(snapshot(new Map([[root,text]])));
    assert(graph.references.every(ref=>ref.resolution==='resolved'),'Every derived semantic reference must resolve without original files');
   }
   assert(attempts.every(uri=>resources.has(uri)),'Unexpected resource acquisition');
   console.log(JSON.stringify({candidate,version,fixture:name,openapi:versionOas,status:'working',attempts}));
  }catch(error){failures++;const causes=[];for(let e=error;e;e=e.cause)causes.push(e.stack?.slice(0,1800)??String(e));console.log(JSON.stringify({candidate,version,fixture:name,openapi:versionOas,status:'failing',detail:error.message.slice(0,800),causes}));}
 }
}
console.log(JSON.stringify({comparison:'required-focused-alternatives',failures}));
if(failures)process.exitCode=2;
