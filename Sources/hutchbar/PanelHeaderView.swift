// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Header bar of Panel v2 featuring the period switcher menu.
struct PanelHeaderView: View {
  let usage: UsageViewModel
  var onClose: (@MainActor () -> Void)?

  var body: some View {
    HStack {
      Text("hutchbar")
        .font(.headline)
        .fontWeight(.semibold)

      Spacer()

      Menu {
        Button(action: { usage.period = .today }) {
          Text(L10n.periodToday())
        }
        Button(action: { usage.period = .week }) {
          Text(L10n.periodWeek())
        }
        Button(action: { usage.period = .month }) {
          Text(L10n.periodMonth())
        }
      } label: {
        HStack(spacing: 4) {
          Text(periodTitle(for: usage.period))
          Text("▾")
            .font(.caption2)
        }
        .font(.subheadline)
        .fontWeight(.medium)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel(periodTitle(for: usage.period))

      if let onClose {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .accessibilityLabel("Close")
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
  }

  private func periodTitle(for period: UsagePeriod) -> String {
    switch period {
    case .today:
      return L10n.periodToday()
    case .week:
      return L10n.periodWeek()
    case .month:
      return L10n.periodMonth()
    }
  }
}
