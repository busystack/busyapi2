// Independent positive export oracle: a referenced Callback Object, bodyless
// operation, and 3.2 additional operation with literal data and exact numbers.
// Only fixture construction uses JS objects; the numeric lexeme is authored
// text and is never parsed/reserialized through a JavaScript number.
export function callbackDocument(version) {
  const path={post:{summary:'Export callback POST sentinel',responses:{204:{description:'Bodyless export callback sentinel'}}}};
  if(version.startsWith('3.2.')){
    path.query={summary:'Export callback QUERY sentinel',responses:{204:{description:'Bodyless export QUERY sentinel'}}};
    path.additionalOperations={COPY:{summary:'Export callback COPY sentinel',responses:{200:{description:'Export callback content sentinel',content:{
      'application/json':{schema:true,examples:{Captured:{dataValue:{$ref:'literal nested callback payload',number:'EXACT_CALLBACK'}}}},
    }}}}};
  }
  return JSON.stringify({Shared:{'{$request.body#/callbackUrl}':path},'x-preserved':{$ref:'literal callback extension'}})
    .replace('"EXACT_CALLBACK"','900719925474099312345678901.00')+'\n';
}
