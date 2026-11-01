const {test}=require('node:test');
const assert=require('node:assert/strict');
const http=require('node:http');
const YAML=require('yaml');
const {mockStart,startMock}=require('./mock_test_capture.cjs');
const versions=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function wire(port,path,headers={}){
 return new Promise((resolve,reject)=>{
  const request=http.request({host:'127.0.0.1',port,path,method:'GET',headers},response=>{
   const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.once('error',reject);
   response.once('end',()=>resolve({status:response.statusCode,headers:response.headers,text:Buffer.concat(chunks).toString()}));
  });request.once('error',reject);request.end();
 });
}
function fixture(version){
 const legacy=version==='2.0',modern=/^3\.[12]\./.test(version),schemes={
  Key:{type:'apiKey',in:'header',name:'X-Key'},Query:{type:'apiKey',in:'query',name:'Token'},
  Basic:legacy?{type:'basic'}:{type:'http',scheme:'basic'},
  OAuth:legacy?{type:'oauth2',flow:'application',tokenUrl:'https://issuer.invalid/token',scopes:{read:'Read'}}:{type:'oauth2',flows:{clientCredentials:{tokenUrl:'https://issuer.invalid/token',scopes:{read:'Read'}}}},
  ...(!legacy?{Cookie:{type:'apiKey',in:'cookie',name:'Token'}}:{}),
 };
 const operation=security=>({get:{security,responses:{204:{description:'Empty'}}}});
 return {...(legacy?{swagger:version}:{openapi:version}),info:{title:'Captured security wire',version:'1'},
  ...(legacy?{securityDefinitions:schemes}:{components:{securitySchemes:schemes}}),security:[{Key:[]}],
  paths:{'/and':operation([{Key:[],Query:[]}]),'/optional':operation([{}, {Key:[]}]),'/override':operation([]),
   '/basic':operation([{Basic:modern?['reader']:[]}]),'/oauth':operation([{OAuth:['read']}]),
   ...(!legacy?{'/cookie':operation([{Cookie:[]}])}:{}),
  }};
}
function nativeFailure(response,input,pointer){
 const findings=JSON.parse(response.headers['sl-violations']??'[]');
 assert.ok(findings.some(finding=>finding.nativeCode?.startsWith('runtime.request.security.')&&finding.source?.resource===input.capture.root&&finding.source.pointer===pointer&&finding.source.snapshot===input.capture.snapshot&&finding.source.range[1]>finding.source.range[0]),JSON.stringify(findings));
 assert.ok(!JSON.stringify(findings).includes('synthetic-private-value'));
}
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} mocks interpret captured security alternatives and credentials`,{timeout:30000},async t=>{
 const document=fixture(version),text=format==='yaml'?YAML.stringify(document):JSON.stringify(document),input=mockStart(text,{},'file:///security-fixture/api.'+format),original=JSON.stringify(input.capture),ready=await startMock(t,input),{port}=ready;
 await t.test('AND requirements keep field names, presence and empty values',async()=>{
  assert.equal((await wire(port,'/and?Token=synthetic-private-value',{'x-key':'synthetic-private-value'})).status,204);
  for(const [path,headers] of [['/and?token=synthetic-private-value',{'X-Key':'synthetic-private-value'}],['/and?Token=synthetic-private-value',{}],['/and',{'X-Key':'synthetic-private-value'}]]){
   const result=await wire(port,path,headers);assert.equal(result.status,401,result.text);nativeFailure(result,input,'/paths/~1and/get/security/0');
  }
  assert.equal((await wire(port,'/and?Token=',{'X-Key':''})).status,204);
  const duplicate=await wire(port,'/and?Token=one&Token=two',{'X-Key':'synthetic-private-value'});assert.equal(duplicate.status,401);nativeFailure(duplicate,input,'/paths/~1and/get/security/0');
 });
 await t.test('anonymous and empty overrides do not forbid unrelated credentials',async()=>{
  for(const path of ['/optional','/override'])for(const headers of [{},{authorization:'Bearer synthetic-private-value'}])assert.equal((await wire(port,path,headers)).status,204,path);
 });
 await t.test('Basic validates the wire grammar and permits colons in a password',async()=>{
  for(const header of ['Basic '+Buffer.from('user:password:tail').toString('base64'),'bAsIc  '+Buffer.from(':').toString('base64')])assert.equal((await wire(port,'/basic',{authorization:header})).status,204);
  for(const header of ['Basic !'+Buffer.from(':').toString('base64'),'Basic '+Buffer.from('missing-colon').toString('base64')]){
   const result=await wire(port,'/basic',{authorization:header});assert.equal(result.status,401);nativeFailure(result,input,'/paths/~1basic/get/security/0');
  }
 });
 await t.test('OAuth token syntax uses the case-insensitive HTTP authentication scheme',async()=>{
  assert.equal((await wire(port,'/oauth',{authorization:'bearer  synthetic-private-value'})).status,204);
  for(const authorization of ['Bearer','Bearer invalid token','Bearer invalid:token']){
   const result=await wire(port,'/oauth',{authorization});assert.equal(result.status,401);nativeFailure(result,input,'/paths/~1oauth/get/security/0');
  }
 });
 if(version!=='2.0')await t.test('API key cookies require complete case-sensitive names and unambiguous presence',async()=>{
  assert.equal((await wire(port,'/cookie',{cookie:'Token=synthetic-private-value'})).status,204);
  assert.equal((await wire(port,'/cookie',{cookie:'Token='})).status,204);
  for(const cookie of ['NotToken=synthetic-private-value','token=synthetic-private-value','Other=0&Token=synthetic-private-value','Token=one; Token=two','\u00a0Token=synthetic-private-value','Token =synthetic-private-value','Token=synthetic private','Token="synthetic private"']){
   const result=await wire(port,'/cookie',{cookie});assert.equal(result.status,401);nativeFailure(result,input,'/paths/~1cookie/get/security/0');
  }
 });
 assert.equal(ready.nativeSecurityValidation?.name,'busyapi-native-security');
 assert.equal(JSON.stringify(input.capture),original);
});

for(const format of ['yaml','json'])for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} ${format} original security references, Digest and incomplete mechanisms retain native ownership`,{timeout:30000},async t=>{
 const document=fixture(version),schemes=document.components.securitySchemes,operation=security=>({get:{security,responses:{204:{description:'Empty'}}}});
 schemes.Digest={type:'http',scheme:'Digest'};schemes.Unknown={type:'http',scheme:'not-implemented'};
 if(!version.startsWith('3.0.'))schemes.Certificate={type:'mutualTLS'};
 schemes.Alias={$ref:'#/components/securitySchemes/Key'};
 Object.assign(document.paths,{'/alias':operation([{Alias:[]}]),'/digest':operation([{Digest:[]}]),'/unknown':operation([{Unknown:[]}]),'/or':operation([{Unknown:[]},{Key:[]}]),...(!version.startsWith('3.0.')?{'/certificate':operation([{Certificate:[]}])}:{})});
 if(version.startsWith('3.2.'))document.paths['/uri']=operation([{'#/components/securitySchemes/Key':['reader']}]);
 const text=format==='yaml'?YAML.stringify(document):JSON.stringify(document),input=mockStart(text,{errors:false},'file:///security-extra/api.'+format),{port}=await startMock(t,input);
 assert.equal((await wire(port,'/alias',{'X-Key':'synthetic-private-value'})).status,204);
 if(version.startsWith('3.2.')){
  assert.equal((await wire(port,'/uri',{'X-Key':'synthetic-private-value'})).status,204);
  const invalid=await wire(port,'/uri');assert.equal(invalid.status,401);nativeFailure(invalid,input,'/paths/~1uri/get/security/0');
 }
 const digest='Digest username="User, Example", realm="public", nonce="n", uri="/digest", algorithm=SHA-256, qop=auth, nc=00000001, cnonce="c", response="'+'0'.repeat(64)+'"';
 const valid=await wire(port,'/digest',{authorization:digest});assert.equal(valid.status,204);assert.equal(valid.headers['sl-violations'],undefined);assert.equal(valid.headers['busyapi-request-security-complete'],'true');
 for(const authorization of [digest.replace('nc=00000001','nc=1'),digest.replace('nonce="n"','nonce="n", nonce="n"'),digest.replace('"'+'0'.repeat(64)+'"','"not-hex"')]){
  const result=await wire(port,'/digest',{authorization});assert.equal(result.status,401);nativeFailure(result,input,'/paths/~1digest/get/security/0');
 }
 for(const path of ['/unknown',...(!version.startsWith('3.0.')?['/certificate']:[])]){
  const result=await wire(port,path,{authorization:'Unknown synthetic-private-value'});assert.equal(result.status,501,result.text);assert.equal(result.headers['busyapi-request-security-complete'],'false');
  const body=JSON.parse(result.text);assert.equal(body.complete,false);assert.ok(body.findings.some(finding=>finding.code==='runtime.request.security.unchecked'&&finding.source.resource===input.capture.root&&finding.source.range[1]>finding.source.range[0]));
  assert.ok(!result.text.includes('synthetic-private-value'));
 }
 assert.equal((await wire(port,'/or',{'X-Key':'synthetic-private-value'})).status,204);
 assert.equal(input.capture.resources[0].text,text);
});

for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])test(`${version} native security uses raw prototype-like fields and does not confuse a report limit with OR proof`,{timeout:30000},async t=>{
 const document=fixture(version),schemes=version==='2.0'?document.securityDefinitions:document.components.securitySchemes;
 const name='__proto__';Object.defineProperty(schemes,name,{value:{type:'apiKey',in:'header',name},enumerable:true});
 document.paths['/prototype']={get:{security:[{[name]:[]}],responses:{204:{description:'Empty'}}}};
 const requirements=[];
 for(let index=0;index<210;index++){const key='Missing'+index;schemes[key]={type:'apiKey',in:'header',name:'X-Missing-'+index};requirements.push({[key]:[]});}
 requirements.push({Key:[]});document.paths['/late']={get:{security:requirements,responses:{204:{description:'Empty'}}}};
 const input=mockStart(document),{port}=await startMock(t,input);
 assert.equal((await wire(port,'/prototype',JSON.parse('{"__proto__":"synthetic-private-value"}'))).status,204);
 const missing=await wire(port,'/prototype');assert.equal(missing.status,401);nativeFailure(missing,input,'/paths/~1prototype/get/security/0');
 const last=await wire(port,'/late',{'X-Key':'synthetic-private-value'});assert.equal(last.status,204,last.text);assert.equal(last.headers['sl-violations'],undefined);
 const unchecked=await wire(port,'/late');assert.equal(unchecked.status,501);assert.equal(unchecked.headers['busyapi-request-security-complete'],'false');
});

for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])test(`${version} validation proxies retain their explicit forwarding policy and native security findings`,{timeout:30000},async t=>{
 const received=[],bytes=Buffer.from('{"n":9007199254740993,"ok":false}');
 const upstream=http.createServer((request,response)=>{
  received.push([request.method,request.url,request.headers['x-key']]);
  response.writeHead(200,{'content-type':'application/json','x-probe':'retained'});response.end(bytes);
 });
 await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));t.after(()=>new Promise(resolve=>upstream.close(resolve)));
 const document=fixture(version),response={description:'Observed',...(version==='2.0'?{schema:{type:'object'}}:{content:{'application/json':{schema:{type:'object'}}}})};
 document.paths['/and'].get.responses={200:response};if(version==='2.0')document.produces=['application/json'];
 if(version!=='2.0'){
  document.components.securitySchemes.Unknown={type:'http',scheme:'not-implemented'};
  document.paths['/unknown']={get:{security:[{Unknown:[]}],responses:{200:response}}};
 }
 const input=mockStart(document,{errors:false,upstream:'http://127.0.0.1:'+upstream.address().port}),{port}=await startMock(t,input);
 const good=await wire(port,'/and?Token=synthetic-private-value',{'X-Key':'synthetic-private-value'});assert.equal(good.status,200);assert.equal(good.text,bytes.toString());assert.equal(good.headers['sl-violations'],undefined);
 const bad=await wire(port,'/and?Token=synthetic-private-value');assert.equal(bad.status,200);assert.equal(bad.text,bytes.toString());assert.equal(bad.headers['x-probe'],'retained');assert.equal(bad.headers['busyapi-request-security-complete'],'true');nativeFailure(bad,input,'/paths/~1and/get/security/0');
 assert.deepEqual(received,[['GET','/and?Token=synthetic-private-value','synthetic-private-value'],['GET','/and?Token=synthetic-private-value',undefined]]);
 if(version!=='2.0'){
  assert.equal((await wire(port,'/unknown')).status,501);assert.equal(received.length,2);
 }
});

for(const version of ['2.0','3.0.4','3.1.2','3.2.1'])test(`${version} duplicate raw credential field lines never select an arbitrary value`,{timeout:30000},async t=>{
 const input=mockStart(fixture(version)),{port}=await startMock(t,input);
 const key=await wire(port,'/and?Token=synthetic-private-value',{'X-Key':['one','two']});assert.equal(key.status,401);nativeFailure(key,input,'/paths/~1and/get/security/0');
 const authorization='Basic '+Buffer.from('user:password').toString('base64');
 const basic=await wire(port,'/basic',{authorization:[authorization,authorization]});assert.equal(basic.status,401);nativeFailure(basic,input,'/paths/~1basic/get/security/0');
});
