// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Semantic color token for the Hutchbar panel UI.
public enum PanelColorToken: String, Sendable, Equatable, CaseIterable {
  case orange
  case blue
  case red
  case green
  case purple
  case teal
  case secondary
}

/// Pure presentation and formatting logic for Panel v2.
public enum PanelV2Logic {

  // MARK: - Color Selection

  /// Returns the semantic color token for the given agent provider mark.
  public static func agentColor(for agent: AgentKind) -> PanelColorToken {
    agent.info.color
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

  /// Formats token counts into human-readable compact notation (e.g. 500, 12k, 1.5M, 12M or 4,2M with locale).
  public static func formatTokenCount(_ count: Int, locale: Locale? = nil) -> String {
    guard count > 0 else { return "0" }

    let separator = locale?.decimalSeparator ?? "."

    if count < 1_000 {
      return "\(count)"
    }

    if count < 1_000_000 {
      let thousands = Double(count) / 1_000.0
      if thousands >= 10.0 || (Double(count).truncatingRemainder(dividingBy: 1_000) == 0) {
        return "\(Int(thousands.rounded()))k"
      }
      let formatted = String(format: "%.1f", thousands)
      let localized = formatted.replacingOccurrences(of: ".", with: separator)
      return localized.replacingOccurrences(of: "\(separator)0", with: "") + "k"
    }

    let millions = Double(count) / 1_000_000.0
    if millions >= 10.0 || (Double(count).truncatingRemainder(dividingBy: 1_000_000) == 0) {
      return "\(Int(millions.rounded()))M"
    }
    let formatted = String(format: "%.1f", millions)
    let localized = formatted.replacingOccurrences(of: ".", with: separator)
    return localized.replacingOccurrences(of: "\(separator)0", with: "") + "M"
  }

  /// Formats cache summary line (e.g. «кэш 95 %» or «cache 95 %»).
  public static func formatCacheSummary(
    cachedShare: Double,
    language: L10n.Language = L10n.currentLanguage()
  ) -> String {
    let cacheWord = L10n.cache(language: language)
    let percent = Int((max(0.0, min(1.0, cachedShare)) * 100.0).rounded())
    return "\(cacheWord) \(percent) %"
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

  // MARK: - Agent Names and Icons

  /// Returns the display name for the agent provider ("Claude" / "Codex").
  public static func agentName(for agent: AgentKind) -> String {
    agent == .claudeCode ? "Claude" : "Codex"
  }

  /// Returns the SF Symbol name for the agent provider icon.
  public static func agentIcon(for agent: AgentKind) -> String {
    agent == .claudeCode ? "asterisk" : "hexagon"
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
    now: Date = Date(),
    calendar: Calendar = .current,
    timeZone: TimeZone = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) -> (leading: String, trailing: String) {
    let labels = trendAxisLabels(
      period: period,
      points: points,
      now: now,
      calendar: calendar,
      timeZone: timeZone,
      language: language
    )
    return (labels.leading.text, labels.trailing.text)
  }
}

// MARK: - Agent Spending Breakdown Extension

extension PanelV2Logic {
  /// Builds formatted spending breakdown rows for agents active in the reporting period.
  ///
  /// Only agents with total tokens > 0 are included.
  /// Rows are sorted by descending cost, with ties broken by descending total tokens,
  /// then by agent kind identifier.
  public static func agentSpendingRows(
    tokensByProvider: [AgentKind: TokenUsage],
    costByProvider: [AgentKind: Double],
    unknownTokensByProvider: [AgentKind: Int],
    locale: Locale = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) -> [AgentSpendingRow] {
    let activeAgents = AgentKind.allCases.filter { agent in
      (tokensByProvider[agent]?.total ?? 0) > 0
    }

    let sortedAgents = activeAgents.sorted { lhs, rhs in
      let lhsCost = costByProvider[lhs] ?? 0.0
      let rhsCost = costByProvider[rhs] ?? 0.0
      if lhsCost != rhsCost {
        return lhsCost > rhsCost
      }
      let lhsTokens = tokensByProvider[lhs]?.total ?? 0
      let rhsTokens = tokensByProvider[rhs]?.total ?? 0
      if lhsTokens != rhsTokens {
        return lhsTokens > rhsTokens
      }
      return lhs.rawValue < rhs.rawValue
    }

    return sortedAgents.map { agent in
      let totalTokens = tokensByProvider[agent]?.total ?? 0
      let unknownTokens = unknownTokensByProvider[agent] ?? 0
      let maybeCost = costByProvider[agent]

      let tokenText = formatTokenCount(totalTokens, locale: locale)
      let name = agentName(for: agent)
      let icon = agentIcon(for: agent)
      let colorToken = agentColor(for: agent)

      let costText: String
      let costNote: String?

      if maybeCost == nil || unknownTokens >= totalTokens {
        costText = "—"
        costNote = nil
      } else if let cost = maybeCost {
        costText = formatCurrency(amount: cost, locale: locale)
        if unknownTokens > 0 {
          costNote = L10n.plusWithoutPrice(language: language)
        } else {
          costNote = nil
        }
      } else {
        costText = "—"
        costNote = nil
      }

      return AgentSpendingRow(
        agent: agent,
        name: name,
        icon: icon,
        colorToken: colorToken,
        tokenCount: totalTokens,
        tokenText: tokenText,
        costUSD: maybeCost,
        costText: costText,
        costNote: costNote
      )
    }
  }

  /// Builds formatted spending breakdown rows for agents active in the usage summary.
  public static func agentSpendingRows(
    summary: UsageSummary,
    locale: Locale = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) -> [AgentSpendingRow] {
    agentSpendingRows(
      tokensByProvider: summary.tokensByProvider,
      costByProvider: summary.costByProvider,
      unknownTokensByProvider: summary.unknownTokensByProvider,
      locale: locale,
      language: language
    )
  }
}

// MARK: - Trend Axis Labels Extension

extension PanelV2Logic {
  /// Computes axis labels according to the separation rule:
  /// First and last labels are always displayed.
  /// Current point label is shown (as middle) only if it is separated from first and last
  /// by at least 3 positions.
  /// Otherwise, current replaces the closest extreme label (highlighted), and the extreme is hidden.
  public static func trendAxisLabels(
    period: UsagePeriod,
    points: [UsagePoint],
    now: Date = Date(),
    calendar: Calendar = .current,
    timeZone: TimeZone = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) -> TrendAxisLabels {
    guard !points.isEmpty else {
      let empty = TrendAxisLabel(text: "")
      return TrendAxisLabels(leading: empty, trailing: empty)
    }

    var cal = calendar
    cal.timeZone = timeZone

    if points.count == 1 {
      let text = formatPointDate(
        points[0].date,
        period: period,
        calendar: cal,
        timeZone: timeZone,
        language: language
      )
      let single = TrendAxisLabel(text: text, isCurrent: true)
      return TrendAxisLabels(leading: single, trailing: single)
    }

    let firstIndex = 0
    let lastIndex = points.count - 1

    let currentIndex: Int
    switch period {
    case .today:
      let currentHour = cal.component(.hour, from: now)
      if let hourIndex = points.firstIndex(where: {
        cal.component(.hour, from: $0.date) == currentHour
      }) {
        currentIndex = hourIndex
      } else {
        currentIndex = min(max(0, currentHour), lastIndex)
      }

    case .week, .month:
      if let dayIndex = points.firstIndex(where: { cal.isDate($0.date, inSameDayAs: now) }) {
        currentIndex = dayIndex
      } else {
        currentIndex = lastIndex
      }
    }

    let distFirst = currentIndex - firstIndex
    let distLast = lastIndex - currentIndex
    let isSeparated = distFirst >= 3 && distLast >= 3

    let formatLabel: (Int, Bool) -> TrendAxisLabel = { (pointIndex, isCurrent) in
      let text = formatPointDate(
        points[pointIndex].date,
        period: period,
        calendar: cal,
        timeZone: timeZone,
        language: language
      )
      return TrendAxisLabel(text: text, isCurrent: isCurrent)
    }

    if isSeparated {
      let leading = formatLabel(firstIndex, false)
      let middle = formatLabel(currentIndex, true)
      let trailing = formatLabel(lastIndex, false)
      return TrendAxisLabels(leading: leading, trailing: trailing, middle: middle)
    }

    if distFirst <= distLast {
      let leading = formatLabel(currentIndex, true)
      let trailing = formatLabel(lastIndex, false)
      return TrendAxisLabels(leading: leading, trailing: trailing, middle: nil)
    } else {
      let leading = formatLabel(firstIndex, false)
      let trailing = formatLabel(currentIndex, true)
      return TrendAxisLabels(leading: leading, trailing: trailing, middle: nil)
    }
  }

  /// Formats date of a usage point according to the selected reporting period.
  private static func formatPointDate(
    _ date: Date,
    period: UsagePeriod,
    calendar: Calendar,
    timeZone: TimeZone,
    language: L10n.Language
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: language == .ru ? "ru_RU" : "en_US_POSIX")

    switch period {
    case .today:
      formatter.dateFormat = "HH:mm"
      return formatter.string(from: date)

    case .week:
      formatter.dateFormat = "EEE"
      let text = formatter.string(from: date)
      if language == .ru {
        return text.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      }
      return text

    case .month:
      let dayNumber = calendar.component(.day, from: date)
      return "\(dayNumber)"
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
