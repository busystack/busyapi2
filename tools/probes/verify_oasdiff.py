"""Verify the exact pinned release entry despite the locally renamed archive."""
import hashlib, pathlib, re, sys

ENTRY = 'oasdiff_1.33.0_linux_amd64.tar.gz'

def verify(archive, checksums):
    matches = []
    for line in pathlib.Path(checksums).read_text().splitlines():
        match = re.fullmatch(r'([0-9a-fA-F]{64})\s+\*?(.+)', line)
        if match and match[2] == ENTRY:
            matches.append(match[1].lower())
    if len(matches) != 1:
        raise ValueError('Expected exactly one checksum for ' + ENTRY)
    actual = hashlib.sha256(pathlib.Path(archive).read_bytes()).hexdigest()
    if matches[0] != actual:
        raise ValueError('oasdiff release archive checksum mismatch')

if __name__ == '__main__':
    verify(sys.argv[1], sys.argv[2])
