# cdpclick

`cdpclick` is a small macOS helper for trusted local browser workflows. It keeps the existing Accessibility watcher for Chrome remote debugging confirmation prompts and Homebrew Cask Gatekeeper confirmations, and it includes a Chrome extension bridge that uses `chrome.debugger` with Native Messaging inside the normal Chrome profile.

It watches UI through `AXObserver`, follows process restarts, and independently checks Chrome prompts every 250 milliseconds even if no notification arrives. A separate low-frequency maintenance scan refreshes observers and checks Gatekeeper. The Chrome rule only presses an allow button when the prompt element itself contains Chrome remote debugging text such as `Allow remote debugging?`.

Chrome notifications trigger an immediate check followed by short retries while the prompt becomes ready. A prompt that remains present can be retried every 500 milliseconds; two failed attempts no longer suppress it for five minutes. Disappearance is confirmed only when the Accessibility element is invalid, not when an Accessibility request temporarily fails. Completion timing in the log starts at first detection, not at the moment Chrome displayed the prompt.

Loss of Accessibility permission clears the monitoring state. Monitoring is rebuilt when permission returns. These mechanisms target a response within one second while macOS and Chrome are responsive; they cannot provide a hard deadline while the machine is asleep, permission is unavailable, or Accessibility requests are stalled. Web page contents are excluded from Chrome prompt matching.

The normal-profile bridge preserves the cookies, storage, and signed-in state of the Chrome profile where the extension is loaded. It does not start a second Chrome profile and it does not use an external remote-debugging approval dialog. Chrome can keep the extension and its native host running while the macOS session is locked, but an operation that requires browser UI still waits until the session is unlocked.

The Homebrew Gatekeeper rule is independent from the Chrome targets and buttons. It only presses the system-localized Open button when every condition below is satisfied:

- The UI owner has the bundle identifier `com.apple.coreservices.uiagent` and the system bundle path `/System/Library/CoreServices/CoreServicesUIAgent.app`.
- The window's static text contains Homebrew Cask download provenance.
- The headline exactly matches the localized application-from-the-Internet Gatekeeper template.
- The detail matches the system's online or offline notarization wording that Apple checked the app for malicious software and detected none.
- `AXModal` is true. An `AXDialog` or `AXSystemDialog` subrole is accepted only when `AXModal` is unsupported.
- The `AXDefaultButton` is an `AXButton` whose exact label is the localized `Q_BUTTON_OPEN` value. If the default button attribute is unsupported, exactly one button with that label must exist.

Localized headline, detail, provenance, and button values are loaded from the CoreServicesUIAgent `QuarantineHeadlines.loctable`, `QuarantineDetails.loctable`, and `Quarantine.loctable` resources. English and Japanese safe values remain available as fallbacks. Disk image prompts, unverified developer warnings, malware warnings, damaged app warnings, Move to Trash, and Open Anyway are not accepted. The Gatekeeper rule never searches for `Open` as a generic button label.

`Homebrew Cask` is the exact download-agent name recorded in macOS quarantine metadata, not cryptographic verification of a Homebrew receipt.

The offline notarization wording reports Apple's cached result as of the date shown by macOS; it is not a fresh online revocation or malware check.

Each native element is visited at most once per window scan. Cyclic Accessibility references cannot repeatedly expand the same subtree. Chrome menu bars and menu items are excluded because they cannot contain the native approval dialog.

## Install

```bash
brew install --cask schroneko/cdpclick/cdpclick
cdpclick-install-agent
```

Homebrew is the only supported installation and upgrade path. For an existing installation, update the tap and upgrade the Cask:

```bash
brew update
brew upgrade --cask --no-ask schroneko/cdpclick/cdpclick
cdpclick-install-agent
```

If the installed version is already the desired release and the app needs to be restored, use a Cask reinstall:

```bash
brew reinstall --cask --no-ask schroneko/cdpclick/cdpclick
cdpclick-install-agent
```

Do not copy, move, or overlay a build artifact directly into `/Applications`. Do not replace a Homebrew-managed app with a same-version local build. Publish a new release and update the Cask before upgrading through Homebrew.

After installing the LaunchAgent, grant Accessibility permission to `AutoClickCDPPopup.app` in System Settings:

```text
System Settings -> Privacy & Security -> Accessibility
```

Install the normal-profile bridge host, then load the bundled extension once from Chrome's extension manager:

```bash
cdpclick-install-chrome-bridge
```

Open `chrome://extensions`, enable Developer mode, choose Load unpacked, and select the path printed by the command. The extension ID is fixed so the Native Messaging host remains authorized across reloads. The extension must be loaded in the same normal Chrome profile whose authentication should be used.

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

## Status Check

Confirm the watcher is running:

```bash
pgrep -fl AutoClickCDPPopup
launchctl print "gui/$UID/com.schroneko.auto-click-cdp-popup"
```

The LaunchAgent should show `state = running` and the watcher executable as its program. Read the last lines of `~/Library/Logs/auto-click-cdp-popup/actions.log`. A healthy watcher logs `started: watching Chrome CDP prompts and Homebrew Gatekeeper confirmations`. Match and click entries include `[cdp]` or `[homebrew-gatekeeper]` so the rule is identifiable. Repeated `waiting: Accessibility permission is required` means the Accessibility permission is missing; re-grant it in System Settings.

## Options

```bash
auto-click-cdp-popup --once --timeout 30
auto-click-cdp-popup --dry-run --once --timeout 10
auto-click-cdp-popup --interval 60 --log ~/Library/Logs/auto-click-cdp-popup/actions.log
auto-click-cdp-popup --bridge-status
auto-click-cdp-popup --bridge-request '{"id":"tabs","method":"tabs.list"}'
auto-click-cdp-popup --bridge-request '{"id":"eval","method":"debugger.command","tabId":123,"command":"Runtime.evaluate","params":{"expression":"document.title","returnByValue":true}}'
```

Supported options:

- `--once`: exit after the first click.
- `--dry-run`: report matches without clicking.
- `--interval <seconds>`: full maintenance and Gatekeeper scan interval. Default is `60`. Independent Chrome checks remain at 250 milliseconds.
- `--timeout <seconds>`: exit after a timeout.
- `--max-clicks <count>`: exit after a number of clicks.
- `--process <name>`: watch an additional macOS process name.
- `--log <path>`: append timestamped events to a log file.
- `--prompt-for-accessibility`: ask macOS to show the Accessibility permission prompt once.

Bridge requests use a local Unix socket at `~/Library/Application Support/AutoClickCDPPopup/bridge.sock`. Supported methods are `bridge.status`, `tabs.list`, `debugger.attach`, `debugger.detach`, and `debugger.command`. The `debugger.command` method forwards the Chrome DevTools Protocol domains allowed by `chrome.debugger`, including `Runtime` and `Page`.

## Release

```bash
scripts/build-app.sh VERSION
gh release create vVERSION build/AutoClickCDPPopup-VERSION.zip --title "cdpclick VERSION"
```

Calculate the published archive checksum and update both `version` and `sha256` in `Casks/cdpclick.rb`:

```bash
shasum -a 256 build/AutoClickCDPPopup-VERSION.zip
```

Run the Cask checks, then commit and push the Cask update:

```bash
brew style Casks/cdpclick.rb
brew audit --cask --strict schroneko/cdpclick/cdpclick
```

Consumers should run `brew update`, `brew upgrade --cask --no-ask schroneko/cdpclick/cdpclick`, and `cdpclick-install-agent` to receive the release. After installation, verify `brew list --cask --versions cdpclick`, the Caskroom version directory, the app bundle version, and the running process before reporting the update complete.

## Build

```bash
swift test
swift build -c release
```

## License

MIT
