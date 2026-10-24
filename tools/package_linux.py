"""Bundle non-glibc shared dependencies. Never modifies a system installation."""
import argparse, pathlib
from native_distribution import assemble as assemble_native_distribution
from verify_font_assets import verify as verify_font_assets
from verify_application_assets import verify as verify_application_assets
from verify_documentation_runtime import verify as verify_documentation_runtime
from verify_resource_package_assets import verify as verify_resource_package_assets
from verify_m3_assets import verify as verify_m3_assets
from prepare_generator import verify as verify_generator
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle',type=pathlib.Path)
parser.add_argument('--platform-runtime',action='store_true',help='Verify a fresh CMake layout without copying libraries supplied by the Snap base/GNOME platform')
args=parser.parse_args()
bundle=args.bundle.resolve()
if args.platform_runtime and (bundle/'share/licenses/busyapi-native/dependencies.json').exists():
    raise RuntimeError('Platform-runtime packaging requires a fresh CMake install, not an assembled standalone layout')
for required in ['busyapi-desktop', 'busyapi', 'libexec/busyapi/node',
                 'libexec/busyapi/engine.cjs', 'libexec/busyapi/policy-worker.cjs',
                 'lib/libbusyapi_documentation.so', 'share/busyapi/documentation-runtime.json',
                 'libexec/busyapi/policy-isolation.node', 'libexec/busyapi/policy-launcher',
                 'libexec/busyapi/policy-build.json', 'libexec/busyapi/mock-server.cjs',
                 'libexec/busyapi/oasdiff', 'libexec/busyapi/build.json',
                 'libexec/busyapi/generator/assets.json',
                 'libexec/busyapi/generator/openapi-generator.jar',
                 'libexec/busyapi/generator/jre/bin/java',
                 'libexec/busyapi/generator/generator-launcher']:
    if not (bundle/required).is_file():
        raise RuntimeError('Missing standalone asset: '+required)
for schema in ['oas31.json', 'oas32.json', 'oas30.json']:
    if not (bundle/'share/busyapi/schemas'/schema).is_file():
        raise RuntimeError('Missing standalone schema asset: '+schema)
for path in bundle.rglob('*'):
    if path.is_symlink() and (path.readlink().is_absolute() or
                              not path.resolve().is_relative_to(bundle)):
        raise RuntimeError('Non-relocatable bundle symlink: '+str(path.relative_to(bundle)))
verify_font_assets(bundle)
verify_application_assets(bundle)
verify_documentation_runtime(bundle)
verify_resource_package_assets(bundle)
verify_m3_assets(bundle)
verify_generator(bundle/'libexec/busyapi/generator')
# A profile/debug build can leave its kernel asset in shared native staging.
# The shipped AOT application reads libapp.so; do not package an old kernel.
if (bundle/'lib/libapp.so').is_file():
    (bundle/'data/flutter_assets/kernel_blob.bin').unlink(missing_ok=True)
if not args.platform_runtime:
    assemble_native_distribution(bundle)
