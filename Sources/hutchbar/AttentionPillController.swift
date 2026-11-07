// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import HutchbarCore

/// Owns the attention pill panel. See docs/specs/ui-v0.1.md, "Attention pill".
/// Stub — replaced by the pill implementation.
@MainActor
final class AttentionPillController {
  private let store: SessionStore
  private let onJump: @MainActor (SessionSnapshot) -> Void

  init(store: SessionStore, onJump: @escaping @MainActor (SessionSnapshot) -> Void) {
    self.store = store
    self.onJump = onJump
  }

  /// Re-evaluates AttentionPolicy; called by the app after each store update and on a 5 s timer.
  func evaluate(now: Date, thresholdSeconds: TimeInterval?) {}

  /// Hides the pill and releases its window.
  func stop() {}
}
