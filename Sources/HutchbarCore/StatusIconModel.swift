// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Alert level for the menu bar quota ring.
public enum StatusRingLevel: String, Sendable, Equatable, CaseIterable {
  case normal
  case warning
  case critical
}

/// Pure model describing the status icon in the menu bar.
public struct StatusIconModel: Equatable, Sendable {
  public static let warningThreshold: Double = 80.0
  public static let criticalThreshold: Double = 95.0

  public let text: String?
  public let ringPercent: Double?
  public let ringLevel: StatusRingLevel

  public init(text: String?, ringPercent: Double?, ringLevel: StatusRingLevel) {
    self.text = text
    self.ringPercent = ringPercent
    self.ringLevel = ringLevel
  }

  public init(waitingCount: Int, quotaPercent: Double?) {
    let formattedText = waitingCount > 0 ? "\(waitingCount)" : nil
    let level = Self.evaluateRingLevel(quotaPercent)
    self.init(text: formattedText, ringPercent: quotaPercent, ringLevel: level)
  }

  public static func evaluateRingLevel(_ quotaPercent: Double?) -> StatusRingLevel {
    guard let quotaPercent else { return .normal }
    if quotaPercent >= criticalThreshold {
      return .critical
    } else if quotaPercent >= warningThreshold {
      return .warning
    } else {
      return .normal
    }
  }
}
