#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_bin="${BUSYAPI_FLUTTER:-flutter}"
case "${BUSYAPI_DISTRIBUTION:-standalone}" in
  standalone|snap) ;;
  *) echo 'Choose BUSYAPI_DISTRIBUTION=standalone or snap.' >&2; exit 1;;
esac
if [[ "${BUSYAPI_DISTRIBUTION:-standalone}" == snap && -n "${BUSYAPI_NATIVE_SOURCE_CACHE:-}${BUSYAPI_NATIVE_SOURCE_INDEX:-}${BUSYAPI_NATIVE_SOURCE_OUTPUT:-}" ]]; then
  echo 'The standalone copied-library source companion is not a Snap platform inventory.' >&2
  exit 1
fi
case "${BUSYAPI_WIDGET_RUNNER:-standard}" in
  standard|local|both) ;;
  *) echo 'Choose BUSYAPI_WIDGET_RUNNER=standard, local or both.' >&2; exit 1;;
esac
if [[ -n "${BUSYAPI_NATIVE_SOURCE_CACHE:-}${BUSYAPI_NATIVE_SOURCE_INDEX:-}${BUSYAPI_NATIVE_SOURCE_OUTPUT:-}" ]]; then
  [[ -n "${BUSYAPI_NATIVE_SOURCE_CACHE:-}" && -n "${BUSYAPI_NATIVE_SOURCE_INDEX:-}" && -n "${BUSYAPI_NATIVE_SOURCE_OUTPUT:-}" ]] || {
    echo 'Set all three BUSYAPI_NATIVE_SOURCE_CACHE, BUSYAPI_NATIVE_SOURCE_INDEX and BUSYAPI_NATIVE_SOURCE_OUTPUT to assemble native source materials.' >&2
    exit 1
  }
fi
source tools/node_toolchain.sh
busyapi_select_node
busyapi_sdk_metadata
pub_args=(--enforce-lockfile)
if [[ "${BUSYAPI_BUILD_OFFLINE:-0}" == 1 ]]; then pub_args+=(--offline); fi
"$flutter_bin" pub get "${pub_args[@]}"
tools/build_engine.sh
tools/build_documentation_assets.sh
python3 tools/prepare_contract_assets.py --node "$node_bin"
dart_bin="$(dirname "$(dirname "$(readlink -f "$(command -v "$flutter_bin")")")")/bin/cache/dart-sdk/bin/dart"
BUSYAPI_DART="$dart_bin" tools/prepare_test_runtime.sh
"$flutter_bin" gen-l10n
"$flutter_bin" analyze --no-pub
case "${BUSYAPI_WIDGET_RUNNER:-standard}" in
  local) BUSYAPI_FLUTTER="$flutter_bin" tools/test_widgets_local.sh;;
  both)
    "$flutter_bin" test --no-pub --concurrency=1
    BUSYAPI_FLUTTER="$flutter_bin" tools/test_widgets_local.sh;;
  # The widget integration files each own a real helper process and an
  # eight-second fail-closed IO guard. Running them concurrently can starve a
  # correct reply behind other process-heavy fixtures; keep the release gate
  # deterministic rather than treating a loaded parallel run as a product
  # failure.
  standard) "$flutter_bin" test --no-pub --concurrency=1;;
esac
# Resource-package cases copy and independently execute complete runtimes under
# their unchanged watchdogs. Keep unrelated process-heavy suites serial here;
# the actual IPC/process concurrency contracts have their own explicit tests.
"$dart_bin" test packages/busyapi_core/test --concurrency=1
"$flutter_bin" build linux --release --no-pub
bundle=build/linux/x64/release/bundle
"$dart_bin" compile exe packages/busyapi_core/bin/busyapi.dart -o "$bundle/busyapi"
package_args=("$bundle")
if [[ "${BUSYAPI_DISTRIBUTION:-standalone}" == snap ]]; then package_args+=(--platform-runtime); fi
python3 tools/package_linux.py "${package_args[@]}"
if [[ -n "${BUSYAPI_NATIVE_SOURCE_INDEX:-}" ]]; then
  python3 tools/native_sources.py "$bundle" --cache "$BUSYAPI_NATIVE_SOURCE_CACHE" \
    --index "$BUSYAPI_NATIVE_SOURCE_INDEX" --output "$BUSYAPI_NATIVE_SOURCE_OUTPUT"
fi
