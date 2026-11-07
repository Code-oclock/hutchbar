// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import HutchbarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Hutchbar")
    let menu = NSMenu()
    let about = menu.addItem(
      withTitle: "About Hutchbar", action: #selector(showAbout), keyEquivalent: "")
    about.target = self
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit Hutchbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    item.menu = menu
    statusItem = item
  }

  @objc private func showAbout() {
    NSApplication.shared.orderFrontStandardAboutPanel(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }
}

@main
struct HutchbarApp {
  @MainActor static func main() {
    let arguments = CommandLine.arguments.dropFirst()
    if arguments.contains("--version") {
      print(HutchbarVersion.current)
      return
    }
    if arguments.contains("--selftest") {
      // Touch core models and the real filesystem adapter without starting AppKit.
      do {
        guard SessionState.allCases.count == 4,
          SessionState(rawValue: "waitingForApproval") == .waitingForApproval
        else { exit(1) }
        let reader = try JSONLTailReader(path: "/dev/null")
        reader.stop()
        print("hutchbar core selftest passed (\(HutchbarVersion.current))")
        return
      } catch {
        fputs("hutchbar core selftest failed\n", stderr)
        exit(1)
      }
    }
    guard arguments.isEmpty else {
      fputs("Usage: hutchbar [--selftest | --version]\n", stderr)
      exit(64)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
