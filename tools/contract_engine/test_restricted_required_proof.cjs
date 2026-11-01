const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const YAML=require('yaml');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {analyse}=require(path.join(process.env.BUSYAPI_REQUIRED_PROOF_BASELINE||__dirname,'dist/model.cjs'));

function packet(version,format,mode){
 const swagger=version==='2.0',base=swagger?'#/definitions/':'#/components/schemas/';
 const name='kind/~雪',subject={type:'object',discriminator:swagger?name:{propertyName:name},allOf:[{$ref:base+'Chain0'}]};
 const schemas={Subject:subject},length=mode==='short'?64:['bounded','bounded-anyOf','bounded-oneOf','bounded-with-required'].includes(mode)?130:1;
 for(let index=0;index<length;index++)schemas['Chain'+index]=index+1===length?
  {type:'object',required:[name],properties:{[name]:{type:'string'}}}:{$ref:base+'Chain'+(index+1)};
 if(mode==='optional')delete schemas.Chain0.required;
 if(mode==='unavailable')subject.allOf=[{$ref:'missing.'+format+'#/Schema'}];
 if(mode==='bounded-anyOf'||mode==='bounded-oneOf'){
  subject[mode.slice('bounded-'.length)]=[...subject.allOf,{type:'object',required:[name]}];delete subject.allOf;
 }
 if(mode==='bounded-with-required')subject.allOf.push({type:'object',required:[name]});
 if(mode==='shared-dag'){
  for(let index=0;index<18;index++)schemas['Chain'+index]={allOf:[{$ref:base+'Chain'+(index+1)},{$ref:base+'Chain'+(index+1)}]};
  schemas.Chain18={type:'object',properties:{[name]:{type:'string'}}};
 }
 if(mode==='cycle-required'||mode==='cycle-optional'){
  schemas.Chain0={allOf:[{$ref:base+'Chain1'},...(mode==='cycle-required'?[{type:'object',required:[name],properties:{[name]:{type:'string'}}}]:[])]};
  schemas.Chain1={$ref:base+'Chain0'};
  schemas.Other={...subject,allOf:[{$ref:base+'Chain1'}]};
 }
 // Controls retain each family's own discriminator rules.
 if(swagger){subject.required=[name];subject.properties={[name]:{type:'string'}};}
 if(version.startsWith('3.2.')){
  const adjacent=['anyOf','oneOf'].find(keyword=>Array.isArray(subject[keyword]));
  subject.discriminator.defaultMapping=adjacent?base+'Subject/'+adjacent+'/1':'Fallback';
  schemas.Fallback={allOf:[{$ref:base+'Subject'}]};
 }
 const value={...(swagger?{swagger:version}:{openapi:version}),info:{title:'Keep native proof',version:'business'},paths:{},...(swagger?{definitions:schemas}:{components:{schemas}}),'x-number':'EXACT','x-payload':{$ref:'literal.json',discriminator:{propertyName:'decoy'}}};
 const text=(format==='yaml'?'# Keep original CRLF\r\n'+YAML.stringify(value).replaceAll('\n','\r\n'):JSON.stringify(value)+'\r\n').replaceAll('"EXACT"','9007199254740993.00').replaceAll('EXACT','9007199254740993.00');
 const root='file:///controlled/proof.'+format;
 return {root,snapshot:version+format+mode,resources:[{id:root,text,generation:7,identity:createHash('sha256').update(text).digest('hex')}]};
}

for(const version of ['3.0.0','3.0.1','3.0.2','3.0.3','3.0.4'])for(const format of ['yaml','json'])
 for(const mode of ['direct','short','bounded','bounded-anyOf','bounded-oneOf','bounded-with-required','optional','unavailable','shared-dag','cycle-required','cycle-optional'])
  test(`${version} ${format} discriminator required proof ${mode} distinguishes violations and incomplete evaluation`,()=>{
   const input=packet(version,format,mode),before=input.resources[0].text,result=analyse(input);
   const required=result.findings.filter(note=>note.code==='discriminator.required');
   const incomplete=result.findings.filter(note=>note.code==='discriminator.required.incomplete');
   const limited=['bounded','bounded-anyOf','bounded-oneOf','unavailable'].includes(mode),optional=['optional','shared-dag','cycle-optional'].includes(mode);
   assert.equal(result.complete,!limited,JSON.stringify(result.findings));
   assert.equal(result.status,limited?'incomplete':optional?'invalid':'complete',JSON.stringify(result.findings));
   assert.equal(required.length,mode==='cycle-optional'?2:optional?1:0,JSON.stringify(result.findings));
   assert.equal(incomplete.length,limited?1:0,JSON.stringify(result.findings));
   if(limited){
    const note=incomplete[0];assert.equal(note.resource,input.root);assert.equal(note.pointer,'/components/schemas/Subject/discriminator/propertyName');
    assert.equal(note.severity,'warning');assert.equal(note.incomplete,true);assert(note.range[1]>note.range[0]);
    assert(result.findings.filter(note=>note.severity==='error').every(note=>mode==='unavailable'&&note.code==='reference.unavailable'),JSON.stringify(result.findings));
    if(mode==='unavailable')assert(result.findings.some(note=>note.code==='reference.unavailable'));
   }
   assert.equal(input.resources[0].text,before);assert(before.includes('9007199254740993.00'));
   assert(!result.findings.some(note=>note.pointer.startsWith('/x-payload')));
  });

for(const version of ['2.0','3.1.0','3.1.1','3.1.2','3.2.0','3.2.1'])for(const format of ['yaml','json'])
 for(const mode of ['direct','bounded'])test(`${version} ${format} ${mode} retains its own required/discriminator policy`,()=>{
  const input=packet(version,format,mode),before=input.resources[0].text,result=analyse(input);
  assert.equal(result.complete,true,JSON.stringify(result.findings));assert.equal(result.status,'complete',JSON.stringify(result.findings));
  assert(!result.findings.some(note=>note.code.startsWith('discriminator.required')),JSON.stringify(result.findings));
  assert.equal(input.resources[0].text,before);
 });

for(const format of ['yaml','json'])test(`3.0.4 ${format} a wide inheritance proof stops incomplete at its work bound`,()=>{
 const value={openapi:'3.0.4',info:{title:'Bounded required proof',version:'business'},paths:{},components:{schemas:{Subject:{type:'object',discriminator:{propertyName:'kind'},allOf:Array.from({length:20010},()=>({type:'object'}))}}}};
 const root='file:///controlled/wide.'+format,text=(format==='yaml'?'# Keep wide source\r\n':'')+JSON.stringify(value)+'\r\n';
 const input={root,snapshot:'wide-'+format,resources:[{id:root,text,generation:1}]},result=analyse(input);
 assert.equal(result.complete,false);assert.equal(result.status,'incomplete',JSON.stringify(result.findings));
 assert(!result.findings.some(note=>note.code==='discriminator.required'),JSON.stringify(result.findings));
 const findings=result.findings.filter(note=>note.code==='discriminator.required.incomplete');assert.equal(findings.length,1);
 assert.equal(findings[0].resource,root);assert.equal(findings[0].pointer,'/components/schemas/Subject/discriminator/propertyName');
 assert.equal(findings[0].severity,'warning');assert.equal(findings[0].incomplete,true);assert.equal(input.resources[0].text,text);
});

for(const format of ['yaml','json'])test(`3.0.4 ${format} a long discriminator name stays bounded across many schemas`,()=>{
 const script=`
 const assert=require('node:assert/strict'),path=require('node:path');
 const {analyse}=require(path.join(process.argv[1],'dist/model.cjs'));
 const name='k'.repeat(131072),format=process.argv[2];
 const allOf=Array.from({length:1200},()=>({type:'object'}));allOf.push({required:[name]});
 const value={openapi:'3.0.4',info:{title:'Bounded metadata',version:'business'},paths:{},components:{schemas:{Subject:{type:'object',discriminator:{propertyName:name},allOf}}}};
 const root='file:///controlled/metadata.'+format,text=(format==='yaml'?'# Keep source\\r\\n':'')+JSON.stringify(value)+'\\r\\n';
 const input={root,snapshot:'metadata',resources:[{id:root,text,generation:1}]},result=analyse(input);
 assert.equal(result.complete,true);assert.equal(result.status,'complete',JSON.stringify(result.findings));
 assert.equal(input.resources[0].text,text);console.log(JSON.stringify({complete:true,sourceUnchanged:true}));
 `;
 const result=spawnSync(process.execPath,['--max-old-space-size=192','-e',script,process.env.BUSYAPI_REQUIRED_PROOF_BASELINE||__dirname,format],{encoding:'utf8',maxBuffer:1024*1024});
 assert.equal(result.status,0,result.stderr);assert.equal(result.signal,null);
 assert.deepEqual(JSON.parse(result.stdout),{complete:true,sourceUnchanged:true});
});
