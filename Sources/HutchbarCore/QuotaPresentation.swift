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
  public var id: String {
    "\(windowMinutes)_\(label)"
  }
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
    isStale: Bool = false,
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

/// Formatted representation of one account's quotas under a provider.
public struct AccountQuotaPresentation: Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let planBadge: String?
  public let resetCreditsText: String?
  public let isCurrent: Bool
  public let observedAt: Date
  public let windows: [WindowPresentation]
  public let windowGroups: [QuotaWindowGroupPresentation]
  public let asOfText: String?

  public var isStale: Bool { asOfText != nil }
  public var accountName: String { name }

  public init(
    id: String,
    name: String,
    planBadge: String? = nil,
    resetCreditsText: String? = nil,
    isCurrent: Bool = false,
    observedAt: Date,
    windows: [WindowPresentation],
    windowGroups: [QuotaWindowGroupPresentation] = [],
    asOfText: String? = nil
  ) {
    self.id = id
    self.name = name
    self.planBadge = planBadge
    self.resetCreditsText = resetCreditsText
    self.isCurrent = isCurrent
    self.observedAt = observedAt
    self.windows = windows
    if windowGroups.isEmpty && !windows.isEmpty {
      self.windowGroups = [QuotaWindowGroupPresentation(scope: nil, windows: windows)]
    } else {
      self.windowGroups = windowGroups
    }
    self.asOfText = asOfText
  }
}

/// Visual card presentation for a single provider (Claude Code or Codex).
public struct ProviderQuotaCard: Equatable, Sendable, Identifiable {
  public var id: String { agent.rawValue }
  public let agent: AgentKind
  /// Accounts read on this Mac directly from the agent (its CLI, app or session logs).
  public let accounts: [AccountQuotaPresentation]
  /// Accounts seen only through a gateway (ccr), shown apart and collapsed; may repeat
  /// a direct account, since a gateway cannot tell which subscription it is.
  public let gateways: [GatewayQuotaGroup]

  public var primaryAccountName: String { accounts.first?.name ?? "" }
  public var secondaryAccounts: [AccountQuotaPresentation] { Array(accounts.dropFirst()) }
  public var windows: [WindowPresentation] { accounts.first?.windows ?? [] }
  public var planBadge: String? { accounts.first?.planBadge }
  public var observedAt: Date { accounts.first?.observedAt ?? .distantPast }
  public var isStale: Bool { accounts.first?.isStale ?? false }

  public init(
    agent: AgentKind, accounts: [AccountQuotaPresentation], gateways: [GatewayQuotaGroup] = []
  ) {
    self.agent = agent
    self.accounts = accounts
    self.gateways = gateways
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
      let agentQuotas = quotas.filter { $0.agent == agent }
      guard !agentQuotas.isEmpty else { continue }

      let directQuotas = agentQuotas.filter { $0.source.gatewayName == nil }
      let gateways = Self.buildGatewayGroups(
        agent: agent, quotas: agentQuotas, now: now, timeZone: timeZone, language: language)
      let accounts = Self.buildAccounts(
        agent: agent,
        quotas: directQuotas,
        now: now,
        timeZone: timeZone,
        language: language,
        // Without gateways the newest reading may stand for "now"; with them, a direct
        // account is "now" only on real evidence (its session log).
        guessCurrent: gateways.isEmpty
      )
      guard !accounts.isEmpty || !gateways.isEmpty else { continue }

      cardList.append(ProviderQuotaCard(agent: agent, accounts: accounts, gateways: gateways))
    }

    self.cards = cardList
  }

  public func card(for agent: AgentKind) -> ProviderQuotaCard? {
    cards.first { $0.agent == agent }
  }

  // MARK: - Calculations

  public static func evaluateLevel(for remainingPercent: Double) -> QuotaBarLevel {
    if remainingPercent < 10.0 { return .critical }
    if remainingPercent < 20.0 { return .warning }
    return .normal
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

  public static func formatPlanBadge(_ plan: String) -> String {
    let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
  }

  public static func formatLabel(
    windowMinutes: Int,
    scope: String?,
    language: L10n.Language
  ) -> String {
    let base = L10n.quotaWindowName(minutes: windowMinutes, language: language)
    if let scope, !scope.isEmpty {
      return "\(base) · \(scope)"
    }
    return base
  }

  public static func makeWindowPresentation(
    window: QuotaWindow,
    now: Date,
    language: L10n.Language,
    includeScopeInLabel: Bool = true
  ) -> WindowPresentation {
    let label = formatLabel(
      windowMinutes: window.windowMinutes,
      scope: includeScopeInLabel ? window.scope : nil,
      language: language
    )

    if let resetsAt = window.resetsAt, resetsAt <= now {
      return WindowPresentation(
        windowMinutes: window.windowMinutes, label: label, remainingPercent: 100.0,
        remainingText: L10n.remainingPercent(100, language: language),
        resetsInText: L10n.updatesOnNextRequest(language: language),
        resetsAt: resetsAt, pace: nil, isStale: false, level: .normal
      )
    }

    let isNotStarted: Bool
    if window.usedPercent == 0 {
      if let resetsAt = window.resetsAt {
        let windowDuration = TimeInterval(window.windowMinutes * 60)
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        isNotStarted = timeUntilReset >= (windowDuration - 120.0)
      } else {
        isNotStarted = true
      }
    } else {
      isNotStarted = false
    }

    if isNotStarted {
      return WindowPresentation(
        windowMinutes: window.windowMinutes, label: label, remainingPercent: 100.0,
        remainingText: L10n.remainingPercent(100, language: language),
        resetsInText: L10n.notStarted(language: language),
        resetsAt: window.resetsAt, pace: nil, isStale: false, level: .normal
      )
    }

    let remaining = max(0.0, min(100.0, 100.0 - window.usedPercent))
    let remainingInt = Int(remaining.rounded())
    let remText = L10n.remainingPercent(remainingInt, language: language)
    let pace = calculatePace(
      resetsAt: window.resetsAt,
      windowMinutes: window.windowMinutes,
      now: now
    )
    let level = evaluateLevel(for: remaining)

    let resetsText: String
    if let resetsAt = window.resetsAt, resetsAt > now {
      resetsText = L10n.countdown(from: resetsAt, now: now, language: language)
    } else {
      resetsText = L10n.updatesOnNextRequest(language: language)
    }

    return WindowPresentation(
      windowMinutes: window.windowMinutes, label: label, remainingPercent: remaining,
      remainingText: remText, resetsInText: resetsText, resetsAt: window.resetsAt,
      pace: pace, isStale: false, level: level
    )
  }
}

// MARK: - Account Merging & Construction

extension QuotaPresentation {
  private struct MergedCluster {
    let group: [AccountQuota]
    let name: String
    let numbersRecord: AccountQuota
    let plan: String?
    let resetCredits: Int?
    let latestRealWorkDate: Date?
  }

  private static func canMerge(_ lhs: AccountQuota, _ rhs: AccountQuota) -> Bool {
    guard lhs.agent == rhs.agent else { return false }
    guard
      let lhsWeek = lhs.windows.first(where: { $0.windowMinutes == 10080 && $0.scope == nil }),
      let rhsWeek = rhs.windows.first(where: { $0.windowMinutes == 10080 && $0.scope == nil }),
      let lhsReset = lhsWeek.resetsAt,
      let rhsReset = rhsWeek.resetsAt
    else {
      return false
    }
    return abs(lhsReset.timeIntervalSince(rhsReset)) <= 60.0
  }

  private static func clusterQuotas(_ quotas: [AccountQuota]) -> [[AccountQuota]] {
    var groups: [[AccountQuota]] = []
    for quota in quotas {
      var matchingIndices: [Int] = []
      for (idx, group) in groups.enumerated() {
        if group.contains(where: { canMerge($0, quota) }) {
          matchingIndices.append(idx)
        }
      }
      if matchingIndices.isEmpty {
        groups.append([quota])
      } else {
        var combined: [AccountQuota] = [quota]
        for idx in matchingIndices.reversed() {
          combined.append(contentsOf: groups.remove(at: idx))
        }
        groups.append(combined)
      }
    }
    return groups
  }

  private static func resolveClusterName(_ group: [AccountQuota]) -> String {
    let ccrRecords = group.filter { $0.source == .ccr }
    if let bestCcr = ccrRecords.max(by: { $0.observedAt < $1.observedAt }) {
      return bestCcr.accountName
    }
    let cliRecords = group.filter { $0.source == .agentCLI }
    if let bestCli = cliRecords.max(by: { $0.observedAt < $1.observedAt }) {
      return bestCli.accountName
    }
    let bestOther = group.max(by: { $0.observedAt < $1.observedAt })
    return bestOther?.accountName ?? "unknown"
  }

  private static func resolveClusterPlan(_ group: [AccountQuota]) -> String? {
    let cliRecords = group.filter {
      $0.source == .agentCLI && $0.plan != nil && !($0.plan?.isEmpty ?? true)
    }
    if let plan = cliRecords.max(by: { $0.observedAt < $1.observedAt })?.plan {
      return plan
    }
    let anyRecords = group.filter { $0.plan != nil && !($0.plan?.isEmpty ?? true) }
    return anyRecords.max(by: { $0.observedAt < $1.observedAt })?.plan
  }

  private static func resolveClusterCredits(_ group: [AccountQuota]) -> Int? {
    let cliRecords = group.filter { $0.source == .agentCLI && $0.resetCredits != nil }
    if let credits = cliRecords.max(by: { $0.observedAt < $1.observedAt })?.resetCredits {
      return credits
    }
    let anyRecords = group.filter { $0.resetCredits != nil }
    return anyRecords.max(by: { $0.observedAt < $1.observedAt })?.resetCredits
  }

  /// The account in real use: newest `.sessionLog` / `.ccr` reading; else the newest reading.
  private static func selectCurrentClusterName(_ clusters: [MergedCluster], guess: Bool)
    -> String?
  {
    let hasAnyRealWork = clusters.contains { $0.latestRealWorkDate != nil }
    if !hasAnyRealWork && !guess { return nil }
    if hasAnyRealWork {
      return clusters.max(by: { lhs, rhs in
        let lhsDate = lhs.latestRealWorkDate ?? .distantPast
        let rhsDate = rhs.latestRealWorkDate ?? .distantPast
        if lhsDate != rhsDate {
          return lhsDate < rhsDate
        }
        if lhs.numbersRecord.observedAt != rhs.numbersRecord.observedAt {
          return lhs.numbersRecord.observedAt < rhs.numbersRecord.observedAt
        }
        return lhs.name > rhs.name
      })?.name
    } else {
      return clusters.max(by: { lhs, rhs in
        if lhs.numbersRecord.observedAt != rhs.numbersRecord.observedAt {
          return lhs.numbersRecord.observedAt < rhs.numbersRecord.observedAt
        }
        return lhs.name > rhs.name
      })?.name
    }
  }

  static func buildAccounts(
    agent: AgentKind,
    quotas: [AccountQuota],
    now: Date,
    timeZone: TimeZone,
    language: L10n.Language,
    mergeByReset: Bool = true,
    guessCurrent: Bool = true
  ) -> [AccountQuotaPresentation] {
    let rawGroups = mergeByReset ? clusterQuotas(quotas) : quotas.map { [$0] }
    guard !rawGroups.isEmpty else { return [] }

    var clusters: [MergedCluster] = []
    clusters.reserveCapacity(rawGroups.count)

    for group in rawGroups {
      let chosenName = resolveClusterName(group)
      let numbersRecord = group.max(by: { $0.observedAt < $1.observedAt }) ?? group[0]
      let chosenPlan = resolveClusterPlan(group)
      let chosenCredits = resolveClusterCredits(group)
      let realWorkDates = group.filter { $0.source == .sessionLog || $0.source == .ccr }.map(
        \.observedAt)
      let latestRealWork = realWorkDates.max()

      clusters.append(
        MergedCluster(
          group: group,
          name: chosenName,
          numbersRecord: numbersRecord,
          plan: chosenPlan,
          resetCredits: chosenCredits,
          latestRealWorkDate: latestRealWork
        )
      )
    }

    let currentClusterName = selectCurrentClusterName(clusters, guess: guessCurrent)

    var result: [AccountQuotaPresentation] = []
    result.reserveCapacity(clusters.count)

    for cluster in clusters {
      let isCurrent = cluster.name == currentClusterName
      let planBadge = cluster.plan.flatMap { plan -> String? in
        let formatted = formatPlanBadge(plan)
        return formatted.isEmpty ? nil : formatted
      }

      let resetCreditsText = cluster.resetCredits.flatMap { credits -> String? in
        credits > 0 ? L10n.resetCredits(credits, language: language) : nil
      }

      let isStale =
        (cluster.numbersRecord.source != .agentCLI)
        && (now.timeIntervalSince(cluster.numbersRecord.observedAt) > 7200.0)

      let asOfText: String?
      if isStale {
        let timeStr = asOfMoment(
          cluster.numbersRecord.observedAt, now: now, timeZone: timeZone, language: language)
        asOfText = L10n.dataAsOf(timeStr, language: language)
      } else {
        asOfText = nil
      }

      let sortedWindows = sortQuotaWindows(cluster.numbersRecord.windows)
      let windows = sortedWindows.map { window in
        makeWindowPresentation(window: window, now: now, language: language)
      }
      let groups = buildWindowGroups(
        rawWindows: cluster.numbersRecord.windows,
        now: now,
        language: language
      )

      result.append(
        AccountQuotaPresentation(
          id: "\(agent.rawValue):\(cluster.name)",
          name: cluster.name,
          planBadge: planBadge,
          resetCreditsText: resetCreditsText,
          isCurrent: isCurrent,
          observedAt: cluster.numbersRecord.observedAt,
          windows: windows,
          windowGroups: groups,
          asOfText: asOfText
        )
      )
    }

    result.sort { lhs, rhs in
      if lhs.isCurrent != rhs.isCurrent {
        return lhs.isCurrent && !rhs.isCurrent
      }
      return lhs.name < rhs.name
    }

    return result
  }
}
