// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Two-column layout presenting quota utilization cards for Claude and Codex.
struct PanelQuotasView: View {
  let presentation: QuotaPresentation

  init(presentation: QuotaPresentation) {
    self.presentation = presentation
  }

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

  init(card: ProviderQuotaCard) {
    self.card = card
  }

  var body: some View {
    PanelCardView {
      cardHeader

      VStack(spacing: 8) {
        ForEach(Array(card.accounts.enumerated()), id: \.element.id) { index, account in
          if index > 0 {
            Divider()
              .padding(.vertical, 2)
          }
          AccountQuotaBlockView(account: account)
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

      Spacer()
    }
  }

  private var agentIcon: String {
    card.agent.info.symbol
  }

  private var agentColor: Color {
    PanelV2Logic.agentColor(for: card.agent).color
  }

  private var providerTitle: String {
    card.agent.info.displayName
  }
}

/// A single account block showing account information and rate limit windows.
private struct AccountQuotaBlockView: View {
  let account: AccountQuotaPresentation

  init(account: AccountQuotaPresentation) {
    self.account = account
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      accountHeader

      VStack(spacing: 6) {
        ForEach(account.windows) { window in
          QuotaWindowRowView(window: window)
        }
      }
    }
  }

  private var accountHeader: some View {
    HStack(spacing: 4) {
      Text(account.name)
        .font(.caption)
        .fontWeight(.medium)
        .lineLimit(1)

      if let plan = account.planBadge, !plan.isEmpty {
        Text("·")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(plan)
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.secondary.opacity(0.15)))
          .foregroundStyle(.secondary)
      }

      if let credits = account.resetCreditsText, !credits.isEmpty {
        Text("·")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(credits)
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.secondary.opacity(0.15)))
          .foregroundStyle(.secondary)
      }

      Spacer()

      if account.isCurrent {
        Text(L10n.currentAccountNow())
          .font(.caption2)
          .fontWeight(.medium)
          .foregroundStyle(.green)
      } else if let asOf = account.asOfText {
        Text(asOf)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Visual row for a single quota window with countdown and remaining bar.
private struct QuotaWindowRowView: View {
  let window: WindowPresentation

  init(window: WindowPresentation) {
    self.window = window
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(window.label)
          .font(.caption)
          .fontWeight(.medium)

        Text(resetsText)
          .font(.caption2)
          .foregroundStyle(.secondary)

        Spacer()

        Text(window.remainingText)
          .font(.caption)
          .fontWeight(.bold)
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

          if let pace = window.pace {
            let paceX = min(max(width * CGFloat(pace), 0), width)
            Rectangle()
              .fill(Color.primary.opacity(0.75))
              .frame(width: 1.5, height: 8)
              .offset(x: paceX)
          }
        }
      }
      .frame(height: 6)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(window.label), \(window.remainingText), \(window.resetsInText)"
    )
  }

  private var resetsText: String {
    if window.pace == nil {
      return window.resetsInText
    }
    return "↻ \(window.resetsInText)"
  }
}
