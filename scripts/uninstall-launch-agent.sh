#!/usr/bin/env bash
set -euo pipefail

label="com.schroneko.auto-click-cdp-popup"
host_name="com.schroneko.autoclickcdppopup.bridge"
legacy_app_path="$HOME/Applications/AutoClickCDPPopup.app"
plist_path="$HOME/Library/LaunchAgents/$label.plist"
host_manifest="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$host_name.json"
legacy_host_manifest="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.schroneko.auto-click-cdp-popup.bridge.json"

if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID" "$plist_path" >/dev/null 2>&1 || true
fi

launchctl disable "gui/$UID/$label" >/dev/null 2>&1 || true
pkill -f "AutoClickCDPPopup.app/Contents/MacOS/auto-click-cdp-popup" >/dev/null 2>&1 || true
rm -f "$plist_path"
rm -f "$host_manifest"
rm -f "$legacy_host_manifest"
rm -rf "$legacy_app_path"
echo "Uninstalled LaunchAgent $label"
echo "Remove the app itself with: brew uninstall --cask cdpclick"
echo "Remove the unpacked cdpclick bridge extension from chrome://extensions"
