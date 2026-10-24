// Offline build input preparation, not a runtime package loader.
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {readFile} from 'node:fs/promises';
import {redocRedistribution} from './asset_licenses.mjs';
import {redocAdapterIdentity} from './redoc_adapter.mjs';
import {swaggerRedistribution} from './swagger_licenses.mjs';
import {swaggerAdapterIdentity} from './swagger_adapter.mjs';
import {compileSwaggerModule} from './swagger_module_build.mjs';

async function assembled(preset,adapter,runtimeResources,files,notices) {
  const digests=Object.fromEntries(Object.keys(files).sort().map(name=>[name,createHash('sha256').update(files[name]).digest('hex')]));
  const identity=createHash('sha256').update(JSON.stringify({adapter,files:digests})).digest('hex');
  const manifest={version:1,producer:'busyapi-documentation-assets',producerVersion:'1',preset,adapter,
    identity,files:digests,runtimeResources,notices};
  return Object.freeze({manifest,files:Object.freeze({...files,'assets.json':Buffer.from(JSON.stringify(manifest,null,2)+'\n')})});
}

export async function buildRedocAssets() {
  if(process.version!=='v24.15.0')throw Error('Use the pinned Node 24.15.0 build runtime');
  const engine=createRequire(new URL('../contract_engine/package.json',import.meta.url)),{build}=engine('esbuild');
  const result=await build({absWorkingDir:fileURLToPath(new URL('../../',import.meta.url)),entryPoints:[fileURLToPath(new URL('./redoc_entry.mjs',import.meta.url))],bundle:true,write:false,metafile:true,
    format:'iife',globalName:'BusyApiRedoc',platform:'browser',target:'es2022',
    define:{'process.env.NODE_ENV':'"production"'},logLevel:'silent',
    banner:{js:'/* BusyAPI read-only integration; compiled unmodified third-party inputs. See THIRD_PARTY_NOTICES.txt and third-party.json. */'}});
  const notices=await redocRedistribution(result.metafile);
  const files={
    'redoc.js':Buffer.from(result.outputFiles[0].contents),
    'bootstrap.js':await readFile(new URL('./bootstrap.js',import.meta.url)),
    ...notices.files,
  };
  return assembled('redoc',redocAdapterIdentity,['redoc.js','bootstrap.js'],files,['THIRD_PARTY_NOTICES.txt','third-party.json']);
}

export async function buildSwaggerAssets() {
  const result=await compileSwaggerModule({directory:fileURLToPath(new URL('./swagger',import.meta.url))}),
    notices=await swaggerRedistribution(result.metafile),files={
      'swagger.js':Buffer.from(result.outputFiles[0].contents),
      'swagger.css':await readFile(new URL('./swagger/node_modules/swagger-ui/dist/swagger-ui.css',import.meta.url)),
      'bootstrap.js':await readFile(new URL('./bootstrap.js',import.meta.url)),...notices.files,
    };
  return assembled('swagger',swaggerAdapterIdentity,['swagger.js','swagger.css','bootstrap.js'],files,
    ['THIRD_PARTY_NOTICES.txt','third-party.json','swagger-ui-es-bundle-core.js.LICENSE.txt']);
}
