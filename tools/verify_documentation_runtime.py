"""Verify the assembled on-demand module and declared full native runtime."""
import json
from pathlib import Path
import re
import subprocess

LIBRARIES = ('libwebkit2gtk-4.1.so.0', 'libjavascriptcoregtk-4.1.so.0')


def needed(path):
    output = subprocess.check_output(['readelf', '-d', str(path)], text=True)
    return set(re.findall(r'\(NEEDED\).*?\[([^\]]+)\]', output))


def verify(bundle):
    bundle = Path(bundle)
    module = bundle / 'lib/libbusyapi_documentation.so'
    descriptor = bundle / 'share/busyapi/documentation-runtime.json'
    for path in (module, descriptor):
        if not path.is_file() or path.is_symlink():
            raise RuntimeError('Missing ordinary documentation runtime asset: ' + str(path.relative_to(bundle)))
    data = json.loads(descriptor.read_text())
    if (data.get('version') != 1 or data.get('moduleAbi') != 1 or
            data.get('module') != 'lib/libbusyapi_documentation.so' or
            data.get('systemRuntime') != 'webkit2gtk-4.1' or data.get('gtkAbi') != 'GTK3' or
            data.get('requiredLibraries') != list(LIBRARIES) or
            not re.fullmatch(r'\d+\.\d+\.\d+', data.get('buildVersion', '')) or
            'helper processes' not in data.get('requiredRuntime', '') or
            'without nested Bubblewrap' not in data.get('requiredRuntime', '')):
        raise RuntimeError('Documentation runtime descriptor does not match the installed module contract')
    if not set(LIBRARIES).issubset(needed(module)):
        raise RuntimeError('Documentation module is not linked to its declared native runtime')
    runner = bundle / 'busyapi-desktop'
    if runner.is_file() and set(LIBRARIES).intersection(needed(runner)):
        raise RuntimeError('The source workspace unexpectedly requires WebKit at startup')
    for path in (bundle / 'lib').glob('*.so*'):
        if any(path.name.startswith(library) for library in LIBRARIES):
            raise RuntimeError('A partial private WebKit runtime must not replace the declared full system installation')
    return data


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    print(json.dumps(verify(parser.parse_args().bundle), indent=2))
