// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure attention pill evaluation policy.
public struct AttentionPolicy: Sendable {
  /// Default interval before re-alerting for the exact same session (5 minutes).
  public static let repeatInterval: TimeInterval = 5 * 60

  /// Attention pill display history state.
  public struct State: Equatable, Sendable {
    public var lastShownKey: SessionKey?
    public var lastShownAt: Date?
    public var lastShownTimes: [SessionKey: Date]

    public var lastShownSessionId: String? {
      lastShownKey?.id
    }

    public init(
      lastShownKey: SessionKey? = nil,
      lastShownAt: Date? = nil,
      lastShownTimes: [SessionKey: Date] = [:]
    ) {
      self.lastShownKey = lastShownKey
      self.lastShownAt = lastShownAt
      if lastShownTimes.isEmpty, let lastShownKey, let lastShownAt {
        self.lastShownTimes = [lastShownKey: lastShownAt]
      } else {
        self.lastShownTimes = lastShownTimes
      }
    }

    public init(
      lastShownSessionId: String?,
      lastShownAt: Date?,
      agent: AgentKind = .claudeCode
    ) {
      let key = lastShownSessionId.map { SessionKey(agent: agent, id: $0) }
      self.init(lastShownKey: key, lastShownAt: lastShownAt)
    }
  }

  /// Result of evaluating the attention pill policy.
  public struct Decision: Equatable, Sendable {
    public let sessionToShow: SessionSnapshot?
    public let newState: State

    public var session: SessionSnapshot? { sessionToShow }
    public var state: State { newState }

    public init(sessionToShow: SessionSnapshot?, newState: State) {
      self.sessionToShow = sessionToShow
      self.newState = newState
    }

    public init(session: SessionSnapshot?, state: State) {
      self.sessionToShow = session
      self.newState = state
    }
  }

  /// Evaluates which waiting session to show in the attention pill, if any.
  public static func decide(
    waiting: [SessionSnapshot],
    now: Date,
    threshold: TimeInterval?,
    state: State
  ) -> Decision {
    guard let threshold, threshold >= 0 else {
      return Decision(sessionToShow: nil, newState: state)
    }

    let eligible = waiting.filter { session in
      guard let waitingSince = session.waitingSince else { return false }
      let waited = now.timeIntervalSince(waitingSince)
      guard waited >= threshold else { return false }

      if let previousShownAt = state.lastShownTimes[session.sessionKey] {
        let elapsed = now.timeIntervalSince(previousShownAt)
        if elapsed < repeatInterval {
          return false
        }
      }
      return true
    }

    guard
      let chosen = eligible.min(by: { lhs, rhs in
        let lhsSince = lhs.waitingSince ?? .distantFuture
        let rhsSince = rhs.waitingSince ?? .distantFuture
        if lhsSince != rhsSince {
          return lhsSince < rhsSince
        }
        if lhs.state != rhs.state {
          return lhs.state == .waitingForApproval
        }
        return lhs.id < rhs.id
      })
    else {
      return Decision(sessionToShow: nil, newState: state)
    }

    var updatedTimes = state.lastShownTimes
    updatedTimes[chosen.sessionKey] = now

    let maxRetention = now.addingTimeInterval(-24 * 60 * 60)
    updatedTimes = updatedTimes.filter { _, date in date >= maxRetention }

    let nextState = State(
      lastShownKey: chosen.sessionKey,
      lastShownAt: now,
      lastShownTimes: updatedTimes
    )
    return Decision(sessionToShow: chosen, newState: nextState)
  }

  public static func evaluate(
    waiting: [SessionSnapshot],
    now: Date,
    threshold: TimeInterval?,
    state: State
  ) -> Decision {
    decide(waiting: waiting, now: now, threshold: threshold, state: state)
  }
}
