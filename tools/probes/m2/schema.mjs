// Development-only evaluator qualification. No production dependency adoption.
import assert from 'node:assert/strict';
import {addUriSchemePlugin, addMediaTypePlugin} from '@hyperjump/browser';
import {createRequire} from 'node:module';
import {registerSchema, validate, setShouldValidateFormat} from '@hyperjump/json-schema/draft-2020-12';
import '@hyperjump/json-schema/openapi-3-1';
import '@hyperjump/json-schema/openapi-3-2';
import {bundle} from '@hyperjump/json-schema/bundle';
import {typedSchemaDocument} from './typed_schema.mjs';
const {createGraph} = createRequire(import.meta.url)('../../contract_engine/dist/model.cjs');

const supplied = new Map(), attempts = [];
for (const scheme of ['file','http','https']) addUriSchemePlugin(scheme, {retrieve: async reference => {
  const identity = new URL(reference); identity.hash = ''; const uri = identity.href;
  attempts.push(uri);
  const entry = supplied.get(uri);
  if (!entry) throw Error('Resource not supplied');
  const response = new Response(JSON.stringify(entry.value), {headers: {'content-type': entry.media ?? 'application/schema+json'}});
  Object.defineProperty(response, 'url', {value: entry.base ?? uri});
  return response;
}});
setShouldValidateFormat(false);
addMediaTypePlugin('application/vnd.busyapi.snapshot+json',{parse: async response => {
  const entry=supplied.get(response.url);
  const {graph}=createGraph({root:response.url,resources:[{id:response.url,text:JSON.stringify(entry.value),generation:1,identity:'probe'}]});
  return typedSchemaDocument(entry.value,response.url,graph,`https://spec.openapis.org/oas/${entry.value.openapi.slice(0,3)}/schema-base`);
}});
const dialect = 'https://json-schema.org/draft/2020-12/schema';

const tree = {$schema:dialect,$id:'https://contracts.invalid/tree',$dynamicAnchor:'node',type:'object',properties:{name:{type:'string'},children:{type:'array',items:{$dynamicRef:'https://contracts.invalid/tree#node'}}}};
const strict = {$schema:dialect,$id:'https://contracts.invalid/strict',$dynamicAnchor:'node',$ref:'tree',unevaluatedProperties:false};
registerSchema(tree);registerSchema(strict);
assert.equal((await validate(strict.$id,{name:'root',children:[{name:'child'}]})).valid,true);
assert.equal((await validate(strict.$id,{name:'root',children:[{name:'child',unknown:true}]})).valid,false);
assert.equal((await validate(tree.$id,{children:[{name:42}]})).valid,false);
const compound = await bundle(strict.$id);
assert.equal(compound.$id,strict.$id);assert.equal(compound.$ref,'tree');
assert(Object.values(compound.$defs).some(s=>s.$id===tree.$id));
console.log(JSON.stringify({candidate:'@hyperjump/json-schema',version:'1.18.0',case:'dynamic-evaluation-and-compound-bundle',status:'working',assertions:['positive','negative-recursive-dynamic-scope','full-uri-dynamicRef','retained-resource-boundaries']}));

for (const version of ['3.1.2','3.2.1']) {
 const uri=`file:///approved/${version}.openapi.json`;
 const value={openapi:version,info:{title:'Evaluator',version:'1'},paths:{},components:{schemas:{Model:{type:'object',required:['name'],properties:{name:{type:'string'}},examples:[{$ref:'literal payload reference',$schema:'https://payload.invalid/not-a-dialect',$id:'https://payload.invalid/not-an-identity'}]}}}};
 supplied.set(uri,{value,media:'application/vnd.busyapi.snapshot+json'});
 assert.equal((await validate(uri+'#/components/schemas/Model',{name:'valid'})).valid,true);
 assert.equal((await validate(uri+'#/components/schemas/Model',{name:42})).valid,false);
 assert.equal((await validate(`https://spec.openapis.org/oas/${version.slice(0,3)}/schema-base`,value)).valid,true);
 console.log(JSON.stringify({candidate:'@hyperjump/json-schema',version:'1.18.0',case:`oas-${version}`,status:'working',assertions:['canonical-file-uri','positive-instance','negative-instance','oas-schema-dialect','literal-example-ref-no-retrieval']}));
}
assert(attempts.every(uri=>supplied.has(uri)));
console.log(JSON.stringify({case:'snapshot-only-loading',status:'working',approvedReads:attempts.length,unexpectedAttempts:[]}));
