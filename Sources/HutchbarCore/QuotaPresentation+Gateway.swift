// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension QuotaSource {
  /// The gateway a reading came through, or nil when it was read on this Mac directly.
  /// A gateway (ccr) knows its own account aliases, not which subscription each one is,
  /// so its accounts are never merged with the direct ones.
  public var gatewayName: String? {
    switch self {
    case .ccr: return "ccr"
    case .agentCLI, .sessionLog, .claudeApp, .serviceAPI: return nil
    }
  }
}

/// Accounts one gateway reported for an agent: a collapsed list under the direct accounts.
public struct GatewayQuotaGroup: Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let accounts: [AccountQuotaPresentation]

  /// True when one of the gateway's accounts is the one in use right now.
  public var hasCurrent: Bool { accounts.contains(where: \.isCurrent) }

  public init(id: String, name: String, accounts: [AccountQuotaPresentation]) {
    self.id = id
    self.name = name
    self.accounts = accounts
  }
}

extension QuotaPresentation {
  static func buildGatewayGroups(
    agent: AgentKind,
    quotas: [AccountQuota],
    now: Date,
    timeZone: TimeZone,
    language: L10n.Language
  ) -> [GatewayQuotaGroup] {
    let byGateway = Dictionary(grouping: quotas.filter { $0.source.gatewayName != nil }) {
      $0.source.gatewayName ?? ""
    }
    return byGateway.keys.sorted().compactMap { gateway in
      let accounts = buildAccounts(
        agent: agent,
        quotas: byGateway[gateway] ?? [],
        now: now,
        timeZone: timeZone,
        language: language,
        // Gateway aliases are distinct accounts even when their weeks reset together.
        mergeByReset: false
      )
      guard !accounts.isEmpty else { return nil }
      return GatewayQuotaGroup(
        id: "\(agent.rawValue):\(gateway)", name: gateway, accounts: accounts)
    }
  }

  /// "19:02" for today, "4 нояб. 19:02" / "4 Nov 19:02" for an older reading.
  static func asOfMoment(
    _ date: Date, now: Date, timeZone: TimeZone, language: L10n.Language
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: language == .ru ? "ru_RU" : "en_US_POSIX")
    formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
    return formatter.string(from: date)
  }

  /// General windows first, then scoped ones; within each, shorter windows first.
  static func sortQuotaWindows(_ rawWindows: [QuotaWindow]) -> [QuotaWindow] {
    rawWindows.sorted { lhs, rhs in
      let lhsHasScope = lhs.scope != nil && !(lhs.scope?.isEmpty ?? true)
      let rhsHasScope = rhs.scope != nil && !(rhs.scope?.isEmpty ?? true)
      if lhsHasScope != rhsHasScope {
        return !lhsHasScope && rhsHasScope
      }
      if lhs.windowMinutes != rhs.windowMinutes {
        return lhs.windowMinutes < rhs.windowMinutes
      }
      return (lhs.scope ?? "") < (rhs.scope ?? "")
    }
  }
}
