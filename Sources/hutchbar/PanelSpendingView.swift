// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Spending card displaying aggregate token expenditures and provider breakdown.
struct PanelSpendingView: View {
  let usage: UsageViewModel

  var body: some View {
    PanelCardView {
      HStack {
        Text(L10n.spendingTitle())
          .font(.subheadline)
          .fontWeight(.semibold)
        Spacer()
      }

      if let summary = currentSummary, hasSpendingData(summary) {
        spendingContent(summary: summary)
      } else {
        emptySpendingState
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var currentSummary: UsageSummary? {
    usage.ledger?.summary(period: usage.period, now: Date(), calendar: .current)
  }

  private func hasSpendingData(_ summary: UsageSummary) -> Bool {
    summary.costUSD > 0 || summary.tokens.total > 0
  }

  @ViewBuilder
  private func spendingContent(summary: UsageSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(PanelV2Logic.formatCurrency(amount: summary.costUSD))
          .font(.system(size: 26, weight: .bold, design: .rounded))

        Text(L10n.atApiPrices())
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 6) {
        Image(systemName: "asterisk")
          .font(.caption2)
          .foregroundStyle(.orange)
        Text(summary.spendingText(for: .claudeCode))

        Text("·")
          .foregroundStyle(.secondary)

        Image(systemName: "hexagon")
          .font(.caption2)
          .foregroundStyle(.blue)
        Text(summary.spendingText(for: .codex))
      }
      .font(.caption)
      .fontWeight(.medium)

      Text(
        PanelV2Logic.formatTokenAndCacheSummary(
          tokens: summary.tokens.total,
          cachedShare: summary.cachedShare
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if summary.hasUnknownModels {
        HStack(spacing: 4) {
          Image(systemName: "info.circle")
          Text("+ \(L10n.modelsWithoutPrice())")
        }
        .font(.caption2)
        .foregroundStyle(.orange)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(PanelV2Logic.formatCurrency(amount: summary.costUSD)) \(L10n.atApiPrices()), "
        + "\(PanelV2Logic.formatTokenAndCacheSummary(tokens: summary.tokens.total, cachedShare: summary.cachedShare))"
    )
  }

  private var emptySpendingState: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L10n.emptySpending())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }
}
