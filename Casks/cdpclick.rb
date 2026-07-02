cask "cdpclick" do
  version "1.0.0"
  sha256 "695249b81dfce50b91ac0b6390191fa19ea2ba1a7edda1ba59d178f0f9da7b77"

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
    Re-grant it after every upgrade because the ad-hoc code signature changes.
  EOS
end
