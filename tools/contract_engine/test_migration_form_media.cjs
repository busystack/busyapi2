const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {planMigration}=require('./dist/migration.cjs'),{SourceDocument}=require('./dist/document.cjs');
const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const mediaTypes=['application/x-www-form-urlencoded','Application/X-WWW-Form-Urlencoded','application/x-www-form-urlencoded; charset=utf-8','Application/X-WWW-Form-Urlencoded; Charset="UTF-8"'];
for(const version of versions)for(const format of ['yaml','json'])for(const media of mediaTypes)test(`${version} ${format} ${media} keeps its authored media declaration through form conversion`,async()=>{
 const root='file:///approved/api.'+format;
 const schema={type:'object',required:['name'],properties:{name:{type:'string'},flags:{type:'array',items:{type:'boolean'}}}};
 const document={openapi:version,info:{title:'Media 雪',version:'1'},servers:[{url:'https://api.invalid'}],paths:{'/items':{post:{requestBody:{required:true,content:{[media]:{schema}}},responses:{204:{description:'Empty'}}}}}};
 const text=format==='json'?JSON.stringify(document):'# Keep media organization\r\n'+YAML.stringify(document).replaceAll('\n','\r\n'),resources=[{id:root,text,generation:1}];
 const result=await planMigration({root,resources,snapshot:'media',targetVersion:'2.0',destination:'file:///output/'});
 assert.equal(result.complete,true,JSON.stringify(result.problems));assert.equal(result.status,'faithfully-convertible');assert.equal(resources[0].text,text);
 const output=result.outputs.find(resource=>resource.id===result.outputRoot),doc=new SourceDocument(output.text,output.id);
 assert.deepEqual(doc.node('/paths/~1items/post/consumes').value,[media]);
 const parameters=doc.node('/paths/~1items/post/parameters').value;
 assert.deepEqual(parameters.map(parameter=>[parameter.name,parameter.in]),[['name','formData'],['flags','formData']]);
 assert.equal(parameters[1].collectionFormat,'multi');
 if(format==='yaml')assert(output.text.startsWith('# Keep media organization\r\n'));
});

for(const version of ['3.0.4','3.2.1'])for(const format of ['yaml','json'])for(const media of mediaTypes.slice(1,3))test(`${version} ${format} ${media} retains an exact media-key blocker for an object-wide constraint`,async()=>{
 const root='file:///approved/api.'+format,escape=value=>value.replaceAll('~','~0').replaceAll('/','~1');
 const document={openapi:version,info:{title:'Media',version:'1'},paths:{'/items':{post:{requestBody:{required:true,content:{[media]:{schema:{type:'object',required:['name'],maxProperties:1,properties:{name:{type:'string'}}}}}},responses:{204:{description:'Empty'}}}}}};
 const text=format==='json'?JSON.stringify(document):YAML.stringify(document),resources=[{id:root,text,generation:1}];
 const result=await planMigration({root,resources,snapshot:'media-blocker',targetVersion:'2.0',destination:'file:///output/'});
 assert.equal(result.complete,false);assert.equal(result.status,'blocked');assert.deepEqual(result.outputs,[]);assert.equal(resources[0].text,text);
 const problem=result.problems.find(problem=>problem.code==='migration.form.object-constraint');
 assert(problem,JSON.stringify(result.problems));assert.equal(problem.resource,root);
 assert.equal(problem.pointer,'/paths/~1items/post/requestBody/content/'+escape(media)+'/schema/maxProperties');
 assert(problem.range[1]>problem.range[0]);
});
