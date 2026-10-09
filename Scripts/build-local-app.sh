#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

# Optimization is independent of distribution defaults. Missing plist metadata is off.
channel=${1:-development}
case "$channel" in
  development) app_dir="$project_dir/.build/LingoMend.app" ;;
  release) app_dir="$project_dir/.build/LingoMend-Release.app" ;;
  *) printf '%s\n' 'Usage: sh Scripts/build-local-app.sh [development|release]' >&2; exit 2 ;;
esac

swift build -c release --product LingoMendApp
binary_dir=$(swift build -c release --show-bin-path)

mkdir -p "$app_dir/Contents/MacOS"
install -m 755 "$binary_dir/LingoMendApp" "$app_dir/Contents/MacOS/LingoMendApp"
install -m 644 "$project_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LingoMendBuildChannel $channel" "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"

printf '%s\n' "$app_dir"
