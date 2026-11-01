"""Verify the installed, self-contained headless resource-package exporter inputs."""
import hashlib
import json
from pathlib import Path


def verify(bundle):
    bundle=Path(bundle).resolve()
    manifest=bundle/'share/busyapi/resource-package/runtime.json'
    if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_size>1024*1024:
        raise RuntimeError('Missing ordinary resource-package runtime descriptor')
    record=json.loads(manifest.read_bytes())
    content=dict(record)
    identity=content.pop('identity',None)
    if (record.get('version')!=1 or record.get('producer')!='busyapi-resource-package-runtime'
            or record.get('producerVersion')!='1' or record.get('sdk')!='3.13.4'
            or record.get('node')!='24.15.0' or not isinstance(record.get('files'),dict)
            or len(record['files'])>1024 or identity!=hashlib.sha256(json.dumps(content,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()):
        raise RuntimeError('Invalid resource-package runtime identity')
    required={'libexec/busyapi/resource-package-loader','libexec/busyapi/node','libexec/busyapi/engine.cjs',
              'share/licenses/busyapi-engine/NODE-LICENSE','share/licenses/busyapi-dart/DART-LICENSE',
              'share/licenses/busyapi-engine/dependencies.json','share/licenses/busyapi-dart/dependencies.json'}
    if not required<=record['files'].keys():
        raise RuntimeError('Missing package loader or original redistributed-component notices')
    for name,digest in record['files'].items():
        parts=Path(name).parts
        if Path(name).is_absolute() or not parts or any(part in ('.','..') for part in parts):
            raise RuntimeError('Invalid package runtime input path')
        at=bundle
        for part in parts:
            at=at/part
            if at.is_symlink():
                raise RuntimeError('Package runtime cannot use build-stage symlinks')
        if not at.is_file():
            raise RuntimeError('Missing package runtime input: '+name)
        with at.open('rb') as stream:
            if hashlib.file_digest(stream,'sha256').hexdigest()!=digest:
                raise RuntimeError('Changed package runtime input: '+name)
    # Inspect actual installed inventory contents and every original notice,
    # not just the outer descriptor's self digest or SDK root BSD licence.
    core=json.loads((bundle/'share/licenses/busyapi-dart/dependencies.json').read_bytes())
    runtime=core.get('runtime',{})
    reviewed_bytes=(Path(__file__).resolve().parent/'dart_runtime.review.json').read_bytes()
    reviewed=json.loads(reviewed_bytes)
    reviewed['reviewSha256']=hashlib.sha256(reviewed_bytes).hexdigest()
    prefix='share/licenses/busyapi-dart/runtime/'
    index=prefix+'dependencies.json'
    if (runtime!=reviewed or runtime.get('sdkRevision')!=record.get('sdkRevision')
            or runtime.get('aotRuntimeSha256')!=record.get('aotRuntimeSha256')
            or record['files'].get('share/licenses/busyapi-dart/DART-LICENSE')!=runtime.get('sdkLicenseSha256')
            or not isinstance(runtime.get('components'),list) or not runtime['components']
            or index not in record['files']
            or json.loads((bundle/index).read_bytes())!=runtime):
        raise RuntimeError('Missing or mismatched embedded Dart runtime notice inventory')
    for component in runtime['components']:
        for notice in component['notices']:
            name=notice['file']
            if Path(name).name!=name or name in ('.','..') or record['files'].get(prefix+name)!=notice['sha256']:
                raise RuntimeError('Missing original embedded Dart runtime notice: '+name)
    return record


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle',type=Path)
    args=parser.parse_args()
    verify(args.bundle)
    print('Verified exact installed resource-package loader, runtime and original notices')
