"""Read an independently pinned upstream archive without installing its contents."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import stat
from urllib.parse import urlsplit
import zipfile


def _sha256(value):
    if not isinstance(value, str) or re.fullmatch(r'[a-f0-9]{64}', value) is None:
        raise ValueError('Upstream artifact identity must be a pinned SHA-256 digest')
    return value


def _state(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def member_identity(artifact, archive_root=None):
    """Use a reviewed member pin or derive it from the authenticated archive.

    A selected SDK file and its receipt are never sources of this identity.
    Missing original archives cannot become successful provenance checks.
    """
    archive_sha256 = _sha256(artifact.get('sha256'))
    member = artifact.get('member')
    if not isinstance(member, str) or not member or PurePosixPath(member).is_absolute() or '..' in PurePosixPath(member).parts:
        raise ValueError('Invalid upstream archive member')
    pinned = artifact.get('memberSha256')
    if pinned is not None:
        return _sha256(pinned)
    if archive_root is None:
        raise ValueError('Original upstream archives or independently established member identities are required')
    root = Path(archive_root).resolve(strict=True)
    url = urlsplit(artifact['url'])
    if url.scheme != 'https' or url.netloc != 'storage.googleapis.com':
        raise ValueError('Expected the pinned official upstream artifact origin')
    relative = PurePosixPath(url.path).relative_to('/flutter_infra_release')
    names = [relative, PurePosixPath(*relative.parts[-2:])]
    if relative.name == 'dart-sdk-linux-x64.zip':
        names.append(PurePosixPath(relative.name))
    candidates = list(dict.fromkeys(root / name for name in names))
    present = [path for path in candidates if path.exists() or path.is_symlink()]
    if not present:
        raise ValueError('Missing original upstream archive: ' + relative.as_posix())
    path = present[0]
    if path.is_symlink() or not path.parent.resolve(strict=True).is_relative_to(root):
        raise ValueError('Linked or escaped original upstream archive')
    initial = path.lstat()
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(descriptor, 'rb') as source:
        before = os.fstat(source.fileno())
        if _state(initial) != _state(before) or not stat.S_ISREG(initial.st_mode):
            raise ValueError('Original upstream archive changed before authentication')
        if not stat.S_ISREG(before.st_mode) or before.st_size != artifact.get('size') or before.st_size > 512 * 1024 * 1024:
            raise ValueError('Original upstream archive size or file type differs from the pin')
        digest = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
        if digest.hexdigest() != archive_sha256:
            raise ValueError('Original upstream archive differs from its independently published SHA-256')
        if _state(os.fstat(source.fileno())) != _state(before):
            raise ValueError('Original upstream archive changed during authentication')
        source.seek(0)
        with zipfile.ZipFile(source) as archive:
            entries = [entry for entry in archive.infolist() if entry.filename == member]
            if len(entries) != 1:
                raise ValueError('Upstream archive has no unique selected member')
            entry = entries[0]
            if entry.is_dir() or entry.flag_bits & 1 or stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size > 128 * 1024 * 1024:
                raise ValueError('Invalid selected upstream archive member')
            value = hashlib.sha256()
            with archive.open(entry) as content:
                for block in iter(lambda: content.read(1024 * 1024), b''):
                    value.update(block)
        if path.is_symlink() or _state(os.fstat(source.fileno())) != _state(before) or _state(path.stat()) != _state(before):
            raise ValueError('Original upstream archive changed during member verification')
        return value.hexdigest()
