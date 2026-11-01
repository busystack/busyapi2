const {test}=require('node:test');
const assert=require('node:assert/strict');
const {policyExpressionNeedsIsolation:isolated}=require('./dist/policy_expression.cjs');
test('ordinary navigation and aliases need no project execution capability',()=>{
 for(const expression of ['$', '$.info.title', '$.x-token', '$..tags', '$.paths[*][get,put,post,delete]',
  '$[0:3:1]', '$[-1]', '$[0,2]', '$["application/json"]', '$["get"]', '$.default',
  '#OperationObject', '#Operation-Object.tags[*]', '#A_2["value"]'])assert.equal(isolated(expression),false,expression);
 for(const field of ['summary','application/json','@key','@path','constructor','value[0]','literal(?)'])
  assert.equal(isolated(field,true),false,field);
});
test('scripts, normalized quoted scripts, escapes and unfamiliar syntax require isolation',()=>{
 for(const expression of ['$[?(@.title)]', '$[(@.length-1)]', '$["(process.exit())"]',
  '$.constructor', '$["constr\\u0075ctor"]', '$["\\x28code\\x29"]',
  '$.\\u005f_proto__', '$.prototype', '$/*comment*/.info', '$.info //comment',
  '$.info;process.exit()', '$[`${process.exit()}`]', '$[1+1]', '$[9007199254740993]',
  '$.info@', 'not-a-root', '', '$["unterminated]', '$["?filter"]'])assert.equal(isolated(expression),true,expression);
 assert.equal(isolated('$[?(@.title)]',true),true);
});
