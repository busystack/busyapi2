const {test}=require('node:test'),assert=require('node:assert/strict');
const {SourceDocument}=require((process.env.BUSYAPI_REVIEW_DIST||__dirname+'/dist')+'/document.cjs');
for(const root of [true,false])for(const comments of [true,false])for(const index of [0,1,2])test(`block sequence root=${root} comments=${comments} removes item ${index} by its syntax marker`,()=>{
 const indent=root?'':'  ',prefix=root?'':'items:\r\n',pointer=root?'':'/items';
 const text=prefix+['one','two','雪'].map(name=>indent+'-'+(comments?' # '+name:'')+'\r\n'+indent+'  name: '+name+'\r\n').join('');
 const doc=new SourceDocument(text,'file:///sequence.yaml'),output=doc.remove(pointer+'/'+index),changed=new SourceDocument(output,doc.id);
 assert.equal(changed.issues.length,0,output);
 assert.deepEqual(JSON.parse(changed.dataJson(pointer)),['one','two','雪'].filter((_,at)=>at!==index).map(name=>({name})),output);
 assert(!output.includes('- # '+['one','two','雪'][index]),output);
 for(const name of ['one','two','雪'].filter((_,at)=>at!==index))if(comments)assert(output.includes('# '+name),output);
 assert.equal(doc.text,text);
});
for(const text of ['- # Only\n  name: value\n','items:\n  - # Only\n    name: value\n','- - # Only\n    name: value\n'])test(`single block sequence member has no phantom null: ${JSON.stringify(text)}`,()=>{
 const pointer=text.startsWith('items:')?'/items':text.startsWith('- -')?'/0':'';
 const doc=new SourceDocument(text,'file:///sequence.yaml'),output=doc.remove(pointer+'/0'),changed=new SourceDocument(output,doc.id);
 assert.equal(changed.issues.length,0,output);assert.equal(changed.dataJson(pointer),'[]',output);
});
