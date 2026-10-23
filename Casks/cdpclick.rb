cask "cdpclick" do
  version "1.0.9"
  sha256 "a91262a55b367de99fb96ca35122f0a11a63053281d5a54c575cb43a37b4e4bf"

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
    run "{{appdir}}/AutoClickCDPPopup.app/Contents/Resources/cdpclick-install-agent",
        sudo:           false,
        writable_paths: [
          "Library/LaunchAgents",
          "Library/Logs/auto-click-cdp-popup",
          "Library/Application Support/Google/Chrome/NativeMessagingHosts",
        ],
        writable_base:  :home
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
