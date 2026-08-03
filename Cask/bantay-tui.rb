cask "bantay-tui" do
  version "0.1.0"
  sha256 "REPLACE_WITH_ZIP_SHA256"

  url "https://github.com/monozen/bantay-tui/releases/download/v#{version}/bantay-tui.zip"
  name "Bantay-TUI"
  desc "Agentic control plane in your MacBook notch"
  homepage "https://github.com/monozen/bantay-tui"

  auto_updates true

  app "Bantay-TUI.app"

  zap trash: [
    "~/Library/Application Support/Bantay-TUI",
    "~/Library/LaunchAgents/com.bantay-tui.agent.plist",
  ]
end
