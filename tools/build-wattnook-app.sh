#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ -e "$1" ]; then
  echo "Usage: $0 /path/to/new/WattNook.app" >&2
  exit 2
fi
case "$1" in
  /*) ;;
  *) echo "Output path must be absolute" >&2; exit 2 ;;
esac

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target=$1
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/wattnook-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/WattNook.app"
export GOCACHE="${GOCACHE:-${TMPDIR:-/tmp}/wattnook-go-cache}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$project_dir/tools/app/Info.plist" "$app/Contents/Info.plist"
# WATTNOOK_VERSION (e.g. 0.2.0) stamps the binary and the bundle; the app
# compares it with the helper's version to offer "Upgrade helper".
version=${WATTNOOK_VERSION:-0.0.0-dev}
commit=$(cd "$project_dir" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
(
  cd "$project_dir"
  go build -trimpath -ldflags "-s -w -X github.com/charlie0129/batt/pkg/version.Version=v$version -X github.com/charlie0129/batt/pkg/version.GitCommit=$commit" \
    -o "$app/Contents/MacOS/WattNook" ./cmd/batt
  swiftc -O -module-cache-path "${TMPDIR:-/tmp}/wattnook-swift-modules" \
    tools/keep-awake/Policy.swift tools/keep-awake/KeepAwake.swift -o "$app/Contents/MacOS/KeepAwake"
  icon_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wattnook-icon.XXXXXX")
  trap 'rm -rf "$icon_tmp"' EXIT
  icon_source="$project_dir/tools/app/WattNook-Icon.png"
  mkdir "$icon_tmp/WattNook.iconset"
  for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$icon_source" \
      --out "$icon_tmp/WattNook.iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" "$icon_source" \
      --out "$icon_tmp/WattNook.iconset/icon_${points}x${points}@2x.png" >/dev/null
  done
  iconutil -c icns "$icon_tmp/WattNook.iconset" -o "$app/Contents/Resources/WattNook.icns"
)
mv "$app" "$target"
echo "$target"
