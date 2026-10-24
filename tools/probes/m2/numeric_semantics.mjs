// Isolated precision qualification through public selected-release APIs.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {addMediaTypePlugin,addUriSchemePlugin} from '@hyperjump/browser';
import {registerSchema,unregisterSchema,setShouldValidateSchema,setShouldValidateFormat} from '@hyperjump/json-schema/draft-2020-12';
import '@hyperjump/json-schema/openapi-3-1';
import '@hyperjump/json-schema/openapi-3-2';
import {compile,interpret,getSchema,loadDialect,BASIC} from '@hyperjump/json-schema/experimental';
import {typedSchemaDocument} from './typed_schema.mjs';
import {decimal,compare,multiple,addExactSource,exactInstance,installExactNumericKeywords} from './exact_numbers.mjs';
const require=createRequire(import.meta.url),{createGraph}=require('../../contract_engine/dist/model.cjs'),{SourceDocument}=require('../../contract_engine/dist/document.cjs');
const supplied=new Map(),attempts=[];
installExactNumericKeywords();
for(const family of ['3.1','3.2']) {
 const stem=family==='3.1'?'oas31':'oas32';
 const dialect=JSON.parse(fs.readFileSync(new URL(`../../contract_engine/schemas/${stem}-dialect.json`,import.meta.url),'utf8'));
 const vocabulary=JSON.parse(fs.readFileSync(new URL(`../../contract_engine/schemas/${stem}-vocabulary.json`,import.meta.url),'utf8'));
 registerSchema(vocabulary);
 const alias=`https://spec.openapis.org/oas/${family}/dialect/base`;
 unregisterSchema(alias);registerSchema(dialect,alias);registerSchema(dialect);
 loadDialect(alias,dialect.$vocabulary,true);
}
// Automatic validation builds instances from rounded JavaScript values.
// Replace that boundary with an explicit exact-CST meta-schema evaluation;
// never compile an unverified authored schema in the assertions below.
setShouldValidateSchema(false);setShouldValidateFormat(false);
for(const scheme of ['file','http','https'])addUriSchemePlugin(scheme,{retrieve:async reference=>{
 const uri=new URL(reference);uri.hash='';attempts.push(uri.href);
 const entry=supplied.get(uri.href);if(!entry)throw Error('Resource not supplied');
 const response=new Response(entry.doc.text,{headers:{'content-type':'application/vnd.busyapi.numeric-probe+json'}});
 Object.defineProperty(response,'url',{value:uri.href});return response;
}});
addMediaTypePlugin('application/vnd.busyapi.numeric-probe+json',{parse:async response=>{
 const {doc,graph,dialect}=supplied.get(response.url);return typedSchemaDocument(doc.root.value,doc.id,graph,dialect);
}});
assert.equal(compare(decimal('9007199254740993'),decimal('9007199254740992')),1);
assert.equal(compare(decimal('1e-999999999999999999999999999'),decimal('0')),1);
assert.equal(compare(decimal('-100.0'),decimal('-1e2')),0);
assert.equal(multiple(decimal('0.3'),decimal('0.1')),true);
assert.equal(multiple(decimal('1e999999999999999999999999999'),decimal('0.125')),true);
assert.equal(multiple(decimal('1e-999999999999999999999999999'),decimal('0.1')),false);
// Independent bounded rational oracle, not a second call to the adapter.
let seed=1977;
const random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;};
const rational=(coefficient,exponent)=>({numerator:coefficient*10n**BigInt(Math.max(0,exponent)),denominator:10n**BigInt(Math.max(0,-exponent))});
for(let i=0;i<1000;i++) {
 const ac=BigInt(random()%200000)-100000n,bc=BigInt(random()%100000)+1n,ae=random()%25-12,be=random()%25-12;
 const a=rational(ac,ae),b=rational(bc,be),left=a.numerator*b.denominator,right=b.numerator*a.denominator;
 assert.equal(compare(decimal(ac+'e'+ae),decimal(bc+'e'+be)),left<right?-1:left>right?1:0);
 assert.equal(multiple(decimal(ac+'e'+ae),decimal(bc+'e'+be)),left%right===0n);
}
assert.throws(()=>decimal('1'.repeat(4097)),/work limit/);
const cases=[
 ['integer','{"type":"integer"}','9007199254740993',true],
 ['fraction-below-machine-ulp','{"type":"integer"}','1.0000000000000000001',false],
 ['maximum','{"maximum":9007199254740992}','9007199254740993',false],
 ['minimum','{"minimum":9007199254740993}','9007199254740992',false],
 ['exclusive','{"exclusiveMinimum":0.1}','0.10000000000000000001',true],
 ['multiple-positive','{"multipleOf":0.1}','0.3',true],
 ['multiple-negative','{"multipleOf":0.1}','0.30000000000000000001',false],
 ['small-positive','{"exclusiveMinimum":0}','1e-10000',true],
 ['large-maximum','{"maximum":1e10000}','1e10001',false],
 ['const-distinct','{"const":9007199254740993}','9007199254740992',false],
 ['const-equivalent','{"const":{"n":1e2}}','{"n":100.00}',true],
 ['enum-distinct','{"enum":[9007199254740993]}','9007199254740992',false],
 ['enum-equivalent','{"enum":[1.00]}','1e0',true],
 ['unique-distinct','{"uniqueItems":true}','[9007199254740992,9007199254740993]',true],
 ['unique-equivalent','{"uniqueItems":true}','[{"n":1.0},{"n":1e0}]',false],
 ['huge-min-count','{"minItems":1e10000}','[]',false],
 ['huge-max-count','{"maxItems":1e10000}','[1]',true],
 ['contains-large-min','{"contains":true,"minContains":1e10000}','[1]',false],
 ['contains-large-max','{"contains":true,"maxContains":1e10000}','[1]',true],
 ['conditional','{"if":{"const":9007199254740993},"then":false,"else":true}','9007199254740992',true],
 ['composition','{"oneOf":[{"const":9007199254740993},{"const":9007199254740992}]}','9007199254740992',true],
 ['literal-ref-data','{"const":{"$ref":"payload","n":9007199254740993}}','{"$ref":"payload","n":9007199254740993}',true],
];
let checked=0;
for(const version of ['3.1.2','3.2.1']) {
 const dialect=`https://spec.openapis.org/oas/${version.slice(0,3)}/dialect/base`,meta=await compile(await getSchema(dialect));
 for(const [name,schema,raw,valid]of cases) {
  const uri=`file:///approved/numbers/${version}-${name}.json`;
  const text=`{"openapi":"${version}","info":{"title":"Numeric oracle","version":"1"},"paths":{},"components":{"schemas":{"Target":${schema}}}}`;
  const {graph,docs}=createGraph({root:uri,resources:[{id:uri,text,generation:1,identity:'numeric-probe'}]});
  const doc=docs.get(uri);addExactSource(doc,graph);supplied.set(uri,{doc,graph,dialect});
  assert.equal(interpret(meta,exactInstance(doc,'/components/schemas/Target')).valid,true,`schema ${name}`);
  const compiled=await compile(await getSchema(uri+'#/components/schemas/Target'));
  const instance=new SourceDocument(raw,'file:///approved/data.json');
  const actual=interpret(compiled,exactInstance(instance),BASIC);
  assert.equal(actual.valid,valid,`${version} ${name}`);checked++;
 }
 for(const raw of ['{"minItems":1.00000000000000001}','{"multipleOf":0}','{"type":"invented"}']) {
  const doc=new SourceDocument(raw,'file:///approved/invalid-schema.json');
  assert.equal(interpret(meta,exactInstance(doc)).valid,false,raw);checked++;
 }
}
assert(attempts.every(uri=>supplied.has(uri)));
console.log(JSON.stringify({candidate:'@hyperjump/json-schema',version:'1.18.0',case:'exact-cst-numeric-keyword-adapter',checked,rationalOracles:1000,status:'working',attempts:attempts.length,limits:'4096 significant digits, 64 exponent characters; explicit work-limit errors, never rounded success',api:'pinned exported experimental keyword/instance APIs; not production validation'}));
