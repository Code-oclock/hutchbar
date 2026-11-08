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

      periodSwitch

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

  /// Сегодня / Неделя / Месяц as a segmented control, drawn by hand: the AppKit
  /// segmented picker does not survive `ImageRenderer` (`--render-panel`).
  private var periodSwitch: some View {
    HStack(spacing: 0) {
      ForEach(UsagePeriod.allCases, id: \.self) { period in
        let isSelected = usage.period == period
        Button(action: { usage.period = period }) {
          Text(periodTitle(for: period))
            .font(.caption)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(isSelected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
    )
    .fixedSize()
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
