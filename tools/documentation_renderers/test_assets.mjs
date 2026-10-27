import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,readdir,rm,symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {buildRedocAssets,buildSwaggerAssets} from './build_assets.mjs';
import {prepareDocumentationAssets} from '../prepare_documentation_assets.mjs';
import {redocRedistribution} from './asset_licenses.mjs';
import {swaggerRedistribution} from './swagger_licenses.mjs';
import {compileSwaggerModule} from './swagger_module_build.mjs';
import {fileURLToPath} from 'node:url';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');

test('assembled Redoc assets contain exact reviewed code, all notices and no development tool distribution',async()=>{
  const {manifest,files}=await buildRedocAssets();
  assert.deepEqual(Object.keys(files).sort(),['THIRD_PARTY_NOTICES.txt','assets.json','bootstrap.js','redoc.js','third-party.json']);
  for(const [name,digest]of Object.entries(manifest.files))assert.equal(hash(files[name]),digest);
  assert.deepEqual(manifest.adapter,{producer:'busyapi-redoc-read-only',version:'8',package:'redoc',packageVersion:'3.0.1'});
  assert.equal(manifest.identity,hash(JSON.stringify({adapter:manifest.adapter,files:manifest.files})));
  const inventory=JSON.parse(files['third-party.json']);
  assert.equal(inventory.packages.length,52);
  for(const name of ['playwright','chromium','@redocly/cli','@apidevtools/json-schema-ref-parser'])assert(!inventory.packages.some(record=>record.name===name));
  const notices=files['THIRD_PARTY_NOTICES.txt'].toString();
  for(const expected of ['(c) Copyright 2025 Redocly Inc, all rights reserved.','Permission is hereby granted, free of charge','THE SOFTWARE IS PROVIDED "AS IS"',
    'Meta Platforms, Inc. and affiliates','React Training LLC','Shopify Inc.','Pooya Parsa','Roman Shtylman','Douglas Christopher Wilson','Nathan Friedly',
    'jQuery Foundation','Jeremy Ashkenas','DocumentCloud and Investigative Reporters','Apache License','Copyright (c) Felix Böhm','Copyright Mathias Bynens'])assert(notices.includes(expected),'Missing required notice '+expected);
  const adapted=inventory.packages.find(record=>record.name==='@remix-run/route-pattern').embeddedSources;
  assert.equal(adapted[0].name,'punycode.js');assert.equal(adapted[0].version,'9e1b2cda98d215d3a73fcbfe93c62e021f4ba768');
  const helpers=inventory.packages.find(record=>record.name==='dompurify').embeddedSources;
  assert.equal(helpers[0].name,'regenerator-runtime');assert.equal(helpers[0].license,'MIT');
  assert.equal(helpers[0].sourceSha256,'c44274a7959cfdd4da871fa78a5d5fbbef55db68d118c5c0833bc4b5cf9633ad');
  assert(notices.includes(helpers[0].declaration));assert(notices.includes('Copyright (c) 2014-present, Facebook, Inc.'));
  const declared=inventory.packages.find(record=>record.name==='@redocly/redoc-opentelemetry');
  assert.equal(declared.version,'0.5.1');assert.equal(declared.license,'MIT');
  assert(declared.requiredNotices.some(notice=>notice.declaration==='license_declarations.json'));
});
test('unreviewed compilation inputs fail closed rather than producing empty notices',async()=>{
  await assert.rejects(redocRedistribution({inputs:{'tools/documentation_renderers/node_modules/unreviewed/index.js':{}}}),/unreviewed dependency/);
  await assert.rejects(redocRedistribution({inputs:{'tools/probes/m2/node_modules/redoc/bundles/redoc.js':{}}}),/outside its locked asset tree/);
});
test('assembled Swagger module retains original and adapted notices with truthful distribution roles',async()=>{
  const {manifest,files}=await buildSwaggerAssets();
  assert.equal(manifest.preset,'swagger');
  assert.deepEqual(manifest.adapter,{producer:'busyapi-swagger-read-only',version:'7',package:'swagger-ui',packageVersion:'5.33.2',
    clientPackage:'swagger-client',clientPackageVersion:'3.38.2'});
  assert.equal(manifest.identity,hash(JSON.stringify({adapter:manifest.adapter,files:manifest.files})));
  assert.deepEqual(Object.keys(files).sort(),['THIRD_PARTY_NOTICES.txt','assets.json','bootstrap.js','swagger-ui-es-bundle-core.js.LICENSE.txt','swagger.css','swagger.js','third-party.json']);
  for(const [name,digest]of Object.entries(manifest.files))assert.equal(hash(files[name]),digest);
  const inventory=JSON.parse(files['third-party.json']),notices=files['THIRD_PARTY_NOTICES.txt'].toString();
  assert.equal(inventory.packages.length,118);
  assert.equal(inventory.packages.filter(record=>record.distribution==='build-input-omitted-from-output').length,2);
  assert.equal(inventory.packages.filter(record=>record.distribution==='embedded-in-published-swagger-ui-module').length,13);
  assert.equal(inventory.packages.find(record=>record.name==='sha.js').license,'(MIT AND BSD-3-Clause)');
  for(const name of ['playwright','chromium','@redocly/cli','redoc','@redocly/redoc-opentelemetry'])assert(!inventory.packages.some(record=>record.name===name));
  for(const value of ['SmartBear Software Inc.','Copyright (c) 2024 Lowell D. Thomas','Copyright (c) 2013 IETF Trust','Copyright (c) 2014-present, Facebook, Inc.',
      'Copyright (c) 2017 Evgeny Poberezkin','Copyright (c) 2013-2016 Scott Sauyet and Michael Hurley','Copyright 2010 - 2014 Sami Samhuri',
      'Permission is hereby granted, free of charge','Apache License','Redistribution and use in source and binary forms'])assert(notices.includes(value),'Missing original notice '+value);
  assert(files['swagger-ui-es-bundle-core.js.LICENSE.txt'].length>0);
});
test('Swagger review rejects another dependency tree, incomplete input closure and changed output presence',async()=>{
  const result=await compileSwaggerModule({directory:fileURLToPath(new URL('./swagger',import.meta.url))}),
    meta=structuredClone(result.metafile),input=Object.keys(meta.inputs).find(file=>file.includes('node_modules/@babel/runtime/'));
  delete meta.inputs[input];await assert.rejects(swaggerRedistribution(meta),/identity or compiled closure/);
  await assert.rejects(swaggerRedistribution({inputs:{'tools/probes/m2/node_modules/swagger-ui/dist/index.js':{}},outputs:{}}),/outside its locked asset tree/);
  const changed=structuredClone(result.metafile),output=Object.values(changed.outputs).find(record=>record.inputs[input]);
  output.inputs[input].bytesInOutput++;await assert.rejects(swaggerRedistribution(changed),/identity or compiled closure/);
});
for(const preset of ['redoc','swagger']) {
test(`${preset} repeated installed asset preparation is deterministic and cannot replace unrelated files or symlinks`,async()=>{
  const temp=await mkdtemp(path.join(tmpdir(),'busyapi-documentation-assets-'));
  try{
    const destination=path.join(temp,'assets'),first=await prepareDocumentationAssets(destination,preset);
    const capture=async()=>Object.fromEntries(await Promise.all((await readdir(destination)).sort().map(async name=>[name,hash(await readFile(path.join(destination,name)))])));
    const before=await capture(),second=await prepareDocumentationAssets(destination,preset);
    assert.deepEqual(first,second);assert.deepEqual(await capture(),before);
    await writeFile(path.join(destination,'source.yaml'),'do not overwrite',{flag:'wx'});
    await assert.rejects(prepareDocumentationAssets(destination,preset),/unowned entries/);
    assert.equal(await readFile(path.join(destination,'source.yaml'),'utf8'),'do not overwrite');
    const foreign=path.join(temp,'foreign');await writeFile(foreign,'external source',{flag:'wx'});
    const links=path.join(temp,'links');await symlink(destination,links);
    await assert.rejects(prepareDocumentationAssets(links,preset),/unowned entries|symlink/);
    assert.equal(await readFile(foreign,'utf8'),'external source');
  }finally{await rm(temp,{recursive:true,force:true});}
});
}
