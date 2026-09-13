cask "cdpclick" do
  version "1.0.7"
  sha256 "dee18447ca28e9eecf77a792ddf9e2035d2b4b4cfde00dbc7c3632c388ef58a6"

  url "https://github.com/schroneko/homebrew-cdpclick/releases/download/v#{version}/AutoClickCDPPopup-#{version}.zip"
  name "Auto Click CDP Popup"
  desc "Accessibility watcher that accepts Chrome remote debugging prompts"
  homepage "https://github.com/schroneko/homebrew-cdpclick"

  depends_on :macos

  app "AutoClickCDPPopup.app"
  binary "#{appdir}/AutoClickCDPPopup.app/Contents/Resources/cdpclick-install-agent"
  binary "#{appdir}/AutoClickCDPPopup.app/Contents/Resources/cdpclick-uninstall-agent"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/AutoClickCDPPopup.app"],
        sudo: false
  end

  uninstall quit:   "com.schroneko.auto-click-cdp-popup",
            script: {
              executable: "#{appdir}/AutoClickCDPPopup.app/Contents/Resources/cdpclick-uninstall-agent",
            }

  zap trash: [
    "~/Library/LaunchAgents/com.schroneko.auto-click-cdp-popup.plist",
    "~/Library/Logs/auto-click-cdp-popup",
  ]

  caveats <<~EOS
    Start the login agent with:
      cdpclick-install-agent

    AutoClickCDPPopup.app requires the macOS Accessibility permission.
    Grant it in System Settings > Privacy & Security > Accessibility.
    If macOS still reports missing permission after an upgrade, remove
    AutoClickCDPPopup.app from the Accessibility list and add it again.
  EOS
end
