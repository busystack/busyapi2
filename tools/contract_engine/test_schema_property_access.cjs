const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {evaluateSchemas}=require('./dist/schema_evaluation.cjs');
const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
for(const version of versions)for(const format of ['yaml','json'])for(const mode of ['inline','reference','chain','external','ignored-true','ignored-false','ordinary'])
 test(`${version} ${format} ${mode} property access follows the referenced schema in its request occurrence`,async()=>{
  const root='file:///approved/access.'+format,external='file:///approved/read.'+format,definitions=version==='2.0'?'/definitions':'/components/schemas',legacy=version==='2.0'||version.startsWith('3.0');
  const property=mode==='inline'?{type:'string',readOnly:true}:mode==='ordinary'?{$ref:'#'+definitions+'/Value'}:mode==='ignored-true'?{$ref:'#'+definitions+'/Value',readOnly:true}:{$ref:mode==='external'?'read.'+format:('#'+definitions+'/'+(mode==='chain'?'Chain':'Read')),...(mode==='ignored-false'?{readOnly:false}:{})};
  const models={Value:{type:'string'},Read:{type:'string',readOnly:true},Chain:{$ref:'#'+definitions+'/Read'},Model:{type:'object',required:['token'],properties:{token:property}}};
  const value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Property access 雪',version:'1'},paths:{},...(version==='2.0'?{definitions:models}:{components:{schemas:models}}),'x-payload':{readOnly:true,$ref:'literal',n:'EXACT'}};
  const encode=value=>format==='json'?JSON.stringify(value):YAML.stringify(value),text=encode(value).replace('"EXACT"','9007199254740993.00').replace('EXACT','9007199254740993.00');
  const resources=[{id:root,text,generation:1},...(mode==='external'?[{id:external,text:encode({type:'string',readOnly:true}),generation:2}]:[])],before=resources.map(r=>r.text);
  const samples=[['request-body','{}'],['request-body','{"token":""}'],['request-body','{"token":false}'],['response-body','{}'],['response-body','{"token":""}'],['response-body','{"token":false}']];
  const capture={root,snapshot:'access-'+version+'-'+mode,resources,runtimeInstances:samples.map(([subject,text])=>({subject,text,location:'application/json',schema:{resource:root,pointer:definitions+'/Model'}}))};
  const result=await evaluateSchemas(capture);assert.equal(result.complete,true,JSON.stringify(result.findings));assert(result.runtimeEvaluations.every(e=>e.complete));
  const readOnly=['inline','reference','chain','external','ignored-false'].includes(mode);
  const expected=[version.startsWith('3.0')&&readOnly,version==='2.0'&&readOnly?false:true,false,false,true,false];
  assert.deepEqual(result.runtimeEvaluations.map(e=>e.valid),expected);
  assert.deepEqual(resources.map(r=>r.text),before);
  // readOnly on a reusable root alone is an annotation; its request-property
  // occurrence cannot contaminate standalone evaluation or another family.
  const direct=await evaluateSchemas({...capture,snapshot:'direct-'+mode,runtimeInstances:[{subject:'request-body',location:'application/json',text:'""',schema:{resource:root,pointer:definitions+'/Read'}}]});
  assert.equal(direct.complete,true);assert.equal(direct.runtimeEvaluations[0].valid,true);
 });

for(const version of versions)for(const ownerAlias of [false,true])test(`${version} YAML property access keeps aliased ${ownerAlias?'owner':'property'} context`,async()=>{
 const root='file:///approved/aliases.yaml',defs=version==='2.0'?'definitions':'components:\n  schemas',indent=version==='2.0'?'  ':'    ',pointer=version==='2.0'?'/definitions/Model':'/components/schemas/Model',target=version==='2.0'?'/definitions/Read':'/components/schemas/Read';
 const text=`${version==='2.0'?'swagger':'openapi'}: '${version}'\ninfo: {title: Aliases, version: '1'}\npaths: {}\nx-template: &template\n  ${ownerAlias?`type: object\n  required: [token]\n  properties:\n    token: {$ref: '#${target}'}`:'type: string\n  readOnly: true'}\n${defs}:\n${indent}Read: {type: string, readOnly: true}\n${indent}Model: ${ownerAlias?'*template':`{type: object, required: [token], properties: {token: *template}}`}\n`;
 const input={root,snapshot:'aliases-'+version,resources:[{id:root,text,generation:1}],runtimeInstances:[['request-body','{}'],['request-body','{"token":""}'],['response-body','{"token":""}']].map(([subject,text])=>({subject,text,location:'application/json',schema:{resource:root,pointer}}))};
 const result=await evaluateSchemas(input);assert.equal(result.complete,true,JSON.stringify(result));
 assert.deepEqual(result.runtimeEvaluations.map(e=>e.valid),[version.startsWith('3.0'),version!=='2.0',true]);assert.equal(input.resources[0].text,text);
});
for(const version of versions.filter(v=>v.startsWith('3.0')))for(const format of ['yaml','json'])test(`${version} ${format} referenced writeOnly keeps request and response required roles`,async()=>{
 const root='file:///approved/write.'+format,value={openapi:version,info:{title:'Write',version:'1'},paths:{},components:{schemas:{Write:{type:'string',writeOnly:true},Chain:{$ref:'#/components/schemas/Write'},Model:{type:'object',required:['secret'],properties:{secret:{$ref:'#/components/schemas/Chain',writeOnly:false}}}}}};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),input={root,snapshot:'write-'+version,resources:[{id:root,text,generation:1}],runtimeInstances:[['request-body','{}'],['request-body','{"secret":""}'],['response-body','{}'],['response-body','{"secret":""}']].map(([subject,text])=>({subject,text,location:'application/json',schema:{resource:root,pointer:'/components/schemas/Model'}}))};
 const result=await evaluateSchemas(input);assert.equal(result.complete,true,JSON.stringify(result));assert.deepEqual(result.runtimeEvaluations.map(e=>e.valid),[false,true,true,true]);assert.equal(input.resources[0].text,text);
});

for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])for(const name of ['a/b~雪','__proto__',''])test(`${version} ${format} access flags preserve escaped property ${JSON.stringify(name)} and literal values`,async()=>{
 const root='file:///approved/escaped.'+format,defs=version==='2.0'?'/definitions':'/components/schemas',models={Read:{readOnly:true},Model:{type:'object',required:[name],properties:Object.fromEntries([[name,{$ref:'#'+defs+'/Read'}]])}},value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Exact properties',version:'1'},paths:{},...(version==='2.0'?{definitions:models}:{components:{schemas:models}})};
 const text=format==='json'?JSON.stringify(value):YAML.stringify(value),samples=[null,false,0,'',{},[]],input={root,snapshot:'escaped-'+version,resources:[{id:root,text,generation:1}],runtimeInstances:['request-body','response-body'].flatMap(subject=>samples.map(value=>({subject,text:JSON.stringify(Object.fromEntries([[name,value]])),location:'application/json',schema:{resource:root,pointer:defs+'/Model'}})))};
 const result=await evaluateSchemas(input);assert.equal(result.complete,true,JSON.stringify(result));assert.deepEqual(result.runtimeEvaluations.map(e=>e.valid),[...samples.map(()=>version!=='2.0'),...samples.map(()=>true)]);assert.equal(input.resources[0].text,text);
 if(version==='2.0')assert.equal(result.runtimeFindings.length>=samples.length,true,'Every rejected request retains actual schema findings');
});
