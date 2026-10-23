#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--prepare-install" ) ]]; then
  echo "Usage: $0 [--prepare-install]" >&2
  exit 1
fi

task_user_home="$(/usr/bin/dscacheutil -q user -a uid "$UID" | /usr/bin/sed -n 's/^dir: //p')"
if [[ -z "$task_user_home" ]]; then
  echo "Unable to resolve the account home directory for uid $UID" >&2
  exit 1
fi

host_name="com.schroneko.autoclickcdppopup.bridge"
extension_id="emfpblpnedhhgjgmdlbipkfbockgofjp"
app_path="${CDPCLICK_APP_PATH:-/Applications/AutoClickCDPPopup.app}"
watcher_path="$app_path/Contents/MacOS/auto-click-cdp-popup"
native_host_path="$app_path/Contents/Resources/cdpclick-native-host"
extension_path="$app_path/Contents/Resources/ChromeExtension"
validation_watcher_path="$watcher_path"
validation_native_host_path="$native_host_path"
validation_extension_path="$extension_path"
if [[ "${1:-}" == "--prepare-install" ]]; then
  script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  validation_watcher_path="$script_directory/../MacOS/auto-click-cdp-popup"
  validation_native_host_path="$script_directory/cdpclick-native-host"
  validation_extension_path="$script_directory/ChromeExtension"
fi
chrome_support="$task_user_home/Library/Application Support/Google/Chrome"
host_directory="$chrome_support/NativeMessagingHosts"
host_manifest="$host_directory/$host_name.json"
legacy_host_manifest="$host_directory/com.schroneko.auto-click-cdp-popup.bridge.json"

if [[ ! -x "$validation_watcher_path" ]]; then
  echo "cdpclick watcher is missing from $validation_watcher_path" >&2
  exit 1
fi

if [[ ! -x "$validation_native_host_path" ]]; then
  echo "Chrome bridge native host is missing from $validation_native_host_path" >&2
  exit 1
fi

if [[ ! -f "$validation_extension_path/manifest.json" ]]; then
  echo "Chrome bridge extension is missing from $validation_extension_path" >&2
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
