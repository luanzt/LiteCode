#!/bin/bash
# Builds build/LiteCode.app (release). Pass --install to copy it into /Applications.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release

app="build/LiteCode.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin="$(swift build -c release --show-bin-path)"
cp "$bin/LiteCode" "$app/Contents/MacOS/LiteCode"
# SwiftPM resource bundle (Material icons); MaterialIcons.swift looks for it in Contents/Resources.
cp -R "$bin/LiteCode_LiteCode.bundle" "$app/Contents/Resources/"

if [[ ! -f build/AppIcon.icns ]]; then
  iconset="build/AppIcon.iconset"
  rm -rf "$iconset" && mkdir -p "$iconset"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Lets Finder/Dock/`open -a LiteCode <path>` hand folders and text files to the app. -->
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

# A persistent identity keeps macOS folder-access grants across rebuilds; ad-hoc signatures
# change every build. Reuses mTerm's self-signed identity when present.
identity="${LITECODE_SIGN_IDENTITY:-mTerm Self-Signed}"
if security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  codesign --force --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
fi
echo "Built $root/$app"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/LiteCode.app
  cp -R "$app" /Applications/LiteCode.app
  echo "Installed /Applications/LiteCode.app"
fi
