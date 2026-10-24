"""Focused generator preparation, installed identity and JVM capability tests."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools import prepare_generator as tools


class GeneratorAssets(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='busyapi-generator-assets-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'generator'
        for name, data in {'jre/bin/java': b'fixture java', 'jre/lib/modules': b'fixture modules',
                           'openapi-generator.jar': b'fixture jar', 'generator-launcher': b'fixture launcher'}.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        for name in ['jre/bin/java', 'generator-launcher']:
            (self.root / name).chmod(0o755)
        files = tools.inventory(self.root)
        runtime = {k: v for k, v in files.items() if k.startswith('jre/')}
        lock = {**tools.LOCK, 'jarSha256': files['openapi-generator.jar'],
                'runtimeFilesSha256': hashlib.sha256(json.dumps(runtime, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}
        self.lock = patch.object(tools, 'LOCK', lock)
        self.lock.start()
        self.addCleanup(self.lock.stop)
        receipt = {'version': 1, 'lock': lock, 'launcherSource': tools.digest(tools.ROOT / 'tools/generator/launcher.cc'),
                   'preparation': tools.digest(Path(tools.__file__)),
                   'files': files, 'compiler': 'fixture compiler'}
        (self.root / 'assets.json').write_text(json.dumps(receipt))

    def test_verified_offline_reuse_needs_no_original_archive_or_download(self):
        with patch.object(tools.urllib.request, 'urlopen', side_effect=AssertionError('unexpected download')):
            result = tools.prepare(self.root)
        self.assertEqual(result['files'], tools.inventory(self.root))

    def test_explicit_bad_input_is_not_ignored_for_a_valid_cache(self):
        wrong = Path(self.temporary.name) / 'wrong.jar'
        wrong.write_bytes(b'not the locked jar')
        with self.assertRaisesRegex(RuntimeError, 'Explicit'):
            tools.prepare(self.root, jar=wrong)
        tools.verify(self.root)

    def test_missing_tampered_or_linked_assets_are_rejected(self):
        jar = self.root / 'openapi-generator.jar'
        original = jar.read_bytes()
        for kind in ['missing', 'changed', 'linked']:
            with self.subTest(kind=kind):
                jar.unlink()
                if kind == 'changed':
                    jar.write_bytes(b'altered')
                elif kind == 'linked':
                    jar.symlink_to(self.root / 'jre/bin/java')
                with self.assertRaises((RuntimeError, FileNotFoundError)):
                    tools.verify(self.root)
                jar.unlink(missing_ok=True)
                jar.write_bytes(original)

    def test_jre_cannot_be_reblessed_by_editing_its_installed_receipt(self):
        (self.root / 'jre/lib/modules').write_bytes(b'tampered')
        marker = self.root / 'assets.json'
        receipt = json.loads(marker.read_text())
        receipt['files'] = tools.inventory(self.root)
        marker.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(RuntimeError, 'altered'):
            tools.verify(self.root)

    def test_executable_mode_and_unknown_files_are_checked(self):
        launcher = self.root / 'generator-launcher'
        launcher.chmod(0o644)
        with self.assertRaises(RuntimeError):
            tools.verify(self.root)
        launcher.chmod(0o755)
        (self.root / 'extra-agent.jar').write_bytes(b'foreign')
        with self.assertRaises(RuntimeError):
            tools.verify(self.root)

    def test_changed_launcher_source_rebuilds_only_the_helper_from_verified_inputs(self):
        marker = self.root / 'assets.json'
        receipt = json.loads(marker.read_text())
        receipt['launcherSource'] = 'previous source identity'
        marker.write_text(json.dumps(receipt))
        def rebuild(stage):
            (stage / 'generator-launcher').write_bytes(b'new reviewed helper')
            (stage / 'generator-launcher').chmod(0o755)
            return 'fixture compiler'
        with patch.object(tools, 'build_launcher', side_effect=rebuild) as build:
            tools.prepare(self.root)
        self.assertEqual(build.call_count, 1)
        tools.verify(self.root)


class GeneratorJvmPolicy(unittest.TestCase):
    def test_real_jvm_can_write_stage_but_not_read_secrets_write_outside_or_connect(self):
        runtime = tools.ROOT / 'build/generator'
        tools.verify(runtime)
        javac = shutil.which(os.environ.get('BUSYAPI_GENERATOR_TEST_JAVAC', 'javac'))
        if not javac:
            self.fail('A development javac supporting --release 17 is required for this focused trusted-fixture test')
        with tempfile.TemporaryDirectory(prefix='busyapi-generator-policy-') as folder, socket.socket() as server:
            root = Path(folder)
            stage = root / 'stage'
            stage.mkdir(mode=0o700)
            source = root / 'Probe.java'
            source.write_text('''import java.nio.file.*; import java.net.*; import java.io.*;
public class Probe {
  public static void main(String[] args) throws Exception {
    boolean read = false, write = false, network = false, execute = false;
    try { Files.readString(Path.of(args[0])); } catch (IOException e) { read = true; }
    try { Files.writeString(Path.of(args[1]), "wrong"); } catch (IOException e) { write = true; }
    try (Socket s = new Socket()) { s.connect(new InetSocketAddress("127.0.0.1", Integer.parseInt(args[2])), 250); }
    catch (IOException e) { network = true; }
    try { new ProcessBuilder("/bin/true").start().waitFor(); } catch (IOException e) { execute = true; }
    Files.writeString(Path.of("stage-ok"), "owned bytes");
    System.out.println(read + ":" + write + ":" + network + ":" + execute + ":" + (System.getenv("SYNTHETIC_SECRET") == null));
  }
}''')
            environment = {'PATH': os.defpath, 'LANG': 'C.UTF-8'}
            subprocess.run([javac, '--release', '17', '-proc:none', str(source)], check=True,
                           cwd=root, env=environment, capture_output=True, timeout=20)
            jar = root / 'probe.jar'
            import zipfile
            with zipfile.ZipFile(jar, 'w') as archive:
                archive.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\nMain-Class: Probe\n\n')
                archive.write(root / 'Probe.class', 'Probe.class')
            secret = root / 'synthetic-secret'
            secret.write_bytes(b'synthetic secret must not be read')
            server.bind(('127.0.0.1', 0))
            server.listen()
            server.setblocking(False)
            result = subprocess.run([runtime / 'generator-launcher', runtime / 'jre', jar, stage,
                                     str(secret), str(root / 'outside'), str(server.getsockname()[1])],
                                    env={**environment, 'JAVA_TOOL_OPTIONS': '-javaagent:/missing/agent.jar',
                                         'SYNTHETIC_SECRET': 'must-not-inherit'},
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'true:true:true:true:true')
            self.assertEqual((stage / 'stage-ok').read_bytes(), b'owned bytes')
            self.assertFalse((root / 'outside').exists())
            self.assertEqual(secret.read_bytes(), b'synthetic secret must not be read')
            with self.assertRaises(BlockingIOError):
                server.accept()


if __name__ == '__main__':
    unittest.main()
