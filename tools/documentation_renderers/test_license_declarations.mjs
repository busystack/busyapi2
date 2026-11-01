import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {declaredMitNotice} from './license_declarations.mjs';
// The repository fixture has a final LF; the verified published package.json
// does not. Reconstruct those actual bytes before testing its pinned digest.
const fixture=await readFile(new URL('./test_fixtures/redoc-opentelemetry-0.5.1-package.json',import.meta.url));
assert.equal(fixture.at(-1),10);
const original=fixture.subarray(0,fixture.length-1);
const copyright=Buffer.from('(c) Copyright 2025 Redocly Inc, all rights reserved.\n');
test('published SPDX declaration supplies separate redistribution terms, not a fabricated upstream license',async()=>{
  const saved=Buffer.from(original),raw=Buffer.from(copyright),result=await declaredMitNotice(original,copyright);
  assert.equal(result.record.name,'@redocly/redoc-opentelemetry');assert.equal(result.record.version,'0.5.1');assert.equal(result.record.license,'MIT');
  assert.equal(result.files.length,2);assert.equal(result.files[0].bytes.toString(),copyright.toString());
  const terms=result.files[1].bytes.toString();
  assert(terms.includes('License declaration: MIT'));assert(terms.includes(copyright.toString().trim()));
  for(const term of ['Permission is hereby granted','sublicense, and/or sell','shall be included','WITHOUT WARRANTY','LIABILITY'])assert(terms.includes(term));
  assert(!result.files.some(file=>file.name==='LICENSE'));assert.deepEqual(original,saved);assert.deepEqual(copyright,raw);
});
for(const change of [
  metadata=>metadata.license='UNLICENSED',metadata=>metadata.license='GPL-3.0-only',
  metadata=>metadata.version='0.5.2',metadata=>metadata.name='another-package',
  metadata=>metadata.restrictions='non-commercial only',
])test('changed declarations or additional licensing statements require another explicit review',async()=>{
  const metadata=JSON.parse(original);change(metadata);
  await assert.rejects(declaredMitNotice(Buffer.from(JSON.stringify(metadata,null,2)+'\n'),copyright),/needs review/);
});
test('changed original copyright or archive integrity cannot reuse the review',async()=>{
  await assert.rejects(declaredMitNotice(original,Buffer.from('Another copyright')),/needs review/);
  await assert.rejects(declaredMitNotice(original,copyright,{archive:Buffer.from('different package')}),/integrity changed/);
});
