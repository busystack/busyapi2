#!/usr/bin/env node
// Normal offline build/install preparation. Never invoked by opening a project
// or documentation output. Installs no npm packages and deletes no directories.
import {randomBytes,createHash} from 'node:crypto';
import {mkdir,lstat,readdir,readFile,writeFile,rename,unlink} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {buildRedocAssets,buildSwaggerAssets} from './documentation_renderers/build_assets.mjs';

export async function prepareDocumentationAssets(output,preset='redoc') {
  if(!['redoc','swagger'].includes(preset))throw Error('Choose a supported local documentation preset');
  const result=await (preset==='redoc'?buildRedocAssets():buildSwaggerAssets()),files=result.files;
  const target=path.resolve(output);
  if(target===path.parse(target).root)throw Error('Choose a dedicated documentation build directory');
  await mkdir(target,{recursive:true});
  const entries=await readdir(target,{withFileTypes:true});
  if(entries.length){
    if(entries.some(entry=>!entry.isFile()||!Object.hasOwn(files,entry.name)))
      throw Error('The documentation build destination contains unowned entries');
    const previous=JSON.parse(await readFile(path.join(target,'assets.json'),'utf8'));
    if(previous.producer!=='busyapi-documentation-assets'||previous.version!==1||previous.preset!==preset)
      throw Error('The documentation build destination is not owned by BusyAPI');
  }
  if(!(await lstat(target)).isDirectory())throw Error('The documentation build directory cannot be a symlink');
  // Manifest last: interruption cannot disguise mixed asset bytes as complete.
  for(const name of [...Object.keys(files).filter(name=>name!=='assets.json'),'assets.json']){
    const destination=path.join(target,name),bytes=files[name];
    try{
      if(!(await lstat(destination)).isFile())throw Error('A documentation build target is not an ordinary file');
      if(createHash('sha256').update(await readFile(destination)).digest('hex')===createHash('sha256').update(bytes).digest('hex'))continue;
    }catch(error){if(error.code!=='ENOENT')throw error;}
    const temporary=path.join(target,'.busyapi-documentation-'+randomBytes(12).toString('hex')+'.tmp');
    try{await writeFile(temporary,bytes,{flag:'wx',mode:0o644});await rename(temporary,destination);}
    finally{try{await unlink(temporary);}catch(error){if(error.code!=='ENOENT')throw error;}}
  }
  return result.manifest;
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{
    if(![4,6].includes(process.argv.length)||process.argv[2]!=='--output'||process.argv.length===6&&process.argv[4]!=='--preset')throw Error('Usage: node tools/prepare_documentation_assets.mjs --output DEDICATED_DIRECTORY [--preset redoc|swagger]');
    await prepareDocumentationAssets(process.argv[3],process.argv[5]??'redoc');
  }catch(error){
    process.stderr.write('Local documentation assets were not prepared: '+error.message+'\nRun tools/build_documentation_assets.sh to provision both exact documentation locks, then retry the normal build. No runtime download is performed.\n');
    process.exitCode=1;
  }
}
