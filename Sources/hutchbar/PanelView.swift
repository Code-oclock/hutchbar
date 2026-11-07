// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Popover content: waiting queue, working sessions, quotas. See docs/specs/ui-v0.1.md.
/// Stub — replaced by the panel implementation.
struct PanelView: View {
  let store: SessionStore
  let onJump: @MainActor (SessionSnapshot) -> Void

  var body: some View {
    Text("Hutchbar")
      .padding()
  }
}
