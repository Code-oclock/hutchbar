// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Semantic color token for the Hutchbar panel UI.
public enum PanelColorToken: String, Sendable, Equatable, CaseIterable {
  case orange
  case blue
  case red
  case green
  case secondary
}

/// Pure presentation and formatting logic for Panel v2.
public enum PanelV2Logic {

  // MARK: - Color Selection

  /// Returns the semantic color token for the given agent provider mark.
  public static func agentColor(for agent: AgentKind) -> PanelColorToken {
    switch agent {
    case .claudeCode:
      return .orange
    case .codex:
      return .blue
    }
  }

  /// Returns the semantic color token for a session's current state.
  public static func sessionStateColor(for state: SessionState) -> PanelColorToken {
    switch state {
    case .waitingForApproval:
      return .orange
    case .waitingForInput:
      return .blue
    case .running, .finished:
      return .secondary
    }
  }

  /// Returns the color token for a quota remaining bar.
  public static func quotaBarColor(remainingPercent: Double, isStale: Bool) -> PanelColorToken {
    if isStale {
      return .secondary
    }
    if remainingPercent < 10.0 {
      return .red
    }
    if remainingPercent < 20.0 {
      return .orange
    }
    return .green
  }

  // MARK: - Session Sorting

  /// Sorts session snapshots according to Panel v2 rules:
  /// 1. waitingForApproval (longest waiting first)
  /// 2. waitingForInput (longest waiting first)
  /// 3. running (most recently active first)
  /// 4. finished (most recently active first)
  public static func sortSessions(_ sessions: [SessionSnapshot]) -> [SessionSnapshot] {
    sessions.sorted { lhs, rhs in
      let lhsRank = rank(for: lhs.state)
      let rhsRank = rank(for: rhs.state)
      if lhsRank != rhsRank {
        return lhsRank < rhsRank
      }

      switch lhs.state {
      case .waitingForApproval, .waitingForInput:
        let lhsSince = lhs.waitingSince ?? .distantFuture
        let rhsSince = rhs.waitingSince ?? .distantFuture
        if lhsSince != rhsSince {
          return lhsSince < rhsSince
        }
        return lhs.id < rhs.id

      case .running, .finished:
        if lhs.lastActivity != rhs.lastActivity {
          return lhs.lastActivity > rhs.lastActivity
        }
        return lhs.id < rhs.id
      }
    }
  }

  private static func rank(for state: SessionState) -> Int {
    switch state {
    case .waitingForApproval:
      return 0
    case .waitingForInput:
      return 1
    case .running:
      return 2
    case .finished:
      return 3
    }
  }

  // MARK: - Token Formatting

  /// Formats token counts into human-readable compact notation (e.g. 500, 12k, 1.5M, 12M).
  public static func formatTokenCount(_ count: Int) -> String {
    guard count > 0 else { return "0" }

    if count < 1_000 {
      return "\(count)"
    }

    if count < 1_000_000 {
      let thousands = Double(count) / 1_000.0
      if thousands >= 10.0 || (Double(count).truncatingRemainder(dividingBy: 1_000) == 0) {
        return "\(Int(thousands.rounded()))k"
      }
      let formatted = String(format: "%.1fk", thousands)
      return formatted.replacingOccurrences(of: ".0k", with: "k")
    }

    let millions = Double(count) / 1_000_000.0
    if millions >= 10.0 || (Double(count).truncatingRemainder(dividingBy: 1_000_000) == 0) {
      return "\(Int(millions.rounded()))M"
    }
    let formatted = String(format: "%.1fM", millions)
    return formatted.replacingOccurrences(of: ".0M", with: "M")
  }

  /// Formats the composite token and cache statistics line (e.g. «12M токенов · кэш 94 %»).
  public static func formatTokenAndCacheSummary(
    tokens: Int,
    cachedShare: Double,
    language: L10n.Language = L10n.currentLanguage()
  ) -> String {
    let tokenStr = formatTokenCount(tokens)
    let tokenWord = L10n.tokens(language: language)
    let cacheWord = L10n.cache(language: language)
    let percent = Int((max(0.0, min(1.0, cachedShare)) * 100.0).rounded())
    return "\(tokenStr) \(tokenWord) · \(cacheWord) \(percent) %"
  }

  // MARK: - Currency Formatting

  /// Formats currency amounts in USD taking the specified locale into account for decimal separators.
  public static func formatCurrency(
    amount: Double,
    locale: Locale = .current
  ) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = locale
    let formattedNumber =
      formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    return "$\(formattedNumber)"
  }

  // MARK: - Provider Spending Formatting

  /// Formats spending text for an agent provider according to pricing availability:
  /// - All cost unknown: «— · N токенов» / "— · N tokens"
  /// - Partially unknown: «$5,10 + модели без цены» / "$5.10 + models without price"
  /// - Fully known: «$5,10» / "$5.10"
  public static func providerSpendingText(
    cost: Double?,
    totalTokens: Int,
    unknownTokens: Int,
    locale: Locale = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) -> String {
    if totalTokens > 0 && (cost == nil || unknownTokens >= totalTokens) {
      let tokenStr = formatTokenCount(totalTokens)
      let tokenWord = L10n.tokens(language: language)
      return "— · \(tokenStr) \(tokenWord)"
    }
    if let cost {
      let costStr = formatCurrency(amount: cost, locale: locale)
      if unknownTokens > 0 {
        let mark = L10n.modelsWithoutPrice(language: language)
        return "\(costStr) + \(mark)"
      }
      return costStr
    }
    return formatCurrency(amount: 0.0, locale: locale)
  }

  // MARK: - Trend Axis Labels

  /// Returns the current hour component in 0...23 range.
  public static func currentHourIndex(
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> Int {
    calendar.component(.hour, from: now)
  }

  /// Formats an hour integer into HH:mm (e.g. 14 -> "14:00").
  public static func formatHourLabel(
    hour: Int
  ) -> String {
    String(format: "%02d:00", max(0, min(23, hour)))
  }

  /// Formats leading and trailing edge labels for the trend dynamics chart.
  public static func formatTrendAxisLabels(
    period: UsagePeriod,
    points: [UsagePoint],
    timeZone: TimeZone = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) -> (leading: String, trailing: String) {
    guard let first = points.first, let last = points.last else {
      return ("", "")
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: language == .ru ? "ru_RU" : "en_US_POSIX")

    switch period {
    case .today:
      formatter.dateFormat = "HH:mm"
      let leading = formatter.string(from: first.date)
      let trailing = formatter.string(from: last.date)
      return (leading, trailing)

    case .week:
      formatter.dateFormat = "d MMM"
      let leading = formatter.string(from: first.date)
      let trailing = L10n.periodToday(language: language)
      return (leading, trailing)

    case .month:
      formatter.dateFormat = "d MMM"
      let leading = formatter.string(from: first.date)
      let trailing = L10n.periodToday(language: language)
      return (leading, trailing)
    }
  }
}

// MARK: - L10n Extension

extension L10n {
  /// Label for unknown models without pricing data ("модели без цены" / "models without price").
  public static func modelsWithoutPrice(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru:
      return "модели без цены"
    case .en:
      return "models without price"
    }
  }
}
