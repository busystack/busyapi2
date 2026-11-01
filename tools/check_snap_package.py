#!/usr/bin/env python3
"""Check BusyAPI's configure and desktop handoffs in prime and packed images.

GNOME's unchanged font hook execs this endpoint after generating its cache.
Snapcraft normally supplies a placeholder, but a prepared-prime pack must not
omit it. This check neither generates metadata nor changes extension scripts.
The packed desktop file must also have passed Snapcraft's normal mediation:
snapd requires a namespaced app command, not the standalone executable name.
"""
import argparse
import configparser
from pathlib import Path
import shlex

from tools.snap_extension_notices import ordinary

CONFIGURE = b'#!/bin/true\n'
WRAPPER = b'#!/bin/sh\nexec "$SNAP/snap/hooks/configure" "$@"\n'
DESKTOP = 'share/applications/io.busystack.busyapi.desktop'
ICON = 'share/icons/hicolor/scalable/apps/io.busystack.busyapi.svg'
PACKAGED_ICON = 'meta/gui/icon.svg'


def desktop_entry(prime, relative):
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.optionxform = str
    parser.read_string(ordinary(prime, relative).decode('utf-8'))
    if 'Desktop Entry' not in parser:
        raise RuntimeError('Missing Snap desktop entry')
    return parser['Desktop Entry']


def verify_desktop(prime, *, packaged=False):
    source = desktop_entry(prime, DESKTOP)
    if shlex.split(source.get('Exec', '')) != ['busyapi-desktop', '%F']:
        raise RuntimeError('Unexpected standalone desktop command')
    if not ordinary(prime, ICON):
        raise RuntimeError('Empty BusyAPI desktop icon')
    if packaged:
        entry = desktop_entry(prime, 'meta/gui/busyapi-desktop.desktop')
        if shlex.split(entry.get('Exec', '')) != ['busyapi.busyapi-desktop', '%F']:
            raise RuntimeError('Missing or unmediated Snap desktop command')
        if entry.get('Icon') != '${SNAP}/' + PACKAGED_ICON:
            raise RuntimeError('Missing packaged Snap desktop icon identity')
        if ordinary(prime, PACKAGED_ICON) != ordinary(prime, ICON):
            raise RuntimeError('Changed packaged Snap desktop icon')
        if entry.get('Type') != 'Application' or entry.get('Terminal') != 'false':
            raise RuntimeError('Unexpected Snap desktop application type')


def executable(prime, relative):
    data = ordinary(prime, relative)
    if (prime / relative).stat().st_mode & 0o111 != 0o111:
        raise RuntimeError('Non-executable Snap hook material: ' + relative)
    return data


def verify(prime, *, packaged=False, application_assets=False):
    prime = Path(prime).resolve(strict=True)
    if executable(prime, 'snap/hooks/configure') != CONFIGURE:
        raise RuntimeError('Unexpected BusyAPI configure hook')
    for name in ['hooks-configure-fonts', 'run']:
        executable(prime, 'snap/command-chain/' + name)
    if packaged:
        if executable(prime, 'meta/hooks/configure') not in (CONFIGURE, WRAPPER):
            raise RuntimeError('Unexpected packaged configure handoff')
    verify_desktop(prime, packaged=packaged)
    if application_assets:
        from tools.verify_m3_assets import verify as verify_m3_assets
        verify_m3_assets(prime)
        from tools.prepare_generator import verify as verify_generator
        verify_generator(prime / 'libexec/busyapi/generator')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prime', type=Path, required=True)
    parser.add_argument('--packaged', action='store_true')
    parser.add_argument('--application-assets', action='store_true')
    args = parser.parse_args()
    verify(args.prime, packaged=args.packaged, application_assets=args.application_assets)
