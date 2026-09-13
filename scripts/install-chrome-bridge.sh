#!/usr/bin/env bash
set -euo pipefail

host_name="com.schroneko.autoclickcdppopup.bridge"
extension_id="emfpblpnedhhgjgmdlbipkfbockgofjp"
app_path="${CDPCLICK_APP_PATH:-/Applications/AutoClickCDPPopup.app}"
watcher_path="$app_path/Contents/MacOS/auto-click-cdp-popup"
native_host_path="$app_path/Contents/Resources/cdpclick-native-host"
extension_path="$app_path/Contents/Resources/ChromeExtension"
chrome_support="$HOME/Library/Application Support/Google/Chrome"
host_directory="$chrome_support/NativeMessagingHosts"
host_manifest="$host_directory/$host_name.json"
legacy_host_manifest="$host_directory/com.schroneko.auto-click-cdp-popup.bridge.json"

if [[ ! -x "$watcher_path" ]]; then
  echo "AutoClickCDPPopup.app is not installed at $app_path" >&2
  exit 1
fi

if [[ ! -x "$native_host_path" ]]; then
  echo "Chrome bridge native host is missing from $native_host_path" >&2
  exit 1
fi

if [[ ! -f "$extension_path/manifest.json" ]]; then
  echo "Chrome bridge extension is missing from $extension_path" >&2
  exit 1
fi

mkdir -p "$host_directory"
rm -f "$legacy_host_manifest"
cat >"$host_manifest" <<MANIFEST
{
  "name": "$host_name",
  "description": "cdpclick native messaging bridge",
  "path": "$native_host_path",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$extension_id/"
  ]
}
MANIFEST

node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$host_manifest"
echo "Installed Chrome Native Messaging host $host_name"
echo "Load this unpacked extension in the normal Chrome profile: $extension_path"
echo "Chrome extensions page: chrome://extensions"
