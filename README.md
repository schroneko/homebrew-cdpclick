# auto-click-cdp-popup

`auto-click-cdp-popup` is a small macOS Accessibility watcher that automatically accepts Chrome remote debugging confirmation prompts for trusted local Chrome DevTools Protocol workflows.

It watches Chrome UI through `AXObserver`, uses a light 1 second fallback scan, and only presses an allow button when the prompt element itself contains Chrome remote debugging text such as `Allow remote debugging?`.

## Install

```bash
brew install schroneko/tap/auto-click-cdp-popup
auto-click-cdp-popup-install-agent
```

After installing the LaunchAgent, grant Accessibility permission to `AutoClickCDPPopup.app` in System Settings:

```text
System Settings -> Privacy & Security -> Accessibility
```

## Usage

Run once in the foreground:

```bash
auto-click-cdp-popup
```

Install and start the login agent:

```bash
auto-click-cdp-popup-install-agent
```

Uninstall the login agent:

```bash
auto-click-cdp-popup-uninstall-agent
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

## Build

```bash
swift build -c release
```

## License

MIT
