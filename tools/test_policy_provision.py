"""Controlled transfer boundaries; these tests never contact a server."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools import provision_policy_inputs as provisioning


class PolicyProvision(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='busyapi-policy-provision-test-')
        self.addCleanup(self.temporary.cleanup)
        self.node = Path(self.temporary.name) / 'node'
        self.node.mkdir()
        (self.node / 'node_api.h').write_bytes(b'controlled test declarations')
        self.archive = b'controlled archive fixture; never a distributed component'
        self.record = {'node': {'headers': {'node_api.h': hashlib.sha256((self.node / 'node_api.h').read_bytes()).hexdigest()}},
                       'libseccomp': {'headerPackage': 'https://archive.ubuntu.com/fixture.deb',
                                      'headerPackageSha256': hashlib.sha256(self.archive).hexdigest()}}

    def invoke(self, extra, *, bad=False):
        calls = []
        def run(arguments, **kwargs):
            calls.append((arguments, kwargs))
            if arguments[0] == '/controlled/curl':
                Path(arguments[arguments.index('--output') + 1]).write_bytes(b'incorrect' if bad else self.archive)
            return subprocess.CompletedProcess(arguments, 0)
        with patch('sys.argv', ['provision', '--node-include', str(self.node), *extra]), \
                patch.object(provisioning.json, 'loads', return_value=self.record), \
                patch.object(provisioning.shutil, 'which', return_value='/controlled/curl'), \
                patch.object(provisioning.subprocess, 'run', side_effect=run), \
                patch.object(provisioning, 'prepare') as prepare:
            failure = None
            try:
                provisioning.main()
            except SystemExit as error:
                failure = error.code
            return calls, prepare.call_args, failure

    def test_no_transfer_without_explicit_authority_or_matching_node_declarations(self):
        calls, prepared, failure = self.invoke([])
        self.assertEqual(failure, 2)
        self.assertEqual(calls, [])
        self.assertIsNone(prepared)
        (self.node / 'node_api.h').write_text('changed')
        calls, prepared, failure = self.invoke(['--provision'])
        self.assertEqual((calls, prepared, failure), ([], None, 2))

    def test_exact_transfer_limits_environment_and_verified_archive_precede_extraction(self):
        calls, prepared, failure = self.invoke(['--provision'])
        self.assertIsNone(failure)
        self.assertEqual(len(calls), 2)
        arguments, options = calls[0]
        for option, expected in [('--proto', '=https'), ('--max-redirs', '0'),
                                 ('--max-time', '60'), ('--max-filesize', '2097152')]:
            self.assertEqual(arguments[arguments.index(option) + 1], expected)
        self.assertEqual(arguments[1], '--disable')
        self.assertEqual(options['env'], {})
        self.assertEqual(options['timeout'], 65)
        self.assertEqual(calls[1][0][:2], ['dpkg-deb', '--extract'])
        self.assertEqual(prepared.kwargs['node_include'], self.node)

    def test_changed_archive_cannot_be_extracted_or_cached(self):
        calls, prepared, failure = self.invoke(['--provision'], bad=True)
        self.assertEqual(failure, 1)
        self.assertEqual(len(calls), 1)
        self.assertIsNone(prepared)


if __name__ == '__main__':
    unittest.main()
