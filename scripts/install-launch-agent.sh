#!/usr/bin/env bash
set -euo pipefail

label="com.schroneko.auto-click-cdp-popup"
app_path="$HOME/Applications/AutoClickCDPPopup.app"
watcher_path="$app_path/Contents/MacOS/auto-click-cdp-popup"
plist_path="$HOME/Library/LaunchAgents/$label.plist"
log_dir="$HOME/Library/Logs/auto-click-cdp-popup"
source_binary="${AUTO_CLICK_CDP_POPUP_BINARY:-}"

if [[ -z "$source_binary" ]]; then
  source_binary="$(command -v auto-click-cdp-popup)"
fi

if [[ ! -x "$source_binary" ]]; then
  echo "auto-click-cdp-popup binary is not executable: $source_binary" >&2
  exit 1
fi

if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID" "$plist_path" >/dev/null 2>&1 || true
fi

pkill -f "$watcher_path" >/dev/null 2>&1 || true

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$HOME/Library/LaunchAgents" "$log_dir"
cp "$source_binary" "$watcher_path"
chmod 755 "$watcher_path"

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
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --identifier "$label" "$app_path" >/dev/null

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
echo "Installed $app_path and started $label"
