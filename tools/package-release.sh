#!/bin/sh
# Build WattNook.app for a release and zip it for GitHub Releases.
# Usage: tools/package-release.sh 0.2.0
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: $0 VERSION" >&2; exit 2; fi
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$project_dir/dist"
mkdir -p "$out"
rm -rf "$out/WattNook.app" "$out/WattNook-$1.zip"
WATTNOOK_VERSION="$1" "$project_dir/tools/build-wattnook-app.sh" "$out/WattNook.app"
# Ad-hoc signature over the whole bundle (no Developer ID yet).
codesign --force --deep --sign - "$out/WattNook.app"
codesign --verify --deep --strict "$out/WattNook.app"
ditto -c -k --keepParent "$out/WattNook.app" "$out/WattNook-$1.zip"
shasum -a 256 "$out/WattNook-$1.zip"
