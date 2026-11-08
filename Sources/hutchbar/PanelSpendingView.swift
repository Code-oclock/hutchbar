// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Spending card displaying aggregate token expenditures and provider breakdown.
struct PanelSpendingView: View {
  let usage: UsageViewModel

  init(usage: UsageViewModel) {
    self.usage = usage
  }

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
    let rows = PanelV2Logic.agentSpendingRows(summary: summary)

    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(PanelV2Logic.formatCurrency(amount: summary.costUSD))
          .font(.system(size: 26, weight: .bold, design: .rounded))

        Text(L10n.atApiPrices())
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if !rows.isEmpty {
        VStack(spacing: 4) {
          ForEach(rows) { row in
            agentRow(row)
          }
        }
      }

      Text(PanelV2Logic.formatCacheSummary(cachedShare: summary.cachedShare))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilitySummary(summary: summary, rows: rows))
  }

  private func agentRow(_ row: AgentSpendingRow) -> some View {
    HStack(spacing: 6) {
      Image(systemName: row.icon)
        .font(.caption2)
        .fontWeight(.bold)
        .foregroundStyle(row.colorToken.color)
        .frame(width: 12)

      Text(row.name)
        .font(.caption)
        .fontWeight(.medium)

      Spacer()

      Text(row.tokenText)
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 3) {
        Text(row.costText)
          .font(.caption)
          .fontWeight(.medium)

        if let note = row.costNote {
          Text(note)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func accessibilitySummary(
    summary: UsageSummary,
    rows: [AgentSpendingRow]
  ) -> String {
    let mainCost = "\(PanelV2Logic.formatCurrency(amount: summary.costUSD)) \(L10n.atApiPrices())"
    let cacheText = PanelV2Logic.formatCacheSummary(cachedShare: summary.cachedShare)
    let details = rows.map { row in
      let costDisplay = row.costNote.map { "\(row.costText) \($0)" } ?? row.costText
      return "\(row.name): \(row.tokenText), \(costDisplay)"
    }.joined(separator: "; ")
    if details.isEmpty {
      return "\(mainCost), \(cacheText)"
    }
    return "\(mainCost), \(details), \(cacheText)"
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
