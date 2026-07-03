# cdpclick

`cdpclick` is a small macOS Accessibility watcher that automatically accepts Chrome remote debugging confirmation prompts for trusted local Chrome DevTools Protocol workflows.

It watches Chrome UI through `AXObserver`, uses a light foreground-app fallback scan, and only presses an allow button when the prompt element itself contains Chrome remote debugging text such as `Allow remote debugging?`.

## Install

```bash
brew install --cask schroneko/cdpclick/cdpclick
cdpclick-install-agent
```

After installing the LaunchAgent, grant Accessibility permission to `AutoClickCDPPopup.app` in System Settings:

```text
System Settings -> Privacy & Security -> Accessibility
```

The release app is signed with a stable local identity when available. If macOS keeps reporting missing Accessibility permission after an upgrade, remove `AutoClickCDPPopup.app` from the Accessibility list and add `/Applications/AutoClickCDPPopup.app` again.

## Usage

Install and start the login agent:

```bash
cdpclick-install-agent
```

Uninstall the login agent:

```bash
cdpclick-uninstall-agent
```

Run once in the foreground:

```bash
/Applications/AutoClickCDPPopup.app/Contents/MacOS/auto-click-cdp-popup --once --timeout 30
```

## Options

```bash
auto-click-cdp-popup --once --timeout 30
auto-click-cdp-popup --dry-run --once --timeout 10
auto-click-cdp-popup --interval 1 --log ~/Library/Logs/auto-click-cdp-popup/actions.log
```

Supported options:

- `--once`: exit after the first click.
- `--dry-run`: report matches without clicking.
- `--interval <seconds>`: fallback scan interval. Default is `1`.
- `--timeout <seconds>`: exit after a timeout.
- `--max-clicks <count>`: exit after a number of clicks.
- `--process <name>`: watch an additional macOS process name.
- `--log <path>`: append timestamped events to a log file.
- `--prompt-for-accessibility`: ask macOS to show the Accessibility permission prompt once.

## Release

```bash
scripts/build-app.sh VERSION
gh release create vVERSION build/AutoClickCDPPopup-VERSION.zip --title "cdpclick VERSION"
```

Update `version` and `sha256` in `Casks/cdpclick.rb`, then commit and push.

## Build

```bash
swift build -c release
```

## License

MIT
