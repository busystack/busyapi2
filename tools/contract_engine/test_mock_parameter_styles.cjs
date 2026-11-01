const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const {mockStart,startMock}=require('./mock_test_capture.cjs');

function parameter(version,name,location,schema,extra={}){
 return {name,in:location,required:true,...(version==='2.0'?schema:{schema}),...extra};
}
function contract(version,routes){
 return {...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Native parameter styles',version:'1'},paths:Object.fromEntries(routes.map(([path,parameters])=>[path,{post:{parameters,responses:{204:{description:'Accepted'}}}}]))};
}
function wire(port,path,headers={}){
 return new Promise((resolve,reject)=>{
  const req=http.request({host:'127.0.0.1',port,path,method:'POST',headers:{'content-length':'0',...headers}},res=>{
   const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.once('error',reject);
   res.once('end',()=>resolve({status:res.statusCode,headers:res.headers,text:Buffer.concat(chunks).toString()}));
  });req.once('error',reject);req.end();
 });
}
const array={type:'array',minItems:2,maxItems:2,items:{type:'integer',enum:[0,2]}};
const object={type:'object',required:['A','b'],additionalProperties:false,properties:{A:{type:'integer',enum:[0]},b:{type:'boolean',enum:[false]}}};

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} query arrays use each native collection style`,{timeout:30000},async t=>{
 const styles=version==='2.0'?[['csv',','],['ssv','%20'],['tsv','%09'],['pipes','%7C'],['multi','&a=']]:
  [['form',','],['spaceDelimited','%20'],['pipeDelimited','%7C'],['form-explode','&a=']];
 const routes=styles.map(([style])=>['/'+style,[parameter(version,'a','query',array,version==='2.0'?{collectionFormat:style}:{style:style.replace('-explode',''),explode:style==='form-explode'})]]);
 const {port}=await startMock(t,mockStart(contract(version,routes)));
 for(const [style,separator]of styles){
  const valid=await wire(port,'/'+style+'?a=0'+separator+'2');assert.equal(valid.status,204,style+': '+valid.text);
  assert.equal((await wire(port,'/'+style+'?a=0'+separator+'3')).status,422,style);
  assert.equal((await wire(port,'/'+style)).status,422,style+' missing');
 }
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} native path array/object styles and query objects`,{timeout:30000},async t=>{
 const styles=[['simple',false],['simple',true],['label',false],['label',true],['matrix',false],['matrix',true]];
 const routes=styles.flatMap(([style,explode])=>[
  ['/array-'+style+'-'+explode+'/{a}',[parameter(version,'a','path',array,{style,explode})]],
  ['/object-'+style+'-'+explode+'/{a}',[parameter(version,'a','path',object,{style,explode})]],
 ]);
 routes.push(['/query-form',[parameter(version,'a','query',object,{style:'form',explode:false})]],
  ['/query-explode',[parameter(version,'a','query',object,{style:'form',explode:true})]],
  ['/query-deep',[parameter(version,'a','query',object,{style:'deepObject',explode:true})]]);
 const {port}=await startMock(t,mockStart(contract(version,routes)));
 for(const [style,explode]of styles){
  const a=style==='simple'?'0,2':style==='label'?(explode?'.0.2':'.0,2'):(explode?';a=0;a=2':';a=0,2');
  const o=style==='simple'?(explode?'A=0,b=false':'A,0,b,false'):style==='label'?(explode?'.A=0.b=false':'.A,0,b,false'):(explode?';A=0;b=false':';a=A,0,b,false');
  for(const [kind,value]of [['array',a],['object',o]]){
   const path='/'+kind+'-'+style+'-'+explode+'/'+value;
   const valid=await wire(port,path);assert.equal(valid.status,204,path+': '+valid.text);
   assert.equal((await wire(port,path.replace('0','1'))).status,422,path);
  }
 }
 for(const [route,query]of [['query-form','a=A,0,b,false'],['query-explode','A=0&b=false'],['query-deep','a[A]=0&a[b]=false']]){
  const valid=await wire(port,'/'+route+'?'+query);assert.equal(valid.status,204,route+': '+valid.text);
  assert.equal((await wire(port,'/'+route+'?'+query.replace('false','true'))).status,422,route);
 }
 assert.equal((await wire(port,'/query-explode?A=0&b=false&unexpected=1')).status,422,'additionalProperties is an assertion');
});

for(const version of ['3.0.4','2.0','3.1.2','3.2.1'])test(`${version} transport delimiters stay distinct from encoded data and header literals`,{timeout:20000},async t=>{
 const values={type:'array',minItems:2,maxItems:2,items:{type:'string',enum:['a,b','c.d']}};
 const routes=[['/query',[parameter(version,'a','query',values,version==='2.0'?{collectionFormat:'csv'}:{style:'form',explode:false})]],
  ['/path/{a}',[parameter(version,'a','path',values,version==='2.0'?{collectionFormat:'csv'}:{style:'simple',explode:false})]],
  ['/header',[parameter(version,'X-Literal','header',{type:'string',enum:['a%2Cb']})]]];
 const {port}=await startMock(t,mockStart(contract(version,routes)));
 for(const path of ['/query?a=a%2Cb,c.d','/path/a%2Cb,c.d']){
  const valid=await wire(port,path);assert.equal(valid.status,204,path+': '+valid.text);
  assert.equal((await wire(port,path.replace('%2C',','))).status,422,path);
 }
 assert.equal((await wire(port,'/header',{'x-literal':'a%2Cb'})).status,204);
 assert.equal((await wire(port,'/header',{'x-literal':'a,b'})).status,422);
});

test('3.2 cookie style preserves percent literals and separates array/object fields',{timeout:20000},async t=>{
 const routes=[['/literal',[parameter('3.2.1','Text','cookie',{type:'string',enum:['a%2Cb']},{style:'cookie'})]],
  ['/array',[parameter('3.2.1','a','cookie',array,{style:'cookie'})]],
  ['/object',[parameter('3.2.1','a','cookie',object,{style:'cookie'})]]];
 const {port}=await startMock(t,mockStart(contract('3.2.1',routes)));
 for(const [path,cookie]of [['/literal','Text=a%2Cb'],['/array','a=0; a=2'],['/object','A=0; b=false']]){
  const valid=await wire(port,path,{cookie});assert.equal(valid.status,204,path+': '+valid.text);
  assert.equal((await wire(port,path,{cookie:cookie.replace('a%2Cb','a,b').replace('0','1')})).status,422);
 }
});

test('3.2 whole-query JSON retains exact values and form content retains field structure',{timeout:20000},async t=>{
 const schema={type:'object',required:['zero','flag'],additionalProperties:false,properties:{zero:{type:'integer',enum:[0]},flag:{type:'boolean',enum:[false]}}};
 const routes=['application/json','application/x-www-form-urlencoded'].map((media,index)=>['/whole'+index,[{name:'whole',in:'querystring',required:true,content:{[media]:{schema}}}]]);
 const {port}=await startMock(t,mockStart(contract('3.2.1',routes)));
 for(const [route,good,bad]of [['/whole0',encodeURIComponent('{"zero":0,"flag":false}'),encodeURIComponent('{"zero":1,"flag":false}')],['/whole1','zero=0&flag=false','zero=0&flag=true']]){
  const valid=await wire(port,route+'?'+good);assert.equal(valid.status,204,route+': '+valid.text);
  assert.equal((await wire(port,route+'?'+bad)).status,422);
 }
});

for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} label data periods and quoted header commas retain their boundaries`,{timeout:20000},async t=>{
 const strings={type:'array',minItems:2,maxItems:2,items:{type:'string',enum:['a.b','c.d']}};
 const numbers={type:'array',minItems:2,maxItems:2,items:{type:'number',enum:[0.5,1.5]}};
 const quoted={type:'array',minItems:2,maxItems:2,items:{type:'string',enum:['"a,b"','c']}};
 const routes=[['/string/{a}',[parameter(version,'a','path',strings,{style:'label',explode:true})]],
  ['/number/{a}',[parameter(version,'a','path',numbers,{style:'label',explode:true})]],
  ['/header',[parameter(version,'X-List','header',quoted,{style:'simple'})]]];
 const {port}=await startMock(t,mockStart(contract(version,routes)));
 for(const path of ['/string/.a.b.c.d','/number/.0.5.1.5']){
  const valid=await wire(port,path);assert.equal(valid.status,204,path+': '+valid.text);
 }
 assert.equal((await wire(port,'/string/.a.b.c.e')).status,422);
 assert.equal((await wire(port,'/number/.0.5.2.5')).status,422);
 assert.equal((await wire(port,'/header',{'x-list':'"a,b",c'})).status,204);
 assert.equal((await wire(port,'/header',{'x-list':'"a,b,c'})).status,422);
});
