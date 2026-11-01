// Authored relationship/content oracle shared by supplementary renderer tests.
// These are local fixtures, not a renderer-defined specification or parser.
export function authoredDocument(version) {
  const modern=version.startsWith('3.2.');
  const example=value=>modern?{dataValue:value}:{value};
  const notification=summary=>({post:{summary,responses:{204:{description:'Notification accepted'}}}});
  const value={openapi:version,info:{title:'Authored object inventory',version:'1',description:'Authored overview sentinel',
    contact:{name:'Local contact sentinel',url:'https://contact.invalid'},license:{name:'Contract license sentinel',identifier:'MIT'}},
    servers:[{url:'https://{host}.invalid',variables:{host:{default:'development',enum:['development','production'],description:'Server variable sentinel'}}}],
    security:[{Basic:[]},{Key:[],OAuth:['read']},{}],tags:[{name:'Inventory',description:'Authored tag sentinel'}],
    paths:{
      '/target':{get:{operationId:'target',summary:'Link target sentinel',responses:{204:{description:'Bodyless target sentinel'}}}},
      '/authored':{parameters:[{$ref:'#/components/parameters/Inherited'}],post:{tags:['Inventory'],summary:'Authored operation sentinel',deprecated:true,
        requestBody:{$ref:'#/components/requestBodies/Request'},
        callbacks:{Received:{$ref:'#/components/callbacks/Received'}},responses:{200:{$ref:'#/components/responses/Result'}}}},
    },webhooks:{Incoming:notification('Webhook incoming sentinel')},
    components:{
      parameters:{Inherited:{name:'filter',in:'query',description:'Inherited parameter sentinel',schema:{type:'string'},examples:{Filter:example('parameter example sentinel')}}},
      headers:{Trace:{description:'Response header sentinel',schema:{type:'string'}}},
      requestBodies:{Request:{description:'Referenced request sentinel',required:true,content:{
        'application/json':{schema:{$ref:'#/components/schemas/Composed'},examples:{Payload:{$ref:'#/components/examples/Payload'}}},
        'text/plain':{schema:{type:'string'},example:'Alternate media sentinel'},
      }}},
      responses:{Result:{description:'Referenced response sentinel',headers:{'X-Trace':{$ref:'#/components/headers/Trace'}},
        links:{Target:{$ref:'#/components/links/Target'}},content:{'application/json':{schema:{$ref:'#/components/schemas/Composed'},examples:{Payload:{$ref:'#/components/examples/Payload'}}}}}},
      examples:{Payload:{summary:'Reusable example sentinel',...example({value:'literal example sentinel',$ref:'literal payload identity'})}},
      callbacks:{Received:{'{$request.body#/callbackUrl}':notification('Callback received sentinel')}},
      links:{Target:{operationId:'target',description:'Authored Link description sentinel'}},
      securitySchemes:{Basic:{type:'http',scheme:'basic',description:'Basic declaration sentinel'},Key:{type:'apiKey',in:'header',name:'X-Example-Key',description:'Combined declaration sentinel'},
        OAuth:{type:'oauth2',description:'OAuth declaration sentinel',flows:{clientCredentials:{tokenUrl:'https://authorization.invalid/token',scopes:{read:'Read scope sentinel'}}}}},
      schemas:{
        Precise:{type:'integer',minimum:111},
        Tree:{$id:'https://schemas.invalid/inventory/tree',$dynamicAnchor:'node',type:'object',properties:{value:{type:['string','null'],description:'Tree property sentinel'},next:{$dynamicRef:'#node'}}},
        Composed:{description:'Composition sentinel',allOf:[{$ref:'#/components/schemas/Tree'},{type:'object',properties:{count:{$ref:'#/components/schemas/Precise'}}}],
          if:{required:['count']},then:{properties:{count:{minimum:0}}},else:{properties:{absent:{const:true}}},unevaluatedProperties:false},
        Tuple:{type:'array',prefixItems:[{type:'string'},false],items:false,description:'Tuple schema sentinel'},
      },
    },'x-preserved':{$ref:'literal extension identity',description:'Preserved extension sentinel'},
  };
  if(modern){
    value.tags[0].summary='Tag summary sentinel';
    value.paths['/authored'].additionalOperations={COPY:{summary:'Additional authored operation sentinel',responses:{200:{description:'Sequential media sentinel',content:{
      'application/json-seq':{itemSchema:{$ref:'#/components/schemas/Tree'},examples:{Sequence:{serializedValue:'{"value":"Serialized sequence sentinel"}\n'}}},
    }}}}};
    value.components.securitySchemes.OAuth.oauth2MetadataUrl='https://authorization.invalid/.well-known/oauth-authorization-server';
    value.components.securitySchemes.OAuth.deprecated=true;
    value.webhooks.Incoming.query={summary:'Webhook QUERY inventory sentinel',responses:{204:{description:'Bodyless webhook QUERY sentinel'}}};
    value.webhooks.Incoming.additionalOperations={COPY:{summary:'Webhook COPY inventory sentinel',responses:{204:{description:'Bodyless webhook COPY sentinel'}}}};
    const callback=value.components.callbacks.Received['{$request.body#/callbackUrl}'];
    callback.query={summary:'Callback QUERY inventory sentinel',responses:{204:{description:'Bodyless callback QUERY sentinel'}}};
    callback.additionalOperations={COPY:{summary:'Callback COPY inventory sentinel',responses:{200:{description:'Callback content sentinel',content:{
      'application/json':{schema:false,examples:{Exact:{dataValue:{$ref:'literal nested callback payload',number:'EXACT_CALLBACK'}}}},
    }}}}};
  }
  return JSON.stringify(value).replace('"minimum":111','"minimum":9007199254740993.00').replace('"EXACT_CALLBACK"','900719925474099312345678901.00');
}
