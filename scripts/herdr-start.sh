#!/bin/bash
# Herdr plugin startup hook and action. The app runs from a copy in the plugin state directory,
# because Herdr removes old installation directories after an update.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="$repo_root/build/TskViewer.app"
dest="${HERDR_PLUGIN_STATE_DIR:?run through Herdr}/TskViewer.app"

if pgrep -xq TskViewer; then
    exit 0
fi
if [[ ! -d "$src" ]]; then
    printf 'Missing %s, run scripts/build-app.sh first\n' "$src" >&2
    exit 1
fi
if ! cmp -s "$src/Contents/MacOS/TskViewer" "$dest/Contents/MacOS/TskViewer"; then
    rm -rf -- "$dest"
    ditto "$src" "$dest"
fi

# A menu bar app does not inherit PATH, so hand it the tool paths.
env_args=()
if [[ -n "${HERDR_BIN_PATH:-}" ]]; then
    env_args+=(--env "HERDR_PATH=$HERDR_BIN_PATH")
fi
if tsk_path="$(command -v tsk)"; then
    env_args+=(--env "TSK_PATH=$tsk_path")
fi
open ${env_args[@]+"${env_args[@]}"} "$dest"
