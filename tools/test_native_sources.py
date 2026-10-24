"""Source companions retain original bytes and are not licensing verdicts."""
import hashlib
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from tools.native_sources import assemble, declaration


def sha(data):
    return hashlib.sha256(data).hexdigest()


class NativeSourceCompanion(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='busyapi-native-source-test-')
        self.root = Path(self.temporary.name)
        self.bundle, self.cache = self.root / 'app', self.root / 'cache'
        self.cache.mkdir()
        library = self.bundle / 'lib/libfixture.so.1'
        library.parent.mkdir(parents=True)
        library.write_bytes(b'Exact copied library fixture')
        self.inventory = self.bundle / 'share/licenses/busyapi-native/dependencies.json'
        self.inventory.parent.mkdir(parents=True)
        self.record = {'version': 1, 'scope': 'busyapi-linux-native-distribution', 'inventoryStage': 'assembled',
                       'libraries': [{'file': 'lib/libfixture.so.1', 'sha256': sha(library.read_bytes()), 'package': 'libfixture1:amd64'}],
                       'packages': [{'name': 'libfixture1:amd64', 'version': '1.0-2', 'sourcePackage': 'fixture', 'sourceVersion': '1.0-2'}]}
        self.inventory.write_text(json.dumps(self.record))
        archive = b'Original source archive bytes: not unpacked or executed\x00\xff'
        name = 'fixture_1.0.orig.tar.xz'
        (self.cache / name).write_bytes(archive)
        self.dsc = ('-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n'
                    'Format: 3.0 (quilt)\nSource: fixture\nVersion: 1.0-2\nChecksums-Sha256:\n '
                    + sha(archive) + ' ' + str(len(archive)) + ' ' + name + '\n'
                    '-----BEGIN PGP SIGNATURE-----\nRetained test signature, not authenticated\n-----END PGP SIGNATURE-----\n').encode()
        (self.cache / 'fixture_1.0-2.dsc').write_bytes(self.dsc)
        self.index = self.root / 'source-index.json'
        self.source = {'package': 'fixture', 'version': '1.0-2',
                       'declaration': {'url': 'https://archive.invalid/fixture_1.0-2.dsc', 'bytes': len(self.dsc), 'sha256': sha(self.dsc)},
                       'files': [{'file': name, 'url': 'https://archive.invalid/' + name, 'bytes': len(archive), 'sha256': sha(archive)}]}
        self.write_index()
        self.output = self.root / 'sources.tar'

    def tearDown(self):
        self.temporary.cleanup()

    def write_index(self):
        self.index.write_text(json.dumps({'sources': [self.source]}))

    def run_assemble(self):
        return assemble(self.bundle, self.cache, self.index, self.output)

    def test_original_materials_deterministic_headers_scope_and_exact_bytes(self):
        record = self.run_assemble()
        self.assertFalse(record['licenceReviewComplete'])
        self.assertEqual(record['upstreamSignatureVerification'], 'not-performed')
        self.assertEqual(record['nativeInventorySha256'], sha(self.inventory.read_bytes()))
        with tarfile.open(self.output) as archive:
            self.assertEqual(json.load(archive.extractfile('sources.json')), record)
            for member in archive.getmembers():
                self.assertEqual((member.mtime, member.mode, member.uid, member.gid, member.uname, member.gname), (0, 0o644, 0, 0, '', ''))
                self.assertTrue(member.isfile())
            self.assertEqual(archive.extractfile('archives/fixture_1.0-2.dsc').read(), self.dsc)
            self.assertEqual(archive.extractfile('archives/fixture_1.0.orig.tar.xz').read(), (self.cache / 'fixture_1.0.orig.tar.xz').read_bytes())
            readme = archive.extractfile('README.txt').read().decode()
            self.assertIn('not a written future source offer', readme)
            self.assertIn('dpkg-source -x', readme)
            self.assertIn('No BusyAPI-supplied condition restricts', readme)
        second = self.root / 'space 雪 companion.tar'
        self.assertEqual(assemble(self.bundle, self.cache, self.index, second), record)
        self.assertEqual(self.output.read_bytes(), second.read_bytes())
        self.assertNotIn(str(self.root), self.output.read_bytes().decode(errors='ignore'))

    def test_existing_file_or_directory_and_parent_symlink_are_refused(self):
        for directory in (False, True):
            with self.subTest(directory=directory):
                target = self.root / ('existing-' + str(directory))
                target.mkdir() if directory else target.write_bytes(b'Keep previous output')
                with self.assertRaisesRegex(RuntimeError, 'destination exists'):
                    assemble(self.bundle, self.cache, self.index, target)
                if not directory:
                    self.assertEqual(target.read_bytes(), b'Keep previous output')
        (self.root / 'linked').symlink_to(self.cache, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            assemble(self.bundle, self.cache, self.index, self.root / 'linked/new.tar')

    def test_source_version_mismatch_and_unrelated_scope_are_refused(self):
        self.source['version'] = '1.0-3'
        self.write_index()
        with self.assertRaisesRegex(RuntimeError, 'source package identity'):
            self.run_assemble()
        self.source['version'] = '1.0-2'
        self.source['package'] = 'another-package'
        self.write_index()
        with self.assertRaisesRegex(RuntimeError, 'source package identity'):
            self.run_assemble()
        self.assertFalse(self.output.exists())

    def test_declaration_and_archive_tampering_do_not_publish_an_output(self):
        (self.cache / 'fixture_1.0-2.dsc').write_bytes(self.dsc + b'Changed')
        with self.assertRaisesRegex(RuntimeError, 'declaration changed'):
            self.run_assemble()
        (self.cache / 'fixture_1.0-2.dsc').write_bytes(self.dsc)
        source = self.cache / 'fixture_1.0.orig.tar.xz'
        source.write_bytes(b'X' * source.stat().st_size)
        with self.assertRaisesRegex(RuntimeError, 'bytes changed'):
            self.run_assemble()
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob('.busyapi-native-sources-*')), [])

    def test_index_cannot_replace_original_declaration_checksums(self):
        archive = self.source['files'][0]
        archive['sha256'] = '0' * 64
        self.write_index()
        with self.assertRaisesRegex(RuntimeError, 'differ from the original declaration'):
            self.run_assemble()
        archive['file'] = '../outside'
        archive['url'] = 'https://archive.invalid/%2E%2E%2Foutside'
        self.write_index()
        with self.assertRaisesRegex(RuntimeError, 'source URL'):
            self.run_assemble()

    def test_linked_inputs_and_changed_assembled_library_are_refused(self):
        source = self.cache / 'fixture_1.0.orig.tar.xz'
        saved = self.root / 'saved-source'
        source.rename(saved)
        source.symlink_to(saved)
        with self.assertRaisesRegex(RuntimeError, 'linked'):
            self.run_assemble()
        source.unlink()
        saved.rename(source)
        (self.bundle / 'lib/libfixture.so.1').write_bytes(b'Changed assembly')
        with self.assertRaisesRegex(RuntimeError, 'library changed'):
            self.run_assemble()
        self.assertFalse(self.output.exists())

    def test_atomic_destination_race_preserves_the_competing_file(self):
        original = __import__('os').link
        def race(source, destination):
            Path(destination).write_bytes(b'Competing output')
            return original(source, destination)
        with patch('tools.native_sources.os.link', side_effect=race):
            with self.assertRaises(FileExistsError):
                self.run_assemble()
        self.assertEqual(self.output.read_bytes(), b'Competing output')
        self.assertEqual(list(self.root.glob('.busyapi-native-sources-*')), [])

    def test_assembly_change_during_source_capture_rejects_publication(self):
        original = tarfile.TarFile.addfile
        def change(archive, info, stream=None):
            original(archive, info, stream)
            if info.name.endswith('.tar.xz'):
                self.inventory.write_bytes(self.inventory.read_bytes() + b'\n')
        with patch.object(tarfile.TarFile, 'addfile', new=change):
            with self.assertRaisesRegex(RuntimeError, 'inventory changed before publication'):
                self.run_assemble()
        self.assertFalse(self.output.exists())

    def test_duplicate_json_keys_and_linked_inventory_ancestors_are_rejected(self):
        self.index.write_text('{"sources":[],"sources":[]}')
        with self.assertRaisesRegex(RuntimeError, 'Duplicate'):
            self.run_assemble()
        self.write_index()
        old = self.inventory.parent
        saved = self.root / 'saved-inventory'
        old.rename(saved)
        old.symlink_to(saved, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            self.run_assemble()

    def test_malformed_duplicate_and_empty_source_declarations_are_not_success(self):
        for data in (b'Source: fixture\nVersion: 1\n',
                     b'Source: fixture\nSource: other\nVersion: 1\nChecksums-Sha256: \n',
                     b'Source: fixture\nVersion: 1\nChecksums-Sha256: \n',
                     b'Source: fixture\nVersion: 1\nChecksums-Sha256:\n ' + b'0' * 64 + b' 1 ../source\n',
                     b'-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\nSource: fixture\n'):
            with self.subTest(data=data):
                with self.assertRaises(RuntimeError):
                    declaration(data)


if __name__ == '__main__':
    unittest.main()
