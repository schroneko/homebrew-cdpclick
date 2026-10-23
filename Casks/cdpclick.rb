cask "cdpclick" do
  version "1.0.10"
  sha256 "f6af8f7724d247df20c89b51dc6bab52ebb048299b02a2a3a8a4fbe09eca61b9"

  url "https://github.com/schroneko/homebrew-cdpclick/releases/download/v#{version}/AutoClickCDPPopup-#{version}.zip"
  name "Auto Click CDP Popup"
  desc "Accessibility watcher that accepts Chrome remote debugging prompts"
  homepage "https://github.com/schroneko/homebrew-cdpclick"

  depends_on :macos

  app "AutoClickCDPPopup.app"
  installer script: {
    executable: "AutoClickCDPPopup.app/Contents/Resources/cdpclick-install-agent",
    args:       ["--prepare-install", "#{appdir}/AutoClickCDPPopup.app"],
    sudo:       false,
  }
  binary "#{appdir}/AutoClickCDPPopup.app/Contents/Resources/cdpclick-install-agent"
  binary "#{appdir}/AutoClickCDPPopup.app/Contents/Resources/cdpclick-uninstall-agent"

  preflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{staged_path}}/AutoClickCDPPopup.app"],
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
    The login agent is installed and started automatically after installation,
    upgrades, and reinstalls. It starts at login and restarts if it exits.

    AutoClickCDPPopup.app requires the macOS Accessibility permission.
    Grant it in System Settings > Privacy & Security > Accessibility.
    If macOS still reports missing permission after an upgrade, remove
    AutoClickCDPPopup.app from the Accessibility list and add it again.
  EOS
end
