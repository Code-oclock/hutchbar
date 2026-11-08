// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import HutchbarCore
import SwiftUI

/// Debug/docs helper: `hutchbar --render-panel out.png` polls the sources once
/// and renders the panel to a PNG without showing any window.
@MainActor
enum PanelRenderer {
  static func render(to path: String, polls: Int = 40) async -> Bool {
    _ = Settings()  // applies the stored interface language
    let store = SessionStore()
    TerminalJumper.pidLookup = { [weak store] session in store?.pid(for: session.sessionKey) }
    defer { TerminalJumper.pidLookup = nil }
    let coordinator = SourceCoordinator()
    let updates = coordinator.updates
    let collector = Task { @MainActor in
      for await update in updates { store.apply(update, now: Date()) }
    }
    for _ in 0..<polls { await coordinator.pollOnce() }
    await coordinator.stop()
    await collector.value

    // Ask every agent profile once (all targets are due right after creation).
    let targets = QuotaPoller.defaultTargets(appVersion: HutchbarVersion.current)
    let poller = QuotaPoller(targets: targets)
    let pollerUpdates = poller.updates
    let pollerCollector = Task { @MainActor in
      for await update in pollerUpdates { store.apply(update, now: Date()) }
    }
    for _ in targets { await poller.tick() }
    await poller.stop()
    await pollerCollector.value

    let scanner = UsageScanner()
    let ledger = await scanner.scanOnce()
    await scanner.stop()
    let usage = UsageViewModel(ledger: ledger)

    let nesting = ProcessNesting.children(
      sessions: store.allSessions,
      sessionPids: store.trackedPids,
      processes: DarwinProcessTable().allProcesses(),
      now: Date()
    )
    store.applyNesting(nesting)

    let statusMsg =
      "waiting=\(store.waiting.count) working=\(store.working.count) quotas=\(store.quotas.count)\n"
    FileHandle.standardError.write(Data(statusMsg.utf8))
    let content = PanelView(
      store: store,
      usage: usage,
      onJump: { _ in },
      onClose: nil,
      scrollable: false
    )
    .frame(width: 560)
    .background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.nsImage,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }
}
