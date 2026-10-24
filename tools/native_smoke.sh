#!/usr/bin/env bash
# Run on a real accessible desktop. Never edits BusyMark or its state.
set -euo pipefail
bundle="${1:?Provide packaged bundle path}"
smoke_state=$(mktemp -d /tmp/busyapi-native-smoke.XXXXXX)
export XDG_CONFIG_HOME="$smoke_state/config" XDG_STATE_HOME="$smoke_state/state" XDG_CACHE_HOME="$smoke_state/cache"
"$bundle/busyapi-desktop"
