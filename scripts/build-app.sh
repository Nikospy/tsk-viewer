#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift build -c release
bin_path="$(swift build -c release --show-bin-path)"
app_path="$repo_root/build/TskViewer.app"

rm -rf -- "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp "$bin_path/TskViewer" "$app_path/Contents/MacOS/TskViewer"
cp "$repo_root/Support/Info.plist" "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
printf 'Built: %s\n' "$app_path"
