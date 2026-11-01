// Original legal mixed-dialect schema roots; reused by engine and renderer tests.
const root='https://contracts.invalid/api.json',external='https://contracts.invalid/models.json';
function mixed(version,{pathItem=false}={}) {
 const operation={summary:'Mixed dialect operation sentinel',responses:{200:{description:'Shared dialect response',content:{'application/json':{schema:{$ref:'models.json#/components/schemas/A'},example:{$ref:'literal example sentinel',exact:111}}}}}};
 const document={openapi:version,info:{title:'Mixed dialect renderer',version:'1'},paths:{'/value':version.startsWith('3.2')?{additionalOperations:{COPY:operation}}:{get:operation}},components:{schemas:{B:{$ref:'models.json#/components/schemas/B'}}},'x-busyapi-display-resources':{must:'remain authored'}};
 const model={openapi:version,info:{title:'Original model resource',version:'1'},paths:{},components:{schemas:{
  A:{$schema:'https://json-schema.org/draft/2020-12/schema',type:'object',description:'2020 dialect schema sentinel',properties:{sibling:{$ref:'#/components/schemas/B'}},examples:[{sibling:'okay'}]},
  B:{type:'string',description:'OAS dialect schema sentinel',minLength:2,examples:['okay']},
 }}};
 if(pathItem) {
  model.paths['/template']=document.paths['/value'];
  document.paths['/value']={$ref:'models.json#/paths/~1template'};
 }
 return {root,snapshot:'mixed-reference-display-'+version,resources:[{id:root,text:JSON.stringify(document).replace('111','9007199254740993.00'),generation:1},{id:external,text:JSON.stringify(model).replace('111','9007199254740993.00'),generation:1}]};
}
function pathContexts(version) {
 const operation={operationId:'shared',summary:'Shared contextual operation',responses:{204:{description:'Intentionally bodyless'}}};
 const item=version.startsWith('3.2')?{additionalOperations:{COPY:operation}}:{get:operation};
 const occurrence=name=>({$ref:'models.json#/Shared',servers:[{url:'https://'+name+'.invalid'}],parameters:[{name:'id',in:'path',required:true,description:name+' parameter owner',schema:{type:'string'}}]});
 const document={openapi:version,info:{title:'Path Item contexts',version:'1'},paths:{'/one/{id}':occurrence('one'),'/two/{id}':occurrence('two')}};
 return {root,snapshot:'path-item-display-'+version,resources:[{id:root,text:JSON.stringify(document),generation:1},{id:external,text:JSON.stringify({Shared:item}),generation:1}]};
}
module.exports={mixed,pathContexts};
