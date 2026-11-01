"""Verify installed M3 inputs, not merely their earlier preparation stage."""
import json
from pathlib import Path

try:
    from .verify_application_assets import ordinary, digest
    from .prepare_m3_tools import OASDIFF_SHA256, OASDIFF_VERSION
except ImportError:  # Direct script callers use tools/ as their import root.
    from verify_application_assets import ordinary, digest
    from prepare_m3_tools import OASDIFF_SHA256, OASDIFF_VERSION


def verify(bundle):
    bundle = Path(bundle)
    runtime = bundle / 'libexec/busyapi'
    receipt = json.loads(ordinary(runtime, 'build.json').read_bytes())
    mock = ordinary(runtime, 'mock-server.cjs', 64 * 1024 * 1024)
    if receipt.get('version') != 1 or digest(mock) != receipt.get('mockHelperSha256'):
        raise RuntimeError('Installed Prism adapter differs from its build receipt')
    tool = ordinary(runtime, 'oasdiff', 64 * 1024 * 1024)
    if digest(tool) != OASDIFF_SHA256 or tool.stat().st_mode & 0o111 != 0o111:
        raise RuntimeError('Installed oasdiff identity or executable mode differs from its lock')
    inventory = json.loads(ordinary(bundle, 'share/busyapi/tools.json').read_bytes())
    if not any(item.get('name') == 'oasdiff' and item.get('version') == OASDIFF_VERSION
               and item.get('binarySha256') == OASDIFF_SHA256 for item in inventory.get('tools', [])):
        raise RuntimeError('Installed oasdiff tool identity is missing')
