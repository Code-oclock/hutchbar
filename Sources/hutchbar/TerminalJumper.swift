// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import HutchbarCore

/// Brings the terminal of a session to the front.
/// v0.1 best effort: activates the first running terminal emulator from the supported list.
/// TODO: v0.2: Use AppleScript to match exact tty/session tab for iTerm2 and Terminal.app.
/// See docs/specs/ui-v0.1.md, "Jump to terminal (v0.1 best effort)".
@MainActor
enum TerminalJumper {
  /// Supported terminal bundle identifiers in priority order.
  static let supportedTerminalBundleIdentifiers: [String] = [
    "com.googlecode.iterm2",
    "com.apple.Terminal",
    "com.mitchellh.ghostty",
    "com.github.wez.wezterm",
    "dev.warp.Warp-Stable",
    "dev.warp.Warp",
  ]

  /// Brings the first running terminal emulator to the front.
  static func jump(to session: SessionSnapshot) {
    _ = session
    for bundleIdentifier in supportedTerminalBundleIdentifiers {
      let runningApps = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      )
      if let app = runningApps.first(where: { !$0.isTerminated }) {
        app.activate()
        return
      }
    }
  }
}
