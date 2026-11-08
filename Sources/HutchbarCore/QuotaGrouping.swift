// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Group of rate-limit windows belonging to the same scope (or unscoped).
public struct QuotaWindowGroupPresentation: Equatable, Sendable, Identifiable {
  public var id: String {
    scope ?? "__unscoped__"
  }
  public let scope: String?
  public let windows: [WindowPresentation]

  public init(scope: String?, windows: [WindowPresentation]) {
    self.scope = scope
    self.windows = windows
  }
}

/// Two columns of quota cards partitioned masonry-style.
public struct QuotaCardColumns: Equatable, Sendable {
  public let left: [ProviderQuotaCard]
  public let right: [ProviderQuotaCard]

  public init(left: [ProviderQuotaCard], right: [ProviderQuotaCard]) {
    self.left = left
    self.right = right
  }
}

extension ProviderQuotaCard {
  /// Simple estimate of window row count for masonry column layout.
  public var windowRowCount: Int {
    let count = accounts.reduce(0) { total, account in
      total + max(1, account.windows.count)
    }
    return max(1, count)
  }

  /// Window groups of the primary account, if any.
  public var windowGroups: [QuotaWindowGroupPresentation] {
    accounts.first?.windowGroups ?? []
  }
}

extension QuotaPresentation {
  /// Two columns of quota cards partitioned masonry-style by window row count.
  public var cardColumns: QuotaCardColumns {
    var leftCards: [ProviderQuotaCard] = []
    var rightCards: [ProviderQuotaCard] = []
    var leftRows = 0
    var rightRows = 0

    let sortedCards =
      cards
      .filter { !$0.accounts.isEmpty }
      .sorted { lhs, rhs in
        let lhsIndex = AgentKind.allCases.firstIndex(of: lhs.agent) ?? 0
        let rhsIndex = AgentKind.allCases.firstIndex(of: rhs.agent) ?? 0
        return lhsIndex < rhsIndex
      }

    for card in sortedCards {
      let cardRows = card.windowRowCount
      if leftRows <= rightRows {
        leftCards.append(card)
        leftRows += cardRows
      } else {
        rightCards.append(card)
        rightRows += cardRows
      }
    }

    return QuotaCardColumns(left: leftCards, right: rightCards)
  }

  /// Groups raw windows of an account by scope, ordering unscoped windows first,
  /// and ordering windows within each group 5-hour before weekly.
  public static func buildWindowGroups(
    rawWindows: [QuotaWindow],
    now: Date,
    language: L10n.Language
  ) -> [QuotaWindowGroupPresentation] {
    guard !rawWindows.isEmpty else { return [] }

    var groups: [QuotaWindowGroupPresentation] = []

    let unscoped = rawWindows.filter { $0.scope == nil || ($0.scope?.isEmpty ?? true) }
    if !unscoped.isEmpty {
      let sortedUnscoped = unscoped.sorted { $0.windowMinutes < $1.windowMinutes }
      let presentations = sortedUnscoped.map {
        makeWindowPresentation(
          window: $0,
          now: now,
          language: language,
          includeScopeInLabel: false
        )
      }
      groups.append(QuotaWindowGroupPresentation(scope: nil, windows: presentations))
    }

    let scoped = rawWindows.filter { $0.scope != nil && !($0.scope?.isEmpty ?? true) }
    if !scoped.isEmpty {
      let grouped = Dictionary(grouping: scoped, by: { $0.scope ?? "" })
      let sortedScopes = grouped.keys.sorted()
      for scopeName in sortedScopes {
        guard let scopeWindows = grouped[scopeName], !scopeWindows.isEmpty else { continue }
        let sortedGroupWindows = scopeWindows.sorted { $0.windowMinutes < $1.windowMinutes }
        let presentations = sortedGroupWindows.map {
          makeWindowPresentation(
            window: $0,
            now: now,
            language: language,
            includeScopeInLabel: false
          )
        }
        groups.append(QuotaWindowGroupPresentation(scope: scopeName, windows: presentations))
      }
    }

    return groups
  }
}
