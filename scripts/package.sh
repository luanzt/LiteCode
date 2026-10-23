#!/usr/bin/env bash
#
# Build LiteCode as a distributable .dmg (drag LiteCode.app into Applications).
#
#   scripts/package.sh <version>      # 1.2.3 or v1.2.3
#
# Output: build/LiteCode-<version>.dmg
#
# The app is signed by scripts/bundle.sh (stable self-signed identity when present, else ad-hoc)
# and is NOT notarized: on first open, right-click the app and choose "Open".
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="${1:-}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <MAJOR.MINOR.PATCH>" >&2
  exit 2
fi

LITECODE_VERSION="$version" ./scripts/bundle.sh

app="build/LiteCode.app"
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$built" == "$version" ]] || { echo "error: bundle reports version $built, expected $version" >&2; exit 1; }

dmg="build/LiteCode-$version.dmg"
stage="build/dmg-stage"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "LiteCode $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"
echo "Done: $root/$dmg"
