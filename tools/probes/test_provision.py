import hashlib, pathlib, tempfile, unittest
from verify_oasdiff import verify, ENTRY

class Checksums(unittest.TestCase):
    def test_exact_renamed_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory)/'oasdiff.tar.gz'
            archive.write_bytes(b'trusted fixture archive')
            checksums = pathlib.Path(directory)/'checksums.txt'
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            checksums.write_text(digest+'  '+ENTRY+'\n'+'0'*64+'  unrelated.tar.gz\n')
            verify(archive,checksums)
            for contents in ('0'*64+'  '+ENTRY+'\n', digest+'  unrelated.tar.gz\n', (digest+'  '+ENTRY+'\n')*2):
                checksums.write_text(contents)
                with self.assertRaises(ValueError): verify(archive,checksums)

if __name__ == '__main__': unittest.main()
