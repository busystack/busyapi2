import {lstat,readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {SourceError} from './document';

/** Trusted installed assets only. This is not project resource acquisition. */
export async function policyRuntime() {
    const files:Record<string,string>={};let receipt:any;
    for(const name of ['policy-worker.cjs','policy-isolation.node','policy-launcher','policy-build.json']) {
        try {
            const file=join(__dirname,name),before=await lstat(file);
            if(!before.isFile()||before.isSymbolicLink()||before.size>16*1024*1024)throw Error();
            const bytes=await readFile(file),after=await lstat(file);
            if(before.ino!==after.ino||before.dev!==after.dev||before.mtimeMs!==after.mtimeMs||bytes.length!==before.size)throw Error();
            files[name]=createHash('sha256').update(bytes).digest('hex');
            if(name==='policy-build.json')receipt=JSON.parse(bytes.toString('utf8'));
        } catch {throw new SourceError('policy.assets','Required isolated governance assets are missing or changed; prepare the locked contract assets');}
    }
    if(process.versions.node!=='24.15.0'||receipt?.version!==1||receipt.profile!==2||receipt.minimumLandlockAbi!==3||
        receipt.nativeDependency?.soname!=='libseccomp.so.2'||receipt.nativeDependency?.minimumRuntimeVersion!=='2.5.5'||
        ['policy-isolation.node','policy-launcher'].some(name=>receipt.files?.[name]!==files[name]))
        throw new SourceError('policy.assets.provenance','Isolated governance assets do not match their build receipt');
    const profile={version:1,profile:'busyapi-node-captured-v1',node:process.versions.node,
        minimumLandlockAbi:3,nativeProfile:2,libseccomp:'>=2.5.5',files};
    return {...profile,identity:createHash('sha256').update(JSON.stringify(profile)).digest('hex')};
}
