const {test}=require('node:test');
const assert=require('node:assert/strict');
const YAML=require('yaml');
const {analyse}=require('./dist/model.cjs');

assert.ok(process.execArgv.includes('--disable-proto=throw'),'Run with the packaged Node prototype guard');
const values={
 schemas:{type:'string'},responses:{description:'Empty'},
 parameters:{name:'q',in:'query',schema:{type:'string'}},
 examples:{value:0},requestBodies:{content:{'text/plain':{schema:{type:'string'}}}},
 headers:{schema:{type:'string'}},securitySchemes:{type:'apiKey',in:'header',name:'X-Key'},
 links:{operationRef:'#/paths/~1items/get'},callbacks:{},
};
function input(version,format,components){
 const root='file:///component-names/api.'+format;
 const value={openapi:version,info:{title:'Component names',version:'1'},components,paths:{'/items':{get:{responses:{204:{description:'Empty'}}}}}};
 const text=format==='json'?JSON.stringify(value):'# preserved names\n'+YAML.stringify(value);
 return {root,snapshot:version+'-'+format,resources:[{id:root,text,generation:1}]};
}
for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])test(`${version} ${format} every Component map accepts ordinary prototype-like names under packaged hardening`,()=>{
 const components=Object.fromEntries(Object.entries(values).map(([group,value])=>[group,Object.fromEntries(['__proto__','constructor','toString'].map(name=>[name,value]))]));
 const packet=input(version,format,components),before=packet.resources[0].text;
 const report=analyse(packet);assert.equal(report.status,'complete',JSON.stringify(report.findings));
 for(const group of Object.keys(values))for(const name of ['__proto__','constructor','toString'])
  assert.ok(report.components.some(component=>component.group===group&&component.name===name),group+' '+name);
 assert.equal(packet.resources[0].text,before);
});
for(const version of ['3.0.0','3.0.4'])for(const format of ['yaml','json'])for(const [group,value]of Object.entries(values)){
 test(`${version} ${format} ${group} rejects a non-component name`,()=>{
  const packet=input(version,format,{[group]:{'invalid/name':value}}),before=packet.resources[0].text;
  const report=analyse(packet);assert.equal(report.status,'invalid');
  assert.ok(report.findings.some(finding=>finding.category==='openapi'&&finding.severity==='error'&&finding.pointer.startsWith('/components/'+group)),JSON.stringify(report.findings));
  assert.equal(packet.resources[0].text,before);
 });
 test(`${version} ${format} ${group} still validates named values`,()=>{
  const report=analyse(input(version,format,{[group]:{Valid:false}}));
  assert.equal(report.status,'invalid');
  assert.ok(report.findings.some(finding=>finding.category==='openapi'&&finding.severity==='error'&&finding.pointer.startsWith('/components/'+group)),JSON.stringify(report.findings));
 });
}
