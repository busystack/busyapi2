const {test}=require('node:test'),assert=require('node:assert/strict');
const base=process.env.BUSYAPI_FORM_DOWNGRADE_BASELINE||__dirname;
const {planMigration}=require(base+'/dist/migration.cjs'),{SourceDocument}=require(base+'/dist/document.cjs');
for(const version of ['3.0.0','3.0.4','3.1.2','3.2.1'])for(const query of [false,true])test(`${version} YAML query=${query} form relocation retains property comments and exact lexical values`,async()=>{
 const root='file:///approved/api.yaml';
 const text=('# Keep organization\nopenapi: '+version+'\ninfo: {title: Form, version: "1"}\nservers: [{url: https://fixture.invalid}]\npaths:\n  /items:\n    post:\n'+(query?'      parameters: [{name: tenant, in: query, schema: {type: string}}]\n':'')+'      requestBody: # Keep group\n        required: true\n        content:\n          application/x-www-form-urlencoded:\n            schema:\n              type: object\n              required: [name]\n              properties:\n                # Keep first field\n                name:\n                  type: string # Keep type\n                  description: "literal # never comment"\n                  x-data: {"$ref": "./literal.json#/example", zero: 0, flag: false}\n                # Keep second field\n                exact: # Keep exact owner\n                  type: integer\n                  enum: [9007199254740993.00] # Keep exact bound\n      responses: {"200": {description: Empty}}\n').replaceAll('\n','\r\n');
 const resources=[{id:root,text,generation:1}],result=await planMigration({root,resources,snapshot:'comments',targetVersion:'2.0',destination:'file:///output/'});
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(resources[0].text,text);
 const output=result.outputs.find(value=>value.id===result.outputRoot),doc=new SourceDocument(output.text,output.id);
 for(const comment of ['# Keep organization','# Keep group','# Keep first field','# Keep type','# Keep second field','# Keep exact owner','# Keep exact bound'])
  assert.equal(output.text.split(comment).length-1,1,comment+'\n'+output.text);
 assert.equal(doc.dataJson('/paths/~1items/post/parameters/'+(query?2:1)+'/enum/0'),'9007199254740993.00');
 assert.equal(doc.node('/paths/~1items/post/parameters/'+(query?1:0)+'/description').value,'literal # never comment');
 assert.equal(doc.node('/paths/~1items/post/parameters/'+(query?1:0)+'/x-data/$ref').value,'./literal.json#/example');
 assert(!/(?<!\r)\n/.test(output.text));assert.equal(doc.issues.length,0);
});
for(const version of ['3.0.0','3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} extracted form names retain escaped pointers and literal reference-looking data`,async()=>{
 const root='file:///approved/api.'+format,names=['a/b','~key','雪','$ref','__proto__'];
 const schema={type:'object',required:['a/b'],properties:Object.fromEntries(names.map(name=>[name,{type:'string','x-payload':{$ref:'./literal.json#/never-resolve',empty:'',flag:false,zero:0}}]))};
 const operation={requestBody:{required:true,content:{'application/x-www-form-urlencoded':{schema}}},responses:{200:{description:'No payload'}}};
 const document={openapi:version,info:{title:'Names',version:'1'},servers:[{url:'https://fixture.invalid'}],paths:{'/items':{post:operation}}};
 const text=format==='json'?JSON.stringify(document):require(base+'/node_modules/yaml').stringify(document),resources=[{id:root,text,generation:1}];
 const result=await planMigration({root,resources,snapshot:'field-names',targetVersion:'2.0',destination:'file:///output/'});
 assert.equal(result.complete,true,JSON.stringify(result.problems));const output=result.outputs.find(value=>value.id===result.outputRoot),doc=new SourceDocument(output.text,output.id);
 assert.deepEqual(doc.node('/paths/~1items/post/parameters').value.map(parameter=>parameter.name),names);
 for(let index=0;index<names.length;index++)assert.equal(doc.dataJson('/paths/~1items/post/parameters/'+index+'/x-payload'),JSON.stringify({$ref:'./literal.json#/never-resolve',empty:'',flag:false,zero:0}));
 assert.equal(resources[0].text,text);
});
