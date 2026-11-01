#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/prepare_contract_assets.py --output build/test-runtime/libexec/busyapi
python3 tools/prepare_m3_tools.py --output build/test-runtime/libexec/busyapi
python3 tools/prepare_generator.py --output build/test-runtime/libexec/busyapi/generator
node_bin=build/test-runtime/libexec/busyapi/node
"$node_bin" tools/prepare_documentation_assets.mjs --output build/test-runtime/share/busyapi/documentation/redoc
"$node_bin" tools/prepare_documentation_assets.mjs --output build/test-runtime/share/busyapi/documentation/swagger --preset swagger
dart_bin="${BUSYAPI_DART:-$(command -v dart)}"
"$dart_bin" compile exe packages/busyapi_core/bin/busyapi.dart -o build/test-runtime/busyapi
"$dart_bin" packages/busyapi_core/tool/prepare_notices.dart --output=build/dart-notices
python3 tools/prepare_resource_package_assets.py --output build/resource-package-runtime \
  --dart "$dart_bin" --contract-runtime build/test-runtime/libexec/busyapi --dart-notices build/dart-notices
# Use the same installed layout as CMake. No runtime fallback to the checkout.
install -m 755 build/resource-package-runtime/resource-package-loader build/test-runtime/libexec/busyapi/resource-package-loader
mkdir -p build/test-runtime/share/busyapi/resource-package build/test-runtime/share/licenses/busyapi-dart build/test-runtime/share/licenses/busyapi-engine
install -m 644 build/resource-package-runtime/runtime.json build/test-runtime/share/busyapi/resource-package/runtime.json
cp -R build/dart-notices/. build/test-runtime/share/licenses/busyapi-dart/
cp -R build/test-runtime/libexec/busyapi/licenses/. build/test-runtime/share/licenses/busyapi-engine/
"$dart_bin" compile exe packages/busyapi_core/test/recovery_child.dart -o build/test-runtime/recovery-child

"$dart_bin" compile exe packages/busyapi_core/test/publication_child.dart -o build/test-runtime/publication-child
"$dart_bin" compile exe packages/busyapi_core/test/cli_fault_child.dart -o build/test-runtime/cli-fault-child
"$dart_bin" compile exe packages/busyapi_core/test/definition_move_child.dart -o build/test-runtime/definition-move-child
"$dart_bin" compile exe packages/busyapi_core/test/file_move_child.dart -o build/test-runtime/file-move-child
"$dart_bin" compile exe packages/busyapi_core/test/redirect_redaction_child.dart -o build/test-runtime/redirect-redaction-child
