#!/usr/bin/env bash
#
# Sign a packaged LiteCode DMG with Sparkle's EdDSA key and generate the update feed.
# The private key is read from the macOS Keychain (account litecode-ed25519) by Sparkle's tools.
#
#   scripts/generate-appcast.sh <version> [output]
#
# Writes build/appcast.xml by default, so the GitHub release can exist before the live
# appcast.xml at the repository root is replaced and pushed.
set -euo pipefail

repository="luanzt/LiteCode"
key_account="litecode-ed25519"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="${1:-}"
version="${version#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <MAJOR.MINOR.PATCH> [output]" >&2
  exit 2
fi

dmg="$root/build/LiteCode-$version.dmg"
output="${2:-$root/build/appcast.xml}"
[[ "$output" == /* ]] || output="$root/$output"

tools="$root/.build/artifacts/sparkle/Sparkle/bin"
[[ -f "$dmg" ]] || { echo "error: package first; missing $dmg" >&2; exit 1; }
[[ -x "$tools/generate_appcast" && -x "$tools/sign_update" ]] || {
  echo "error: Sparkle tools not found; run swift build -c release first" >&2
  exit 1
}

archives="$(mktemp -d "${TMPDIR:-/tmp}/litecode-appcast.XXXXXX")"
trap 'rm -rf "$archives"' EXIT
ditto "$dmg" "$archives/$(basename "$dmg")"
mkdir -p "$(dirname "$output")"
rm -f "$output"

echo "==> Signing $(basename "$dmg") and generating appcast"
"$tools/generate_appcast" \
  --account "$key_account" \
  --download-url-prefix "https://github.com/$repository/releases/download/v$version/" \
  --link "https://github.com/$repository/releases/tag/v$version" \
  --versions "$version" \
  --maximum-versions 1 \
  -o "$output" \
  "$archives"

xmllint --noout "$output"
signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$output" | head -1)"
[[ -n "$signature" ]] || { echo "error: generated appcast has no EdDSA signature" >&2; exit 1; }
"$tools/sign_update" --account "$key_account" --verify "$dmg" "$signature"
echo "Done: $output"
