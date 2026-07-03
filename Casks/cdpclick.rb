cask "cdpclick" do
  version "1.0.2"
  sha256 "17d9a633fecf09921a47609f34dea589dab900b7a7383ec9dabbb0be1a4fd46d"

  url "https://github.com/schroneko/homebrew-cdpclick/releases/download/v#{version}/AutoClickCDPPopup-#{version}.zip"
  name "Auto Click CDP Popup"
  desc "Accessibility watcher that accepts Chrome remote debugging prompts"
  homepage "https://github.com/schroneko/homebrew-cdpclick"

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
