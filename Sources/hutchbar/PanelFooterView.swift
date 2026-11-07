// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Footer view displayed when Claude Code hooks are not yet installed.
struct PanelFooterView: View {
  let hooksInstalled: Bool
  let onCopyHooks: () -> Void
  let copied: Bool

  var body: some View {
    if !hooksInstalled {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .font(.caption)

        Text(L10n.hooksNotInstalled())
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Button(action: onCopyHooks) {
          HStack(spacing: 4) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
            Text(copied ? L10n.copiedHooks() : L10n.copyHooks())
          }
          .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(L10n.hooksSnippetHint())
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.orange.opacity(0.1))
      )
    }
  }
}
