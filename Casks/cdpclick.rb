cask "cdpclick" do
  version "1.0.4"
  sha256 "459801bfbcc1d6a1168142e627d57383ba9c930354a8cfde201b523e1ee277dc"

  url "https://github.com/schroneko/homebrew-cdpclick/releases/download/v#{version}/AutoClickCDPPopup-#{version}.zip"
  name "Auto Click CDP Popup"
  desc "Accessibility watcher that accepts Chrome remote debugging prompts"
  homepage "https://github.com/schroneko/homebrew-cdpclick"

  depends_on :macos

  app "AutoClickCDPPopup.app"
  binary "#{appdir}/AutoClickCDPPopup.app/Contents/Resources/cdpclick-install-agent"
  binary "#{appdir}/AutoClickCDPPopup.app/Contents/Resources/cdpclick-uninstall-agent"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/AutoClickCDPPopup.app"],
                   sudo: false
  end

  uninstall launchctl: "com.schroneko.auto-click-cdp-popup",
            quit:      "com.schroneko.auto-click-cdp-popup"

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
