const {test}=require('node:test');
const assert=require('node:assert/strict');
const {nativeNumberIsExact}=require('./dist/exact_numbers.cjs');
test('native numeric witnesses distinguish exact binary values from decimal round trips and rounded integers',()=>{
 for(const [raw,expected]of [
  ['0',true],['-0',true],['0.0',true],['1e0',true],['1.00',true],['1.5',true],['0.5',true],['0.25',true],
  ['9007199254740991',true],['9007199254740992',true],['9007199254740993',false],['9007199254740994',true],
  ['-9007199254740993',false],['0.1',false],['0.10000000000000001',false],['1e308',false],['1e309',false],['1e-9999',false],
 ])assert.equal(nativeNumberIsExact(raw,Number(raw)),expected,raw);
 assert.equal(nativeNumberIsExact('0.1',0.5),false);
 assert.equal(nativeNumberIsExact('1',NaN),false);
 assert.equal(nativeNumberIsExact('1',Infinity),false);
});
test('independent integer power-of-two and finite-decimal identities cover normal and subnormal boundaries',()=>{
 for(let exponent=0;exponent<=1023;exponent+=7){
  const raw=(2n**BigInt(exponent)).toString();
  assert.equal(nativeNumberIsExact(raw,Number(raw)),true,'2^'+exponent);
  if(exponent>53)assert.equal(nativeNumberIsExact((BigInt(raw)+1n).toString(),Number(raw)),false,'rounded successor of 2^'+exponent);
 }
 for(const exponent of [1,2,3,10,52,53,1022,1074]){
  const digits=(5n**BigInt(exponent)).toString(),raw='0.'+'0'.repeat(exponent-digits.length)+digits;
  assert.equal(nativeNumberIsExact(raw,2**-exponent),true,'2^-'+exponent);
 }
 assert.equal(nativeNumberIsExact('5e-324',Number.MIN_VALUE),false,'shortest output is not the exact decimal value of the smallest subnormal');
});
