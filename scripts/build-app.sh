#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: build-app.sh VERSION}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
label="com.schroneko.auto-click-cdp-popup"
build_dir="$repo_root/build"
app_path="$build_dir/AutoClickCDPPopup.app"
zip_path="$build_dir/AutoClickCDPPopup-$version.zip"

swift build -c release --package-path "$repo_root"
binary="$repo_root/.build/release/auto-click-cdp-popup"

rm -rf "$app_path" "$zip_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary" "$app_path/Contents/MacOS/auto-click-cdp-popup"
cp "$repo_root/scripts/install-launch-agent.sh" "$app_path/Contents/Resources/cdpclick-install-agent"
cp "$repo_root/scripts/uninstall-launch-agent.sh" "$app_path/Contents/Resources/cdpclick-uninstall-agent"
chmod 755 "$app_path/Contents/MacOS/auto-click-cdp-popup" \
  "$app_path/Contents/Resources/cdpclick-install-agent" \
  "$app_path/Contents/Resources/cdpclick-uninstall-agent"

cat >"$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Auto Click CDP Popup</string>
  <key>CFBundleExecutable</key>
  <string>auto-click-cdp-popup</string>
  <key>CFBundleIdentifier</key>
  <string>$label</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Auto Click CDP Popup</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$version</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

signing_identity="${CDPCLICK_SIGNING_IDENTITY:-NiceVoice}"
if security find-identity -v -p codesigning | fgrep -q "\"$signing_identity\""; then
  codesign --force --deep --sign "$signing_identity" --identifier "$label" "$app_path"
  echo "signed with stable identity \"$signing_identity\"; Accessibility grant survives upgrades"
else
  codesign --force --deep --sign - --identifier "$label" "$app_path"
  echo "ad-hoc signed; Accessibility grant must be re-granted after upgrades"
fi
ditto -c -k --keepParent "$app_path" "$zip_path"
shasum -a 256 "$zip_path"
