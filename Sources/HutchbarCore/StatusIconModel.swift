// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Visual style of the menu bar waiting pill indicator.
public enum PillStyle: String, Sendable, Equatable, CaseIterable {
  case none
  case approval
  case yourTurn
}

// MARK: - Legacy Compatibility for StatusIconRenderer (v0.1)

public enum StatusRingLevel: String, Sendable, Equatable, CaseIterable {
  case normal
  case warning
  case critical
}

/// Pure model describing the menu bar status icon (two mini bars + waiting pill).
public struct StatusIconModel: Equatable, Sendable {
  /// Session remaining percentage (5h / 300 min window) of the most constrained account,
  /// excluding stale windows. 0...100, or nil if no fresh data is available.
  public let sessionRemaining: Double?

  /// Week remaining percentage (7d / 10080 min window) of the most constrained account,
  /// excluding stale windows. 0...100, or nil if no fresh data is available.
  public let weekRemaining: Double?

  /// Total count of sessions waiting for human action.
  public let waitingCount: Int

  /// Style of the waiting count pill indicator.
  public let pillStyle: PillStyle

  /// True if any non-stale remaining bar is below 10%, triggering the red critical appearance.
  public var barIsCritical: Bool {
    if let sessionRemaining, sessionRemaining < 10.0 {
      return true
    }
    if let weekRemaining, weekRemaining < 10.0 {
      return true
    }
    return false
  }

  public init(
    sessionRemaining: Double?,
    weekRemaining: Double?,
    waitingCount: Int,
    pillStyle: PillStyle
  ) {
    self.sessionRemaining = sessionRemaining
    self.weekRemaining = weekRemaining
    self.waitingCount = waitingCount
    self.pillStyle = pillStyle
  }

  /// Constructs the status icon model from quotas and waiting sessions at the given moment.
  public init(
    quotas: [AccountQuota],
    waitingSessions: [SessionSnapshot],
    now: Date = Date()
  ) {
    self.sessionRemaining = Self.calculateConstrainedRemaining(
      windowMinutes: 300,
      quotas: quotas,
      now: now
    )
    self.weekRemaining = Self.calculateConstrainedRemaining(
      windowMinutes: 10080,
      quotas: quotas,
      now: now
    )
    self.waitingCount = waitingSessions.count
    self.pillStyle = Self.evaluatePillStyle(waitingSessions: waitingSessions)
  }

  public init(
    quotas: [String: AccountQuota],
    waitingSessions: [SessionSnapshot],
    now: Date = Date()
  ) {
    self.init(quotas: Array(quotas.values), waitingSessions: waitingSessions, now: now)
  }

  // MARK: - Evaluation Helpers

  public static func calculateConstrainedRemaining(
    windowMinutes: Int,
    quotas: [AccountQuota],
    now: Date
  ) -> Double? {
    let windowDuration = TimeInterval(windowMinutes * 60)

    let remainingValues = quotas.compactMap { account -> Double? in
      if now.timeIntervalSince(account.observedAt) > windowDuration {
        return nil
      }
      guard let matching = account.windows.first(where: { $0.windowMinutes == windowMinutes })
      else {
        return nil
      }
      if let resetsAt = matching.resetsAt, resetsAt < now {
        return nil
      }
      return max(0.0, min(100.0, 100.0 - matching.usedPercent))
    }

    return remainingValues.min()
  }

  public static func evaluatePillStyle(waitingSessions: [SessionSnapshot]) -> PillStyle {
    guard !waitingSessions.isEmpty else { return .none }
    if waitingSessions.contains(where: { $0.state == .waitingForApproval }) {
      return .approval
    }
    return .yourTurn
  }

  // MARK: - Legacy Compatibility for StatusIconRenderer (v0.1)

  public typealias StatusRingLevel = HutchbarCore.StatusRingLevel

  public init(waitingCount: Int, quotaPercent: Double?) {
    let remaining = quotaPercent.map { max(0.0, min(100.0, 100.0 - $0)) }
    self.init(
      sessionRemaining: remaining,
      weekRemaining: nil,
      waitingCount: waitingCount,
      pillStyle: waitingCount > 0 ? .approval : .none
    )
  }

  public init(text: String?, ringPercent: Double?, ringLevel: StatusRingLevel) {
    let count = text.flatMap(Int.init) ?? 0
    let remaining = ringPercent.map { max(0.0, min(100.0, 100.0 - $0)) }
    self.init(
      sessionRemaining: remaining,
      weekRemaining: nil,
      waitingCount: count,
      pillStyle: count > 0 ? .approval : .none
    )
  }

  public var text: String? {
    waitingCount > 0 ? "\(waitingCount)" : nil
  }

  public var ringPercent: Double? {
    sessionRemaining.map { 100.0 - $0 }
  }

  public var ringLevel: StatusRingLevel {
    if barIsCritical { return .critical }
    if let sessionRemaining, sessionRemaining <= 20.0 { return .warning }
    return .normal
  }

  public static func evaluateRingLevel(_ quotaPercent: Double?) -> StatusRingLevel {
    guard let quotaPercent else { return .normal }
    if quotaPercent >= 95.0 {
      return .critical
    } else if quotaPercent >= 80.0 {
      return .warning
    } else {
      return .normal
    }
  }
}
