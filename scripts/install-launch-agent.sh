#!/usr/bin/env bash
set -euo pipefail

label="com.schroneko.auto-click-cdp-popup"
app_path="/Applications/AutoClickCDPPopup.app"
watcher_path="$app_path/Contents/MacOS/auto-click-cdp-popup"
plist_path="$HOME/Library/LaunchAgents/$label.plist"
log_dir="$HOME/Library/Logs/auto-click-cdp-popup"

if [[ ! -x "$watcher_path" ]]; then
  echo "AutoClickCDPPopup.app is not installed at $app_path" >&2
  echo "Install it with: brew install --cask schroneko/cdpclick/cdpclick" >&2
  exit 1
fi

if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID" "$plist_path" >/dev/null 2>&1 || true
fi

pkill -f "AutoClickCDPPopup.app/Contents/MacOS/auto-click-cdp-popup" >/dev/null 2>&1 || true

mkdir -p "$HOME/Library/LaunchAgents" "$log_dir"

cat >"$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-gj</string>
    <string>$app_path</string>
    <string>--args</string>
    <string>--interval</string>
    <string>1</string>
    <string>--log</string>
    <string>$log_dir/actions.log</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/stderr.log</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

plutil -lint "$plist_path"
launchctl bootstrap "gui/$UID" "$plist_path"
launchctl enable "gui/$UID/$label"
open -gj "$app_path" --args --interval 1 --log "$log_dir/actions.log"
echo "Installed LaunchAgent $label using $app_path"
echo "Grant Accessibility permission to AutoClickCDPPopup.app in System Settings > Privacy & Security > Accessibility"
