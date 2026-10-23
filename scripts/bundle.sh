#!/bin/bash
# Builds build/LiteCode.app (release). Pass --install to copy it into /Applications.
# The version comes from $LITECODE_VERSION, else the latest git tag (without "v"), else 0.0.0.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="${LITECODE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
version="${version#v}"
# Sparkle reads the appcast published by scripts/generate-appcast.sh and checks it against the
# public half of the EdDSA key kept in the release machine's Keychain (account litecode-ed25519).
feed_url="https://raw.githubusercontent.com/luanzt/LiteCode/main/appcast.xml"
public_ed_key="eqs3YlfUb49i1elAd530Q0hWtG8t4YNpfqQvSL9C9No="

swift build -c release

app="build/LiteCode.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
bin="$(swift build -c release --show-bin-path)"
cp "$bin/LiteCode" "$app/Contents/MacOS/LiteCode"
# SwiftPM resource bundle (Material icons); MaterialIcons.swift looks for it in Contents/Resources.
cp -R "$bin/LiteCode_LiteCode.bundle" "$app/Contents/Resources/"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/LiteCode"

# App icon: packaging/AppIcon.icns when present, else the generated placeholder.
icon="packaging/AppIcon.icns"
if [[ ! -f "$icon" ]]; then
  icon="build/AppIcon.icns"
  if [[ ! -f "$icon" ]]; then
    iconset="build/AppIcon.iconset"
    rm -rf "$iconset" && mkdir -p "$iconset"
    swift scripts/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
      sips -z $s $s build/icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
      sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$icon"
  fi
fi
cp "$icon" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>LiteCode</string>
  <key>CFBundleIdentifier</key><string>dev.luan.litecode</string>
  <key>CFBundleName</key><string>LiteCode</string>
  <key>CFBundleDisplayName</key><string>LiteCode</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>$feed_url</string>
  <key>SUPublicEDKey</key><string>$public_ed_key</string>
  <!-- Updates are checked from the app menu, not in the background (same as mTerm). -->
  <key>SUEnableAutomaticChecks</key><false/>
  <!-- Lets Finder, the Dock, and "open -a LiteCode <path>" hand folders and text files to the app. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Source</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.text</string><string>public.source-code</string><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# A persistent identity keeps macOS folder-access grants across updates; ad-hoc signatures
# change every build. Reuses mTerm's self-signed identity when present. Sparkle.framework keeps
# the signature it ships with.
identity="${LITECODE_SIGN_IDENTITY:-mTerm Self-Signed}"
if security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  codesign --force --sign "$identity" "$app"
else
  echo "warning: signing identity '$identity' not found; signing ad-hoc" >&2
  codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built $root/$app ($version)"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/LiteCode.app
  cp -R "$app" /Applications/LiteCode.app
  echo "Installed /Applications/LiteCode.app"
fi
