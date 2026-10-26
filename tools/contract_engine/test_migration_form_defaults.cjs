const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const base=process.env.BUSYAPI_FORM_DOWNGRADE_BASELINE||__dirname;
const {planMigration}=require(base+'/dist/migration.cjs'),{SourceDocument}=require(base+'/dist/document.cjs');
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['json','yaml'])test(`${version} ${format} default array content encoding is decided by its owning family`,async()=>{
 const root='file:///approved/api.'+format;
 const media={schema:{type:'object',required:['name'],properties:{name:{type:'string'},tags:{type:'array',items:{type:'string'}}}}};
 const operation={requestBody:{required:true,content:{'application/x-www-form-urlencoded':media}},responses:{200:{description:'No payload'}}};
 const document={openapi:version,info:{title:'Default form',version:'1'},servers:[{url:'https://fixture.invalid'}],paths:{'/items':{post:operation}}};

 const text=format==='json'?JSON.stringify(document):YAML.stringify(document),resources=[{id:root,text,generation:1}];
 const result=await planMigration({root,resources,snapshot:'defaults',targetVersion:'2.0',destination:'file:///output/'});
 assert.equal(result.complete,true,JSON.stringify(result.problems));
 const output=result.outputs.find(value=>value.id===result.outputRoot),doc=new SourceDocument(output.text,output.id);
 assert.equal(doc.node('/paths/~1items/post/parameters/1/collectionFormat').value,'multi');

 assert.equal(resources[0].text,text);
});
