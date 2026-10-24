// Exact build-input review, not a project resolver or an online license scanner.
// Original distributions remain unmodified. Supplemental notices are BusyAPI
// redistribution material, never fabricated upstream LICENSE files.
import {createHash} from 'node:crypto';
import {readFile,readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const directory=fileURLToPath(new URL('.',import.meta.url)),tree=path.join(directory,'swagger'),
  repository=fileURLToPath(new URL('../../',import.meta.url)),hash=bytes=>createHash('sha256').update(bytes).digest('hex'),
  same=(a,b)=>JSON.stringify([...a].sort())===JSON.stringify([...b].sort()),
  allowed=new Set(['MIT','ISC','Apache-2.0','BSD-2-Clause','BSD-3-Clause','0BSD','Unlicense','(MIT AND BSD-3-Clause)']),
  names=/^(licen[cs]e|notice|copyright|copying)([._-].*)?$/i;
const safe=file=>typeof file==='string'&&file.length>0&&!path.isAbsolute(file)&&!file.split('/').some(part=>!part||part==='.'||part==='..');
async function verified(file,digest){
  const bytes=await readFile(file);
  if(hash(bytes)!==digest)throw Error('Swagger dependency input or notice changed: '+path.basename(file));
  return bytes;
}
async function noticeNames(home){
  const result=[];
  for(const entry of await readdir(home,{withFileTypes:true})){
    if(entry.isFile()&&names.test(entry.name))result.push(entry.name);
    if(entry.isDirectory()&&entry.name==='LICENSES'){
      for(const child of await readdir(path.join(home,entry.name),{withFileTypes:true})){
        if(!child.isFile())throw Error('Swagger license material contains an unreviewed directory');
        result.push(entry.name+'/'+child.name);
      }
    }
  }
  return result;
}

export async function swaggerRedistribution(meta){
  const external=JSON.parse(await readFile(new URL('./swagger-inputs.review.json',import.meta.url))),
    embedded=JSON.parse(await readFile(new URL('./swagger-embedded.review.json',import.meta.url))),
    lock=JSON.parse(await readFile(path.join(tree,'package-lock.json')));
  if(external.version!==1||embedded.version!==1||external.packageVersion!=='5.33.2'||embedded.packageVersion!=='5.33.2'||!meta?.inputs||!meta.outputs)
    throw Error('Swagger dependency review is unavailable or unsupported');
  const actual=new Map(),presence=new Map(),parts=[];
  for(const output of Object.values(meta.outputs))for(const [file,record]of Object.entries(output.inputs))
    presence.set(file,(presence.get(file)??0)+record.bytesInOutput);
  for(const file of Object.keys(meta.inputs))if(file.includes('node_modules/')){
    const absolute=path.resolve(repository,file),prefix=path.join(tree,'node_modules')+path.sep;
    if(!absolute.startsWith(prefix))throw Error('Swagger compilation used a dependency outside its locked asset tree');
    const relative=path.relative(tree,absolute).split(path.sep).join('/'),segments=relative.split('/'),
      at=segments.lastIndexOf('node_modules'),location=segments.slice(0,at+(segments[at+1]?.startsWith('@')?3:2)).join('/'),
      name=relative.slice(location.length+1),record=actual.get(location)??{inputs:[],bytes:0};
    if(!safe(name))throw Error('Invalid Swagger compilation input');
    record.inputs.push([name,hash(await readFile(absolute))]);record.bytes+=presence.get(file)??0;actual.set(location,record);
  }
  if(!same(actual.keys(),external.packages.map(record=>record.location)))throw Error('An unreviewed dependency entered or left the Swagger asset');
  const append=(record,file,bytes)=>parts.push(Buffer.from('\n===== '+record.name+' '+record.version+' / '+file+' =====\n\n'),bytes,Buffer.from('\n'));
  const notice=async(record,item)=>{
    if(!safe(item.file)||!['package','reviewed'].includes(item.origin)||
        item.origin==='package'&&!item.file.startsWith(record.location+'/')||
        item.origin==='reviewed'&&!item.file.startsWith('licenses/'))throw Error('Invalid Swagger notice location');
    append(record,item.file,await verified(path.join(item.origin==='package'?tree:directory,item.file),item.sha256));
  };
  for(const record of external.packages){
    const locked=lock.packages?.[record.location],compiled=actual.get(record.location);
    if(!/^node_modules\/(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+$/.test(record.location)||!allowed.has(record.license)||
        !locked||locked.version!==record.version||locked.integrity!==record.integrity||locked.resolved!==record.source||
        compiled.inputs.length!==record.inputCount||hash(JSON.stringify(compiled.inputs.sort(([a],[b])=>a<b?-1:a>b?1:0)))!==record.inputIdentity||
        compiled.bytes!==record.bytesInOutput)throw Error('Swagger dependency identity or compiled closure changed');
    const home=path.join(tree,record.location),metadata=JSON.parse(await verified(path.join(home,'package.json'),record.packageJsonSha256)),
      declared=metadata.license??metadata.licenses?.[0]?.type;
    if(metadata.name!==record.name||metadata.version!==record.version||declared!==record.declaredLicense)
      throw Error('Swagger dependency license declaration conflicts with its review');
    const expected=record.requiredNotices.filter(item=>item.origin==='package').map(item=>item.file.slice(record.location.length+1));
    if(!same(await noticeNames(home),expected))throw Error('Swagger dependency notice set changed');
    if(record.declarationEvidence){
      if(!['format','short-unique-id'].includes(record.name)||!safe(record.declarationEvidence.readme))throw Error('Unreviewed Swagger SPDX supplement');
      await verified(path.join(home,record.declarationEvidence.readme),record.declarationEvidence.readmeSha256);
    }
    for(const item of record.requiredNotices)await notice(record,item);
    for(const source of record.embeddedSources??[]){
      if(!allowed.has(source.license)||!safe(source.sourceFile)||!source.requiredNotices?.length)throw Error('Unreviewed adapted Swagger source');
      await verified(path.join(home,source.sourceFile),source.sourceSha256);
      for(const item of source.requiredNotices)await notice(record,item);
      if(source.copyrightNotice&&!record.requiredNotices.some(item=>item.file===source.copyrightNotice))throw Error('An adapted-source copyright notice is missing');
    }
  }
  const module='node_modules/swagger-ui/dist/swagger-ui-es-bundle-core.js',
    published=await verified(path.join(tree,module),embedded.publishedModuleSha256),
    map=JSON.parse(await verified(path.join(tree,module+'.map'),embedded.sourceMapSha256)),actualEmbedded=new Map();
  await verified(path.join(tree,'node_modules/swagger-ui/dist/swagger-ui.css'),embedded.stylesheetSha256);
  const locked=lock.packages['node_modules/swagger-ui'];
  if(locked.resolved!==embedded.sourceRelease.source||locked.integrity!==embedded.sourceRelease.integrity)throw Error('Swagger published module identity changed');
  for(let index=0;index<map.sources.length;index++){
    const source=map.sources[index],offset=source.indexOf('./node_modules/');if(offset<0)continue;
    const relative=source.slice(offset+15),segments=relative.split('/'),length=segments[0].startsWith('@')?2:1,
      name=segments.slice(0,length).join('/'),file=segments.slice(length).join('/');
    if(!safe(relative)||typeof map.sourcesContent[index]!=='string')throw Error('Invalid embedded Swagger source');
    const inputs=actualEmbedded.get(name)??{};if(Object.hasOwn(inputs,file))throw Error('Duplicate embedded Swagger source identity');
    inputs[file]=hash(map.sourcesContent[index]);actualEmbedded.set(name,inputs);
  }
  if(!same(actualEmbedded.keys(),embedded.packages.map(record=>record.name)))throw Error('Swagger embedded source closure changed');
  for(const record of embedded.packages){
    if(!allowed.has(record.license)||!record.requiredNotices?.length||
        !same(Object.keys(actualEmbedded.get(record.name)),Object.keys(record.sourceMapInputs))||
        Object.entries(record.sourceMapInputs).some(([file,digest])=>actualEmbedded.get(record.name)[file]!==digest))throw Error('Swagger embedded source identity changed');
    for(const item of record.requiredNotices){
      if(!safe(item.file)||!item.file.startsWith('licenses/swagger-embedded/'))throw Error('Invalid embedded Swagger notice');
      append(record,item.originalFile,await verified(path.join(directory,item.file),item.sha256));
    }
  }
  const extracted=embedded.extractedNotices;
  if(!safe(extracted.file)||!extracted.file.startsWith('licenses/swagger-embedded/'))throw Error('Invalid Swagger extracted-notice path');
  const extractedBytes=await verified(path.join(directory,extracted.file),extracted.sha256);
  // Keep the vendor banner's original notice basename available beside JS.
  if(!published.includes(Buffer.from('swagger-ui-es-bundle-core.js.LICENSE.txt')))throw Error('Swagger extracted-notice declaration changed');
  const inventory={version:1,producer:'busyapi-documentation-notices',producerVersion:'1',preset:'swagger',
    upstreamSource:embedded.sourceRelease,upstreamPublishedModuleSha256:embedded.publishedModuleSha256,
    scope:'Exact supported browser-module compilation inputs and verified embedded source-map constituents. Output-omitted inputs are marked separately; no npm tree, development browser, probe or CLI is redistributed.',
    packages:[...external.packages,...embedded.packages]};
  return Object.freeze({inventory,files:Object.freeze({
    'THIRD_PARTY_NOTICES.txt':Buffer.concat([Buffer.from('BusyAPI local Swagger documentation — third-party notices\n\nUpstream packages are unmodified. BusyAPI compiles a read-only integration with separate exact-value and source-attribution controls. Vendor trademarks are not BusyAPI branding. Original notices retain their wording; reviewed declaration supplements are separate BusyAPI material, not upstream file modifications. ApiDOM supplies a family-wide notice/license directory including terms for paths not compiled here; those original materials are retained without asserting that omitted paths are distributed. DOMPurify uses its Apache-2.0 alternative. Contract content retains its own ownership and licensing.\n'),...parts,extractedBytes]),
    'third-party.json':Buffer.from(JSON.stringify(inventory,null,2)+'\n'),
    'swagger-ui-es-bundle-core.js.LICENSE.txt':extractedBytes,
  })});
}
