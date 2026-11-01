// Build-time exact-distribution checks. No project resource/code loading,
// registry access or inference from a package family's repository license.
import {createHash} from 'node:crypto';
import {readFile,readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {declaredMitNotice} from './license_declarations.mjs';

const directory=fileURLToPath(new URL('.',import.meta.url));
const repository=fileURLToPath(new URL('../../',import.meta.url));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const same=(a,b)=>JSON.stringify([...a].sort())===JSON.stringify([...b].sort());
const noticesPattern=/^(licen[cs]e|notice|copyright|copying)([._-].*)?$/i;
async function verified(file,expected) {
  const bytes=await readFile(file);
  if(hash(bytes)!==expected)throw Error('Documentation dependency input or notice changed: '+path.basename(file));
  return bytes;
}
function packageLocation(file) {
  const prefix=path.join(directory,'node_modules')+path.sep;
  const absolute=path.resolve(repository,file);
  if(!absolute.startsWith(prefix))throw Error('Documentation compilation used a dependency outside its locked asset tree');
  const relative=path.relative(directory,absolute).split(path.sep).join('/'),parts=relative.split('/'),index=parts.lastIndexOf('node_modules');
  return {relative,location:parts.slice(0,index+(parts[index+1]?.startsWith('@')?3:2)).join('/')};
}

export async function redocRedistribution(meta) {
  const external=JSON.parse(await readFile(new URL('./redoc-inputs.review.json',import.meta.url))),
    embedded=JSON.parse(await readFile(new URL('./redoc-embedded.review.json',import.meta.url))),
    lock=JSON.parse(await readFile(new URL('./package-lock.json',import.meta.url)));
  if(external.version!==1||embedded.version!==1||external.packageVersion!=='3.0.1'||embedded.packageVersion!=='3.0.1'||
      !Array.isArray(external.packages)||!Array.isArray(embedded.packages)||!meta?.inputs)
    throw Error('Documentation dependency review is unavailable or unsupported');
  const actual=new Map(),records=[],parts=[];
  for(const file of Object.keys(meta.inputs))if(file.includes('node_modules/')){
    const at=packageLocation(file),files=actual.get(at.location)??[];
    files.push(at.relative.slice(at.location.length+1));actual.set(at.location,files);
  }
  if(!same(actual.keys(),external.packages.map(record=>record.location)))
    throw Error('An unreviewed dependency entered or left the documentation asset');
  const append=(name,version,notice,bytes)=>{
    parts.push(Buffer.from('\n===== '+name+' '+version+' / '+notice+' =====\n\n'),bytes,Buffer.from('\n'));
  };
  const embeddedNotices=async record=>{
    for(const source of record.embeddedSources??[]){
      if(source.license!=='MIT'||!source.requiredNotices?.length)throw Error('An adapted source needs explicit license review');
      for(const notice of source.requiredNotices){
        if(!/^licenses\/[A-Za-z0-9._-]+\.txt$/.test(notice.file))throw Error('Invalid adapted-source notice location');
        const bytes=await verified(path.join(directory,notice.file),notice.sha256);
        if(source.declaration&&!bytes.toString('utf8').includes(source.declaration))throw Error('An embedded-source notice omitted its original declaration');
        append(source.name,source.version,notice.file,bytes);
      }
    }
  };
  for(const record of external.packages){
    const at=record.location,locked=lock.packages?.[at];
    if(!/^node_modules\/(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+$/.test(at)||record.license!=='MIT'||
        !locked||locked.version!==record.version||locked.integrity!==record.integrity||locked.resolved!==record.source||
        !same(actual.get(at),Object.keys(record.inputs)))
      throw Error('Documentation dependency identity or compiled closure changed');
    const home=path.join(directory,at),metadata=JSON.parse(await verified(path.join(home,'package.json'),record.packageJsonSha256));
    if(metadata.name!==record.name||metadata.version!==record.version||metadata.license!==record.license)
      throw Error('Documentation dependency license declaration conflicts with its review');
    for(const [file,digest]of Object.entries(record.inputs)){
      if(!file||file.split('/').some(part=>!part||part==='.'||part==='..'))throw Error('Invalid dependency input location');
      await verified(path.join(home,file),digest);
    }
    const names=(await readdir(home,{withFileTypes:true})).filter(entry=>entry.isFile()&&noticesPattern.test(entry.name)).map(entry=>entry.name);
    if(!same(names,record.requiredNotices.map(notice=>notice.file)))throw Error('Documentation dependency notice set changed');
    for(const notice of record.requiredNotices)append(record.name,record.version,notice.file,await verified(path.join(home,notice.file),notice.sha256));
    await embeddedNotices(record);
    records.push(record);
  }
  const redoc=external.packages.find(record=>record.name==='redoc');
  const published=await verified(path.join(directory,redoc.location,'bundles/redoc.js'),embedded.publishedBundleSha256);
  for(const record of embedded.packages){
    if(!['MIT','Apache-2.0','BSD-2-Clause'].includes(record.license)||!record.requiredNotices?.length)
      throw Error('An embedded documentation distribution needs license review');
    let declarationEvidence;
    for(const notice of record.requiredNotices){
      if(notice.declaration){
        if(record.name!=='@redocly/redoc-opentelemetry'||record.version!=='0.5.1'||notice.key!==record.name+'@'+record.version)
          throw Error('An unreviewed published SPDX supplement was requested');
        const home=path.join(directory,'node_modules',record.name);
        const declared=await declaredMitNotice(await readFile(path.join(home,'package.json')),await readFile(path.join(home,'LICENSE')));
        declarationEvidence=declared.record;
        for(const file of declared.files)append(record.name,record.version,file.name,file.bytes);
      }else{
        if(!/^licenses\/redoc-embedded\/[A-Za-z0-9._-]+\.txt$/.test(notice.file))throw Error('Invalid embedded notice location');
        append(record.name,record.version,notice.originalFile,await verified(path.join(directory,notice.file),notice.sha256));
      }
    }
    for(const source of record.embeddedSources??[])if(source.declaration&&!published.toString('utf8').includes(source.declaration))
      throw Error('The reviewed embedded-source declaration is absent from the published input');
    await embeddedNotices(record);
    records.push({...record,...(declarationEvidence?{declarationEvidence}:{})});
  }
  const inventory={version:1,producer:'busyapi-documentation-notices',producerVersion:'1',preset:'redoc',
    upstreamSource:embedded.sourceRelease,upstreamPublishedBundleSha256:embedded.publishedBundleSha256,
    upstreamSupplierInventorySha256:embedded.supplierInventorySha256,upstreamSourceLockSha256:embedded.sourceLockSha256,
    scope:'Exact compiled external input closure and verified published Redoc bundle constituents. No development browser, probe harness or CLI is redistributed.',
    packages:records};
  const heading=Buffer.from('BusyAPI local Redoc documentation — third-party notices\n\nUpstream packages are unmodified. BusyAPI compiles a read-only integration with separate source attribution and exact-value display controls. No vendor trademarks are BusyAPI branding. Original notices below retain their wording; embedded notice copies use LF line endings and a final newline. MIT permission/disclaimer, BSD conditions and Apache terms/applicable notices accompany the code in the application and standalone documentation. Contract content retains its own ownership and licensing.\n');
  return Object.freeze({inventory,files:Object.freeze({
    'THIRD_PARTY_NOTICES.txt':Buffer.concat([heading,...parts]),
    'third-party.json':Buffer.from(JSON.stringify(inventory,null,2)+'\n'),
  })});
}
