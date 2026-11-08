// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import HutchbarCore
import SwiftUI

/// Debug/docs helper: `hutchbar --render-panel out.png` polls the sources once
/// and renders the panel to a PNG without showing any window.
@MainActor
enum PanelRenderer {
  static func render(to path: String, polls: Int = 40) async -> Bool {
    let store = SessionStore()
    let coordinator = SourceCoordinator()
    let updates = coordinator.updates
    let collector = Task { @MainActor in
      for await update in updates { store.apply(update, now: Date()) }
    }
    for _ in 0..<polls { await coordinator.pollOnce() }
    await coordinator.stop()
    await collector.value
    FileHandle.standardError.write(
      Data(
        "waiting=\(store.waiting.count) working=\(store.working.count) quotas=\(store.quotas.count)\n"
          .utf8))
    let content = PanelView(store: store, onJump: { _ in }, scrollable: false)
      .frame(width: 340)
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
