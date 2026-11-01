"""Actual offline loader build, installed notices and ordinary all-mode CMake."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import urllib.parse

from tools.verify_resource_package_assets import verify

ROOT=Path(__file__).resolve().parent.parent


class ResourcePackageAssets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        config=ROOT/'.dart_tool/package_config.json'
        packages=json.loads(config.read_bytes())['packages']
        flutter=next(p for p in packages if p['name']=='flutter')
        sdk=Path(urllib.parse.unquote(urllib.parse.urlparse(urllib.parse.urljoin(config.as_uri(),flutter['rootUri'])).path)).parent.parent
        cls.dart=Path(os.environ.get('BUSYAPI_DART',str(sdk/'bin/cache/dart-sdk/bin/dart')))
        cls.bundle=ROOT/'build/test-runtime'
        cls.stage=ROOT/'build/resource-package-runtime'
        cls.contract=cls.bundle/'libexec/busyapi'
        cls.notices=ROOT/'build/dart-notices'

    def prepare(self,output,dart=None):
        return subprocess.run([sys.executable,str(ROOT/'tools/prepare_resource_package_assets.py'),
            '--output',str(output),'--dart',str(dart or self.dart),
            '--contract-runtime',str(self.contract),'--dart-notices',str(self.notices)],
            capture_output=True,text=True,timeout=120)

    def test_actual_installed_inputs_and_notices_are_exact(self):
        record=verify(self.bundle)
        self.assertEqual(record['platform']['system'],'Linux')
        self.assertIn('libc.so.6',record['platform']['requiredSystemLibraries'])
        self.assertTrue(record['platform']['requiredElfSymbolVersions'])
        self.assertNotIn('webkit',json.dumps(record).lower())
        dart=json.loads((self.bundle/'share/licenses/busyapi-dart/dependencies.json').read_bytes())
        self.assertEqual(dart['scope'],'headless-core-production-closure')
        self.assertEqual(dart['sdk'],'3.13.4')
        self.assertFalse(any(p['license'].startswith('GPL') for p in dart['packages']))
        self.assertTrue((self.bundle/'share/licenses/busyapi-engine/NODE-LICENSE').is_file())

    def test_repeated_locked_preparation_is_unchanged_and_requires_no_path_tools_at_runtime(self):
        before=(self.stage/'runtime.json').read_bytes()
        built=(self.stage/'resource-package-loader').stat().st_mtime_ns
        result=self.prepare(self.stage)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.stage/'runtime.json').read_bytes(),before)
        self.assertEqual((self.stage/'resource-package-loader').stat().st_mtime_ns,built)
        result=subprocess.run([str(self.stage/'resource-package-loader'),'--help'],
            env={'PATH':''},cwd='/tmp',capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('no network retrieval',result.stdout)

    def test_missing_and_changed_original_notice_is_not_a_valid_installed_runtime(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-package-assets-denied-') as temporary:
            target=Path(temporary)
            # Copy only the descriptor: missing code/notices must not be waived.
            destination=target/'share/busyapi/resource-package/runtime.json'
            destination.parent.mkdir(parents=True)
            destination.write_bytes((self.stage/'runtime.json').read_bytes())
            with self.assertRaisesRegex(RuntimeError,'Missing package runtime input'):
                verify(target)

            # An actual installed notice is checked, not only its inventory.
            value=json.loads(destination.read_bytes())
            first='share/licenses/busyapi-engine/NODE-LICENSE'
            value['files']={first:'0'*64}
            # Required-file rejection is still mandatory even if a forged map
            # has a matching self digest. No substitute license is accepted.
            from hashlib import sha256
            value.pop('identity')
            value['identity']=sha256(json.dumps(value,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
            destination.write_text(json.dumps(value,separators=(',',':'),ensure_ascii=False)+'\n')
            with self.assertRaisesRegex(RuntimeError,'Missing package loader'):
                verify(target)
            value=json.loads((self.stage/'runtime.json').read_bytes())
            value['files']={first:value['files'][first],**{k:v for k,v in value['files'].items() if k!=first}}
            value.pop('identity')
            value['identity']=sha256(json.dumps(value,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
            destination.write_text(json.dumps(value,separators=(',',':'),ensure_ascii=False)+'\n')
            notice=target/first;notice.parent.mkdir(parents=True)
            notice.write_bytes(b'changed original notice\n')
            with self.assertRaisesRegex(RuntimeError,'Changed package runtime input: '+first):
                verify(target)

    def test_independently_compiled_loader_and_descriptor_are_byte_equivalent(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-package-rebuild-') as temporary:
            result=self.prepare(Path(temporary))
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((Path(temporary)/'resource-package-loader').read_bytes(),(self.stage/'resource-package-loader').read_bytes())
            self.assertEqual((Path(temporary)/'runtime.json').read_bytes(),(self.stage/'runtime.json').read_bytes())

    def test_genuine_cmake_build_and_install_uses_the_same_assets_in_all_modes(self):
        with tempfile.TemporaryDirectory(prefix='busyapi-package-cmake-') as temporary:
            directory=Path(temporary)
            source=directory/'source';source.mkdir()
            (source/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.13)
project(resource_package NONE)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(BUSYAPI_SOURCE_DIR "{ROOT}")
set(BUSYAPI_NOTICE_DART "{self.dart}")
set(BUSYAPI_DART_NOTICES "{self.notices}")
set(BUSYAPI_CONTRACT_ASSETS "{self.contract}")
set(BUSYAPI_RESOURCE_PACKAGE_ASSETS "{self.stage}" CACHE PATH "")
set(BINARY_NAME app)
add_custom_target(app)
add_custom_target(busyapi_contract_assets)
add_custom_target(busyapi_dart_notices)
include("{ROOT}/linux/resource_package_assets.cmake")
''')
            for mode in ('Debug','Profile','Release'):
                build=directory/mode
                subprocess.run(['cmake','-G','Ninja','-S',str(source),'-B',str(build),'-DCMAKE_BUILD_TYPE='+mode],capture_output=True,check=True,timeout=30)
                subprocess.run(['cmake','--build',str(build)],capture_output=True,check=True,timeout=120)
                target=directory/('installed '+mode+' 雪')
                subprocess.run(['cmake','--install',str(build),'--prefix',str(target)],capture_output=True,check=True,timeout=30)
                self.assertEqual((target/'share/busyapi/resource-package/runtime.json').read_bytes(),(self.stage/'runtime.json').read_bytes())
                self.assertEqual((target/'libexec/busyapi/resource-package-loader').read_bytes(),(self.stage/'resource-package-loader').read_bytes())
                self.assertEqual((target/'libexec/busyapi/resource-package-loader').stat().st_mode&0o777,0o755)
                self.assertFalse(any(p.is_symlink() for p in target.rglob('*')))


if __name__=='__main__':
    unittest.main()
