// Build-time notice supplement for explicitly reviewed published SPDX grants.
// Not a dependency scanner, legal inference engine or runtime resource reader.
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';

const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
export async function declaredMitNotice(packageJson,copyright,{archive}={}) {
  const review=JSON.parse(await readFile(new URL('./license_declarations.json',import.meta.url),'utf8'));
  const metadata=JSON.parse(Buffer.from(packageJson).toString('utf8'));
  const record=review.packages?.[metadata.name+'@'+metadata.version];
  if(review.version!==1||!record||record.license!=='MIT'||metadata.license!=='MIT'||
     hash(packageJson)!==record.packageJsonSha256||hash(copyright)!==record.copyrightSha256)
    throw Error('The published license declaration or original copyright needs review');
  if(archive&&(hash(archive)!==record.archiveSha256||
     'sha512-'+createHash('sha512').update(archive).digest('base64')!==record.integrity))
    throw Error('The reviewed published distribution integrity changed');
  const text=await readFile(new URL(record.supplement,import.meta.url));
  if(hash(text)!==record.supplementSha256||!text.toString('utf8').includes(Buffer.from(copyright).toString('utf8').trim()))
    throw Error('The redistribution notice changed or omitted the original copyright');
  const name=record.supplement.split('/').at(-1);
  if(!/^[a-zA-Z0-9._-]+$/.test(name)||!/^[a-zA-Z0-9._-]+$/.test(record.copyrightFile))
    throw Error('Redistribution notice filenames must be flat');
  return {record,files:[
    {name:record.copyrightFile,bytes:Buffer.from(copyright)},
    {name,bytes:text},
  ]};
}
