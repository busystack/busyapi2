const {test}=require('node:test'),assert=require('node:assert/strict'),YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');
const patches=['2.0','3.0.0','3.0.1','3.0.2','3.0.3','3.0.4','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'];
function input(version,format,namespace) {
 const root='file:///contracts/api.'+format,schema={type:'string',xml:{name:'document',namespace}},value={...(version==='2.0'?{swagger:version}:{openapi:version}),info:{title:'Namespace 雪',version:'1'},paths:{},...(version==='2.0'?{definitions:{Model:schema}}:{components:{schemas:{Model:schema}}})};
 const text=format==='json'?JSON.stringify(value):'# Keep namespace\r\n'+YAML.stringify(value).replaceAll('\n','\r\n');return {root,snapshot:'namespace-'+version,resources:[{id:root,text,generation:0}]};
}
const examples=[['relative','./relative',false],['empty','',false],['fragment','#local',false],['authority','//example.invalid/name',false],['space','https://example.invalid/a b',false],['percent','https://example.invalid/%zz',false],['http','https://example.invalid/name#part',true],['urn','urn:example:namespace',true],['escaped','https://example.invalid/%E9%9B%AA',true],['unicode','https://例え.invalid/雪#名前','iri']];
for(const version of patches)for(const format of ['yaml','json'])for(const [label,namespace,valid]of examples)test(`${version} ${format} XML namespace ${label} retains the family rule`,()=>{
 const params=input(version,format,namespace),before=JSON.stringify(params),result=analyse(params),expected=version==='2.0'||valid===true||valid==='iri'&&version.startsWith('3.2'),issues=result.findings.filter(f=>f.code==='xml.namespace.uri');
 assert.equal(issues.length,expected?0:1,JSON.stringify(result.findings));assert.equal(result.status,expected?'complete':'invalid');assert.equal(result.complete,true);assert.equal(JSON.stringify(params),before);
 if(!expected){const issue=issues[0];assert.equal(issue.resource,params.root);assert.equal(issue.pointer,version==='2.0'?'/definitions/Model/xml/namespace':'/components/schemas/Model/xml/namespace');assert.equal(issue.category,'openapi');assert(issue.range[1]>issue.range[0]);}
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const format of ['yaml','json'])test(`${version} ${format} unsupported namespace host notation is incomplete rather than valid or invalid`,()=>{
 const params=input(version,format,'https://[v1.future]/namespace'),result=analyse(params),issue=result.findings.find(f=>f.code==='xml.namespace.unsupported');assert(issue,JSON.stringify(result.findings));assert.equal(result.complete,false);assert.equal(result.status,'incomplete');assert.equal(issue.severity,'warning');assert.equal(issue.pointer,'/components/schemas/Model/xml/namespace');assert(!result.findings.some(f=>f.code==='xml.namespace.uri'));
});
for(const version of ['3.0.4','3.1.2','3.2.1'])test(`${version} namespace-looking example payloads are not schema annotations`,()=>{
 const params=input(version,'json','https://namespace.example.invalid'),value=JSON.parse(params.resources[0].text);value.components.schemas.Model.example={xml:{namespace:'./literal'},components:{schemas:{Fake:{xml:{namespace:'#literal'}}}}};value['x-extension']={xml:{namespace:''}};params.resources[0].text=JSON.stringify(value);const before=params.resources[0].text,result=analyse(params);assert.equal(result.status,'complete');assert.equal(params.resources[0].text,before);
});
for(const version of ['3.0.4','3.1.2','3.2.1'])for(const namespace of ['./relative','https://例え.invalid/雪'])test(`${version} schema reference siblings retain their own XML namespace interpretation ${namespace}`,()=>{
 const root='file:///contracts/references.json',value={openapi:version,info:{title:'Reference context',version:'1'},paths:{},components:{schemas:{Model:{$ref:'#/components/schemas/Target',xml:{namespace}},Target:{type:'string'}}}},text=JSON.stringify(value),params={root,snapshot:'namespace-reference-'+version,resources:[{id:root,text,generation:0}]},result=analyse(params),expected=version!=='3.0.4'&&(namespace==='./relative'||version==='3.1.2');
 assert.equal(result.findings.some(f=>f.code==='xml.namespace.uri'),expected);assert.equal(params.resources[0].text,text);
});
