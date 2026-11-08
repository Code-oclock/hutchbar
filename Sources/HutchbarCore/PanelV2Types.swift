// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A formatted row representing agent provider spending in Panel v2.
public struct AgentSpendingRow: Equatable, Sendable, Identifiable {
  public var id: AgentKind { agent }
  public let agent: AgentKind
  public let name: String
  public let icon: String
  public let colorToken: PanelColorToken
  public let tokenCount: Int
  public let tokenText: String
  public let costUSD: Double?
  public let costText: String
  public let costNote: String?

  public init(
    agent: AgentKind,
    name: String,
    icon: String,
    colorToken: PanelColorToken,
    tokenCount: Int,
    tokenText: String,
    costUSD: Double?,
    costText: String,
    costNote: String? = nil
  ) {
    self.agent = agent
    self.name = name
    self.icon = icon
    self.colorToken = colorToken
    self.tokenCount = tokenCount
    self.tokenText = tokenText
    self.costUSD = costUSD
    self.costText = costText
    self.costNote = costNote
  }
}

/// One label on the trend dynamics chart axis.
public struct TrendAxisLabel: Equatable, Sendable {
  public let text: String
  public let isCurrent: Bool

  public init(text: String, isCurrent: Bool = false) {
    self.text = text
    self.isCurrent = isCurrent
  }
}

/// The set of axis labels to display on the trend dynamics chart.
public struct TrendAxisLabels: Equatable, Sendable {
  public let leading: TrendAxisLabel
  public let trailing: TrendAxisLabel
  public let middle: TrendAxisLabel?

  public init(
    leading: TrendAxisLabel,
    trailing: TrendAxisLabel,
    middle: TrendAxisLabel? = nil
  ) {
    self.leading = leading
    self.trailing = trailing
    self.middle = middle
  }
}
