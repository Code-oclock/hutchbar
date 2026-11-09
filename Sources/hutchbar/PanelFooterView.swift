// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Thin status line at the bottom of the panel: Claude hooks state (with install/copy links
/// while they are missing or stale) and a link to Settings.
struct PanelFooterView: View {
  let hooksStatus: HooksStatus
  let onInstallHooks: () -> Void
  let onCopyHooks: () -> Void
  let copied: Bool
  var onOpenSettings: (() -> Void)?

  init(
    hooksStatus: HooksStatus,
    onInstallHooks: @escaping () -> Void = {},
    onCopyHooks: @escaping () -> Void,
    copied: Bool,
    onOpenSettings: (() -> Void)? = nil
  ) {
    self.hooksStatus = hooksStatus
    self.onInstallHooks = onInstallHooks
    self.onCopyHooks = onCopyHooks
    self.copied = copied
    self.onOpenSettings = onOpenSettings
  }

  init(
    hooksInstalled: Bool,
    onInstallHooks: @escaping () -> Void = {},
    onCopyHooks: @escaping () -> Void,
    copied: Bool,
    onOpenSettings: (() -> Void)? = nil
  ) {
    self.init(
      hooksStatus: hooksInstalled ? .installed : .notInstalled,
      onInstallHooks: onInstallHooks,
      onCopyHooks: onCopyHooks,
      copied: copied,
      onOpenSettings: onOpenSettings
    )
  }

  // Plain buttons tinted like links: `.buttonStyle(.link)` is an AppKit control
  // that `ImageRenderer` (`--render-panel`) cannot draw.
  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(dotColor)
        .frame(width: 6, height: 6)

      Text(statusText)
        .font(.caption)
        .foregroundStyle(.secondary)

      if hooksStatus == .notInstalled || hooksStatus == .stale {
        Button(action: onInstallHooks) {
          Text(L10n.installHooks())
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
      }

      if hooksStatus != .installed {
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

  private var dotColor: Color {
    hooksStatus == .installed ? Color.green : Color.orange
  }

  private var statusText: String {
    switch hooksStatus {
    case .installed:
      return L10n.hooksInstalled()
    case .notInstalled:
      return L10n.hooksNotInstalled()
    case .stale:
      return L10n.hooksStale()
    case .unreadable:
      return L10n.hooksUnreadable()
    }
  }
}
