// Build-only supported browser-module compilation. Explicit immutable build
// inputs are separate from project snapshots and never loaded at runtime.
import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

export async function compileSwaggerModule({directory,format='iife'}={}) {
  if(process.version!=='v24.15.0'||!['iife','esm'].includes(format)||typeof directory!=='string'||!path.isAbsolute(directory))
    throw Error('Select the pinned Node and explicit locked Swagger build tree');
  const expected={'swagger-ui':'5.33.2','swagger-client':'3.38.2',react:'18.3.1','react-dom':'18.3.1'},
    metadata=JSON.parse(await readFile(path.join(directory,'package.json'),'utf8'));
  for(const [name,version]of Object.entries(expected)){
    const installed=JSON.parse(await readFile(path.join(directory,'node_modules',name,'package.json'),'utf8'));
    if(metadata.dependencies?.[name]!==version||installed.name!==name||installed.version!==version||
        name==='swagger-ui'&&installed.exports?.['.']?.browser?.import!=='./dist/swagger-ui-es-bundle-core.js')
      throw Error('Swagger browser-module build inputs changed');
  }
  const engine=createRequire(new URL('../contract_engine/package.json',import.meta.url)),{build}=engine('esbuild');
  return build({absWorkingDir:fileURLToPath(new URL('../../',import.meta.url)),
    entryPoints:[fileURLToPath(new URL('./swagger_module_entry.mjs',import.meta.url))],
    alias:Object.fromEntries(Object.keys(expected).map(name=>[name,path.join(directory,'node_modules',name)])),
    bundle:true,write:false,metafile:true,format,...(format==='iife'?{globalName:'BusyApiSwagger'}:{}),
    platform:'browser',target:'es2022',define:{'process.env.NODE_ENV':'"production"'},logLevel:'silent'});
}
