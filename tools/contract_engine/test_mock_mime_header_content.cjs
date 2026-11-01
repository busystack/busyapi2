const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {mockStart,startMock,mockRequest}=require('./mock_test_capture.cjs');

const versions=['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
const good='{"id":9007199254740993.00,"flag":false,"empty":"","$ref":"literal"}';
function input(version,format){
 const header={required:true,content:{'application/json':{schema:{type:'object',required:['id','flag','empty','$ref'],properties:{id:{type:'integer',enum:['EXACT']},flag:{type:'boolean',enum:[false]},empty:{type:'string',maxLength:0},$ref:{type:'string',enum:['literal']}},additionalProperties:false}}}};
 const rule={contentType:'text/plain',headers:{'X-Meta':{$ref:'#/components/headers/Meta'}}},ordered=version.startsWith('3.2.');
 const media={schema:ordered?{type:'array',items:{type:'string'}}:{type:'object',properties:{value:{type:'string'}},required:['value']},...(ordered?{itemEncoding:rule}:{encoding:{value:rule}})};
 const value={openapi:version,info:{title:'Keep 雪',version:'unchanged'},paths:{'/parts':{post:{requestBody:{content:{'multipart/mixed':media}},responses:{204:{description:'Keep response'}}}}},components:{headers:{Meta:header}}};
 const text=(format==='json'?JSON.stringify(value):'# Keep CRLF\r\n'+YAML.stringify(value).replaceAll('\n','\r\n')).replaceAll(format==='json'?'"EXACT"':'EXACT','9007199254740993.00');
 return mockStart(text,{},'file:///mock-fixture/api.'+format);
}
const wire=value=>'--Fixture\r\nContent-Disposition: form-data; name="value"\r\nContent-Type: text/plain\r\n'+(value===null?'':'X-Meta: '+value+'\r\n')+'\r\nvalue\r\n--Fixture--\r\n';
for(const version of versions)for(const format of ['yaml','json'])test(`${version} ${format} actual mock evaluates captured content-based MIME Header values`,{timeout:20000},async t=>{
 const capture=input(version,format),original=JSON.stringify(capture.capture),{port}=await startMock(t,capture);
 const send=value=>mockRequest(port,'/parts',wire(value),{mediaType:'multipart/mixed; boundary=Fixture'});
 const positive=await send(good);assert.equal(positive.status,204,positive.text);
 for(const value of [good.replace('9007199254740993.00','9007199254740992'),good.replace('false','true'),good.replace('"empty":"",',''),null,'{"id":']){
  const result=await send(value);assert.equal(result.status,422,result.text);
  const findings=JSON.parse(result.headers['sl-violations']);assert(findings.some(finding=>(finding.schema?.resource??finding.source?.resource)==='file:///mock-fixture/api.'+format),JSON.stringify(findings));
 }
 assert.equal(JSON.stringify(capture.capture),original);
});
