#!/usr/bin/env bash
# Build input only. Child tooling must use the selected distribution, never an
# unrelated ambient node/npm. Application execution uses installed assets.
busyapi_select_node() {
  local candidate="${BUSYAPI_NODE:-}"
  if [[ -z "$candidate" ]]; then candidate="$(command -v node || true)"; fi
  [[ -n "$candidate" && -x "$candidate" ]] || { echo 'Pinned Node build input is missing; set BUSYAPI_NODE to the verified Node 24.15.0 distribution.' >&2; return 1; }
  node_bin="$(readlink -f "$candidate")"
  [[ "$("$node_bin" --version)" == v24.15.0 ]] || { echo 'Node 24.15.0 is required' >&2; return 1; }
  [[ "$(sha256sum "$node_bin" | cut -d' ' -f1)" == d1de76d8edf2fededf6f8b30d244e2c0529ac607923a018283b77e9c74bd932c ]] || { echo 'Node amd64 binary checksum mismatch' >&2; return 1; }
  local distribution="$(dirname "$(dirname "$node_bin")")"
  npm_cli="$distribution/lib/node_modules/npm/bin/npm-cli.js"
  [[ -f "$npm_cli" ]] || { echo 'Matching npm build input is missing beside the selected Node distribution.' >&2; return 1; }
  export BUSYAPI_NODE="$node_bin"
  export PATH="$(dirname "$node_bin"):$PATH"
}

busyapi_sdk_metadata() {
  local metadata
  metadata="$(mktemp "${TMPDIR:-/tmp}/busyapi-build-sdk.XXXXXXXX.json")"
  # The subshell trap owns only this invocation's private metadata file.
  (
    trap 'rm -f -- "$metadata"' EXIT
    "$flutter_bin" --version --machine > "$metadata"
    python3 - "$metadata" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    value = json.load(source)
assert value['frameworkVersion'] == '3.47.5', 'Use the pinned Flutter 3.47.5 SDK'
assert value['dartSdkVersion'] == '3.13.4', 'Use Dart 3.13.4 from the pinned SDK'
PY
  )
}
