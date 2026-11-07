// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Two-column layout presenting quota utilization cards for Claude and Codex.
struct PanelQuotasView: View {
  let presentation: QuotaPresentation

  var body: some View {
    if presentation.cards.isEmpty {
      PanelCardView {
        HStack {
          Image(systemName: "speedometer")
            .foregroundStyle(.secondary)
          Text(L10n.emptyQuotas())
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.vertical, 8)
      }
    } else {
      HStack(alignment: .top, spacing: 10) {
        if let claudeCard = presentation.card(for: .claudeCode) {
          ProviderQuotaCardView(card: claudeCard)
        }
        if let codexCard = presentation.card(for: .codex) {
          ProviderQuotaCardView(card: codexCard)
        }
      }
    }
  }
}

/// A single quota card for an agent provider (Claude or Codex).
private struct ProviderQuotaCardView: View {
  let card: ProviderQuotaCard

  var body: some View {
    PanelCardView {
      cardHeader

      VStack(spacing: 8) {
        ForEach(card.windows.prefix(2)) { window in
          QuotaWindowRowView(window: window)
        }
      }

      if !card.secondaryAccounts.isEmpty {
        Divider()
          .padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 3) {
          ForEach(card.secondaryAccounts) { sec in
            Text(sec.compactString)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var cardHeader: some View {
    HStack(spacing: 6) {
      Image(systemName: agentIcon)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(agentColor)

      Text(providerTitle)
        .font(.subheadline)
        .fontWeight(.semibold)

      if !card.primaryAccountName.isEmpty {
        Text(card.primaryAccountName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if let plan = card.planBadge, !plan.isEmpty {
        Text(plan)
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.secondary.opacity(0.15)))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var agentIcon: String {
    switch card.agent {
    case .claudeCode:
      return "asterisk"
    case .codex:
      return "hexagon"
    }
  }

  private var agentColor: Color {
    PanelV2Logic.agentColor(for: card.agent).color
  }

  private var providerTitle: String {
    switch card.agent {
    case .claudeCode:
      return "Claude"
    case .codex:
      return "Codex"
    }
  }
}

/// Visual row for a single quota window with countdown and remaining bar.
private struct QuotaWindowRowView: View {
  let window: WindowPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(window.label)
          .font(.caption)
          .fontWeight(.medium)

        Text("↻ \(window.resetsInText)")
          .font(.caption2)
          .foregroundStyle(.secondary)

        Spacer()

        Text(window.remainingText)
          .font(.caption)
          .fontWeight(.bold)
          .foregroundStyle(window.isStale ? .secondary : .primary)
      }

      GeometryReader { geo in
        let width = geo.size.width
        let clamped = min(max(window.remainingPercent, 0.0), 100.0) / 100.0
        let barColor = PanelV2Logic.quotaBarColor(
          remainingPercent: window.remainingPercent,
          isStale: window.isStale
        ).color

        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.secondary.opacity(0.18))

          Capsule()
            .fill(barColor)
            .frame(width: max(0, width * CGFloat(clamped)))

          if let pace = window.pace, !window.isStale {
            let paceX = min(max(width * CGFloat(pace), 0), width)
            Rectangle()
              .fill(Color.primary.opacity(0.75))
              .frame(width: 1.5, height: 8)
              .offset(x: paceX)
          }
        }
      }
      .frame(height: 6)

      if window.isStale {
        Text(L10n.noFreshData())
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(window.label), \(window.remainingText), reset \(window.resetsInText)")
  }
}
