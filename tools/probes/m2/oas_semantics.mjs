// Exact dated OAS dialect qualification; development only. No vendor patches.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {addMediaTypePlugin,addUriSchemePlugin} from '@hyperjump/browser';
import {registerSchema,unregisterSchema,validate,setShouldValidateFormat} from '@hyperjump/json-schema/draft-2020-12';
import {loadDialect,BASIC} from '@hyperjump/json-schema/experimental';
import '@hyperjump/json-schema/openapi-3-1';
import '@hyperjump/json-schema/openapi-3-2';
import {typedSchemaDocument} from './typed_schema.mjs';
const {createGraph}=createRequire(import.meta.url)('../../contract_engine/dist/model.cjs');
const supplied=new Map(),attempts=[];
for(const family of ['3.1','3.2']) {
 const stem=family==='3.1'?'oas31':'oas32';
 const dialect=JSON.parse(fs.readFileSync(new URL(`../../contract_engine/schemas/${stem}-dialect.json`,import.meta.url),'utf8'));
 const vocabulary=JSON.parse(fs.readFileSync(new URL(`../../contract_engine/schemas/${stem}-vocabulary.json`,import.meta.url),'utf8'));
 registerSchema(vocabulary);
 const alias=`https://spec.openapis.org/oas/${family}/dialect/base`;
 unregisterSchema(alias);
 registerSchema(dialect,alias);
 registerSchema(dialect);
 loadDialect(alias,dialect.$vocabulary,true);
 for(const id of [dialect.$id,alias]) {
  assert.equal((await validate(id,{type:'object',properties:{child:{$ref:'#'}}})).valid,true);
  assert.equal((await validate(id,{type:'invented'})).valid,false);
  assert.equal((await validate(id,{minLength:-1})).valid,false);
  assert.equal((await validate(id,{oneOf:[true,false]})).valid,true);
  assert.equal((await validate(id,{examples:[{$schema:'https://payload.invalid', $ref:'literal',$id:'not a resource'}],const:{$ref:'literal'}})).valid,true);
 }
 console.log(JSON.stringify({case:`dated-${family}-dialect`,status:'working',dialect:dialect.$id,assertions:['dated-and-base-identity','positive-and-negative-meta','literal-annotations-and-const']}));
}
for(const scheme of ['file','http','https'])addUriSchemePlugin(scheme,{retrieve:async reference=>{
 const url=new URL(reference);url.hash='';attempts.push(url.href);
 const entry=supplied.get(url.href);if(!entry)throw Error('Resource not supplied');
 const response=new Response(entry.text,{headers:{'content-type':'application/vnd.busyapi.snapshot+json'}});
 Object.defineProperty(response,'url',{value:url.href});return response;
}});
addMediaTypePlugin('application/vnd.busyapi.snapshot+json',{parse:async response=>{
 const entry=supplied.get(response.url);
 return typedSchemaDocument(JSON.parse(entry.text),response.url,entry.graph,entry.dialect);
}});
setShouldValidateFormat(false);
for(const version of ['3.1.2','3.2.1']) {
 const family=version.slice(0,3),uri=`file:///approved/${version}.json`,dialect=`https://spec.openapis.org/oas/${family}/dialect/base`;
 const literal={$schema:'https://payload.invalid/dialect',$id:'https://payload.invalid/id',$ref:'payload ref',nested:{$dynamicRef:'#payload'}};
 const schema={$schema:dialect,type:'object',properties:{id:{type:'integer'},kind:{enum:['a','b']}},if:{properties:{kind:{const:'a'}},required:['kind']},then:{required:['id']},unevaluatedProperties:false,examples:[literal], 'x-kept':literal};
 const value={openapi:version,jsonSchemaDialect:dialect,info:{title:'Dated',version:'1'},paths:{},components:{schemas:{Model:schema,Literal:{const:literal}}}};
 const text=JSON.stringify(value),{graph}=createGraph({root:uri,resources:[{id:uri,text,generation:1,identity:'probe'}]});
 supplied.set(uri,{text,graph,dialect});
 const derived=typedSchemaDocument(value,uri,graph,dialect),root=derived.embedded[uri]?.root??derived.root;
 assert.deepEqual(root.components.schemas.Model.examples,[literal]);
 assert.deepEqual(root.components.schemas.Model['x-kept'],literal);
 assert.deepEqual(root.components.schemas.Literal.const,literal);
 assert.equal((await validate(uri+'#/components/schemas/Model',{kind:'a',id:1})).valid,true);
 assert.equal((await validate(uri+'#/components/schemas/Model',{kind:'a'})).valid,false);
 assert.equal((await validate(uri+'#/components/schemas/Model',{kind:'b',unknown:true})).valid,false);
 assert.equal((await validate(uri+'#/components/schemas/Literal',literal)).valid,true);
 assert.equal((await validate(uri+'#/components/schemas/Literal',{...literal,$ref:'changed'})).valid,false);
 const invalid=await validate(uri+'#/components/schemas/Model',{kind:'a',id:'wrong'},BASIC);
 assert.equal(invalid.valid,false);
 assert(invalid.errors.some(e=>e.instanceLocation.endsWith('/id')&&e.keyword.endsWith('/type')));
 console.log(JSON.stringify({case:`oas-${version}-dated-instance`,status:'working',assertions:['canonical-dialect','positive-and-negative-conditionals','unevaluated-properties','unchanged-literal-const-and-annotations','located-instance-errors']}));
}
assert(attempts.every(uri=>supplied.has(uri)));
assert.throws(()=>registerSchema({$schema:'https://json-schema.org/draft/2020-12/schema',$id:'https://busyapi.invalid/custom-dialect',$vocabulary:{'https://custom.invalid/required':true}}),/Unrecognized vocabulary/);
console.log(JSON.stringify({case:'required-vocabulary-and-resources',status:'working',assertions:['unknown-required-vocabulary-fails-closed','no-payload-resource-acquisition']}));
