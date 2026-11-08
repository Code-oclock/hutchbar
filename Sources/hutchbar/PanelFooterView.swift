// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Thin status line at the bottom of the panel: Claude hooks state (with a copy link
/// while they are missing) and a link to Settings.
struct PanelFooterView: View {
  let hooksInstalled: Bool
  let onCopyHooks: () -> Void
  let copied: Bool
  var onOpenSettings: (() -> Void)?

  // Plain buttons tinted like links: `.buttonStyle(.link)` is an AppKit control
  // that `ImageRenderer` (`--render-panel`) cannot draw.
  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(hooksInstalled ? Color.green : Color.orange)
        .frame(width: 6, height: 6)

      Text(hooksInstalled ? L10n.hooksInstalled() : L10n.hooksNotInstalled())
        .font(.caption)
        .foregroundStyle(.secondary)

      if !hooksInstalled {
        Button(action: onCopyHooks) {
          Text(copied ? L10n.copiedHooks() : L10n.copyHooks())
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(L10n.hooksSnippetHint())
        .accessibilityLabel(L10n.hooksSnippetHint())
      }

      Spacer()

      if let onOpenSettings {
        Button(action: onOpenSettings) {
          Text(L10n.openSettings())
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
  }
}
