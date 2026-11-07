// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Alert color level for quota remaining bar.
public enum QuotaBarLevel: String, Sendable, Equatable, CaseIterable {
  case normal
  case warning
  case critical
}

/// Formatted representation of a single rate-limit window.
public struct WindowPresentation: Equatable, Sendable, Identifiable {
  public var id: Int { windowMinutes }
  public let windowMinutes: Int
  public let label: String
  public let remainingPercent: Double
  public let remainingText: String
  public let resetsInText: String
  public let resetsAt: Date?
  public let pace: Double?
  public let isStale: Bool
  public let level: QuotaBarLevel

  public init(
    windowMinutes: Int,
    label: String,
    remainingPercent: Double,
    remainingText: String,
    resetsInText: String,
    resetsAt: Date?,
    pace: Double?,
    isStale: Bool,
    level: QuotaBarLevel
  ) {
    self.windowMinutes = windowMinutes
    self.label = label
    self.remainingPercent = remainingPercent
    self.remainingText = remainingText
    self.resetsInText = resetsInText
    self.resetsAt = resetsAt
    self.pace = pace
    self.isStale = isStale
    self.level = level
  }
}

/// Compact representation of a secondary (non-primary) account under the same provider.
public struct SecondaryAccountPresentation: Equatable, Sendable, Identifiable {
  public var id: String { accountName }
  public let accountName: String
  public let observedAt: Date
  public let compactString: String
  public let windows: [WindowPresentation]

  public init(
    accountName: String,
    observedAt: Date,
    compactString: String,
    windows: [WindowPresentation]
  ) {
    self.accountName = accountName
    self.observedAt = observedAt
    self.compactString = compactString
    self.windows = windows
  }
}

/// Visual card presentation for a single provider (Claude Code or Codex).
public struct ProviderQuotaCard: Equatable, Sendable, Identifiable {
  public var id: String { agent.rawValue }
  public let agent: AgentKind
  public let primaryAccountName: String
  public let observedAt: Date
  public let planBadge: String?
  public let windows: [WindowPresentation]
  public let secondaryAccounts: [SecondaryAccountPresentation]
  public let isStale: Bool

  public init(
    agent: AgentKind,
    primaryAccountName: String,
    observedAt: Date,
    planBadge: String?,
    windows: [WindowPresentation],
    secondaryAccounts: [SecondaryAccountPresentation],
    isStale: Bool
  ) {
    self.agent = agent
    self.primaryAccountName = primaryAccountName
    self.observedAt = observedAt
    self.planBadge = planBadge
    self.windows = windows
    self.secondaryAccounts = secondaryAccounts
    self.isStale = isStale
  }
}

/// Pure presentation model for all quotas, organized into provider cards.
public struct QuotaPresentation: Equatable, Sendable {
  public let cards: [ProviderQuotaCard]
  public let now: Date
  public let timeZone: TimeZone

  public init(cards: [ProviderQuotaCard], now: Date, timeZone: TimeZone = .current) {
    self.cards = cards
    self.now = now
    self.timeZone = timeZone
  }

  public init(
    quotas: [String: AccountQuota],
    now: Date,
    timeZone: TimeZone = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) {
    self.init(quotas: Array(quotas.values), now: now, timeZone: timeZone, language: language)
  }

  public init(
    quotas: [AccountQuota],
    now: Date,
    timeZone: TimeZone = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) {
    self.now = now
    self.timeZone = timeZone
    var cardList: [ProviderQuotaCard] = []

    for agent in AgentKind.allCases {
      let providerQuotas = quotas.filter { $0.agent == agent }
      guard !providerQuotas.isEmpty else { continue }

      let sorted = providerQuotas.sorted { lhs, rhs in
        if lhs.observedAt != rhs.observedAt {
          return lhs.observedAt > rhs.observedAt
        }
        return lhs.accountName < rhs.accountName
      }

      guard let primaryQuota = sorted.first else { continue }
      let secondaryQuotas = Array(sorted.dropFirst())

      let primaryWindows = primaryQuota.windows
        .sorted { $0.windowMinutes < $1.windowMinutes }
        .map { window in
          Self.makeWindowPresentation(
            window: window,
            observedAt: primaryQuota.observedAt,
            now: now,
            language: language
          )
        }

      let secondaryPresentations = secondaryQuotas.map { secQuota in
        let secWindows = secQuota.windows
          .sorted { $0.windowMinutes < $1.windowMinutes }
          .map { window in
            Self.makeWindowPresentation(
              window: window,
              observedAt: secQuota.observedAt,
              now: now,
              language: language
            )
          }

        let compact = Self.makeSecondaryCompactString(
          accountName: secQuota.accountName,
          windows: secWindows,
          now: now,
          timeZone: timeZone,
          language: language
        )

        return SecondaryAccountPresentation(
          accountName: secQuota.accountName,
          observedAt: secQuota.observedAt,
          compactString: compact,
          windows: secWindows
        )
      }

      let isCardStale = primaryWindows.isEmpty || primaryWindows.allSatisfy(\.isStale)

      cardList.append(
        ProviderQuotaCard(
          agent: agent,
          primaryAccountName: primaryQuota.accountName,
          observedAt: primaryQuota.observedAt,
          planBadge: nil,
          windows: primaryWindows,
          secondaryAccounts: secondaryPresentations,
          isStale: isCardStale
        )
      )
    }

    self.cards = cardList
  }

  public func card(for agent: AgentKind) -> ProviderQuotaCard? {
    cards.first { $0.agent == agent }
  }

  // MARK: - Calculations

  public static func evaluateLevel(for remainingPercent: Double) -> QuotaBarLevel {
    if remainingPercent < 10.0 {
      return .critical
    } else if remainingPercent < 20.0 {
      return .warning
    } else {
      return .normal
    }
  }

  public static func isWindowStale(
    window: QuotaWindow,
    observedAt: Date,
    now: Date
  ) -> Bool {
    let windowDuration = TimeInterval(window.windowMinutes * 60)
    if now.timeIntervalSince(observedAt) > windowDuration {
      return true
    }
    if let resetsAt = window.resetsAt, resetsAt < now {
      return true
    }
    return false
  }

  public static func calculatePace(
    resetsAt: Date?,
    windowMinutes: Int,
    now: Date
  ) -> Double? {
    guard let resetsAt, windowMinutes > 0 else { return nil }
    let windowLength = TimeInterval(windowMinutes * 60)
    let remainingTime = resetsAt.timeIntervalSince(now)
    let rawPace = 1.0 - (remainingTime / windowLength)
    return max(0.0, min(1.0, rawPace))
  }

  public static func makeWindowPresentation(
    window: QuotaWindow,
    observedAt: Date,
    now: Date,
    language: L10n.Language
  ) -> WindowPresentation {
    let remaining = max(0.0, min(100.0, 100.0 - window.usedPercent))
    let stale = isWindowStale(window: window, observedAt: observedAt, now: now)
    let pace = calculatePace(
      resetsAt: window.resetsAt, windowMinutes: window.windowMinutes, now: now)
    let label = L10n.quotaWindowName(minutes: window.windowMinutes, language: language)
    let remainingInt = Int(remaining.rounded())
    let remText = L10n.remainingPercent(remainingInt, language: language)

    let resetsText: String
    if stale {
      resetsText = L10n.noFreshData(language: language)
    } else if let resetsAt = window.resetsAt {
      resetsText = L10n.countdown(from: resetsAt, now: now, language: language)
    } else {
      resetsText = L10n.noFreshData(language: language)
    }

    let level = evaluateLevel(for: remaining)

    return WindowPresentation(
      windowMinutes: window.windowMinutes,
      label: label,
      remainingPercent: remaining,
      remainingText: remText,
      resetsInText: resetsText,
      resetsAt: window.resetsAt,
      pace: pace,
      isStale: stale,
      level: level
    )
  }

  public static func makeSecondaryCompactString(
    accountName: String,
    windows: [WindowPresentation],
    now: Date,
    timeZone: TimeZone = .current,
    language: L10n.Language
  ) -> String {
    let chosenWindow: WindowPresentation?
    if let week = windows.first(where: { $0.windowMinutes == 10080 }) {
      if let minWin = windows.min(by: { $0.remainingPercent < $1.remainingPercent }),
        minWin.remainingPercent < week.remainingPercent
      {
        chosenWindow = minWin
      } else {
        chosenWindow = week
      }
    } else {
      chosenWindow = windows.min(by: { $0.remainingPercent < $1.remainingPercent })
    }

    guard let chosen = chosenWindow else {
      return accountName
    }

    var parts: [String] = [accountName]
    let remainingInt = Int(chosen.remainingPercent.rounded())

    if remainingInt <= 0 {
      parts.append(
        L10n.windowUsedUp(
          windowName: chosen.label,
          minutes: chosen.windowMinutes,
          language: language
        )
      )
      if let resetFormatted = L10n.formatResetDate(
        chosen.resetsAt,
        now: now,
        calendar: Calendar(identifier: .gregorian),
        timeZone: timeZone,
        isUntil: true,
        language: language
      ) {
        parts.append(resetFormatted)
      }
    } else {
      parts.append(
        L10n.secondaryRemaining(
          windowName: chosen.label,
          percent: remainingInt,
          language: language
        )
      )
      if !chosen.isStale {
        parts.append("↻ \(chosen.resetsInText)")
      } else {
        parts.append(chosen.resetsInText)
      }
    }

    return parts.joined(separator: " · ")
  }
}
