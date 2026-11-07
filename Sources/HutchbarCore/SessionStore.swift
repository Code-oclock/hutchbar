// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

/// Unique identifier for an agent session combining agent kind and session identifier.
public struct SessionKey: Hashable, Sendable, CustomStringConvertible {
  public let agent: AgentKind
  public let id: String

  public init(agent: AgentKind, id: String) {
    self.agent = agent
    self.id = id
  }

  public var description: String {
    "\(agent.rawValue):\(id)"
  }
}

extension SessionSnapshot {
  public var sessionKey: SessionKey {
    SessionKey(agent: agent, id: id)
  }
}

/// Central store for agent sessions, quotas, and source statuses.
@MainActor
@Observable
public final class SessionStore {
  /// Whether finished sessions should be exposed via `finished`.
  public var showFinished: Bool

  /// Registered sessions keyed by `(agent, id)`.
  private var sessions: [SessionKey: SessionSnapshot] = [:]

  /// Recent hook events that arrived before their corresponding session snapshot was created.
  private var pendingHookEvents: [HookEvent] = []

  /// Quotas indexed by `AccountQuota.id`. Newer quotas replace older ones.
  public private(set) var quotas: [String: AccountQuota] = [:]

  /// Availability status of data sources for UI indicators.
  public private(set) var sourceStatus: [SourceKind: Bool] = [:]

  /// Maximum number of pending hook events to buffer before dropping the oldest.
  public static let maxPendingHookEvents = 50

  /// Maximum number of total sessions retained before pruning excess finished sessions.
  public static let maxRetainedSessions = 500

  /// Age after which finished sessions are pruned (24 hours).
  public static let finishedSessionTtl: TimeInterval = 24 * 60 * 60

  public init(showFinished: Bool = false) {
    self.showFinished = showFinished
  }

  /// Sessions waiting for user action. `waitingForApproval` comes before `waitingForInput`,
  /// sorted by `waitingSince` ascending (longest waiting first).
  public var waiting: [SessionSnapshot] {
    sessions.values
      .filter { $0.state == .waitingForApproval || $0.state == .waitingForInput }
      .sorted { lhs, rhs in
        if lhs.state != rhs.state {
          return lhs.state == .waitingForApproval
        }
        let lhsSince = lhs.waitingSince ?? .distantFuture
        let rhsSince = rhs.waitingSince ?? .distantFuture
        if lhsSince != rhsSince {
          return lhsSince < rhsSince
        }
        return lhs.id < rhs.id
      }
  }

  /// Actively working (running) sessions, sorted by `lastActivity` descending (most active first).
  public var working: [SessionSnapshot] {
    sessions.values
      .filter { $0.state == .running }
      .sorted { lhs, rhs in
        if lhs.lastActivity != rhs.lastActivity {
          return lhs.lastActivity > rhs.lastActivity
        }
        return lhs.id < rhs.id
      }
  }

  /// Finished sessions, hidden if `showFinished == false`.
  /// When shown, sorted by `lastActivity` descending.
  public var finished: [SessionSnapshot] {
    guard showFinished else { return [] }
    return sessions.values
      .filter { $0.state == .finished }
      .sorted { lhs, rhs in
        if lhs.lastActivity != rhs.lastActivity {
          return lhs.lastActivity > rhs.lastActivity
        }
        return lhs.id < rhs.id
      }
  }

  /// Total count of sessions currently waiting for human intervention.
  public var waitingCount: Int {
    waiting.count
  }

  /// Highest 5-hour quota usage percent across all accounts, or `nil` if no 5-hour quota is known.
  public var maxFiveHourQuota: Double? {
    let percentages = quotas.values.flatMap { account in
      account.windows.compactMap { window -> Double? in
        guard window.windowMinutes == 300 else { return nil }
        return window.usedPercent
      }
    }
    return percentages.max()
  }

  /// Number of registered sessions in the store.
  public var sessionCount: Int {
    sessions.count
  }

  /// Number of buffered pending hook events.
  public var pendingHookCount: Int {
    pendingHookEvents.count
  }

  /// Retrieves a snapshot for the given session key.
  public func session(for key: SessionKey) -> SessionSnapshot? {
    sessions[key]
  }

  /// Retrieves a snapshot for the given agent and session identifier.
  public func session(agent: AgentKind, id: String) -> SessionSnapshot? {
    sessions[SessionKey(agent: agent, id: id)]
  }

  /// Applies a data source update to the store.
  public func apply(_ update: SourceUpdate, now: Date = Date()) {
    switch update {
    case .session(var incoming):
      applySessionUpdate(&incoming)
    case .hookEvent(let event):
      applyHookEventUpdate(event)
    case .quota(let quota):
      quotas[quota.id] = quota
    case .sourceStatus(let kind, available: let available):
      sourceStatus[kind] = available
    }
  }

  /// Prunes finished sessions older than 24 hours and enforces the 500 session limit.
  public func prune(now: Date = Date()) {
    // 1. Remove finished sessions older than 24 hours.
    sessions = sessions.filter { _, session in
      if session.state == .finished {
        let age = now.timeIntervalSince(session.lastActivity)
        return age < Self.finishedSessionTtl
      }
      return true
    }

    // 2. Enforce total session limit by removing excess oldest finished sessions.
    if sessions.count > Self.maxRetainedSessions {
      let excess = sessions.count - Self.maxRetainedSessions
      let finishedSessions = sessions.values
        .filter { $0.state == .finished }
        .sorted { lhs, rhs in
          if lhs.lastActivity != rhs.lastActivity {
            return lhs.lastActivity < rhs.lastActivity
          }
          return lhs.id < rhs.id
        }

      let toDrop = finishedSessions.prefix(excess)
      for session in toDrop {
        sessions.removeValue(forKey: session.sessionKey)
      }
    }
  }

  /// Pure decision evaluation helper for the attention pill.
  public func attentionDecision(
    now: Date = Date(),
    threshold: TimeInterval?,
    state: AttentionPolicy.State
  ) -> AttentionPolicy.Decision {
    AttentionPolicy.decide(waiting: waiting, now: now, threshold: threshold, state: state)
  }

  private func applySessionUpdate(_ incoming: inout SessionSnapshot) {
    let key = incoming.sessionKey
    // If Claude Code, replay any pending hook events buffered before this session appeared.
    if incoming.agent == .claudeCode {
      let matching = pendingHookEvents.filter { $0.session == incoming.id }
      if !matching.isEmpty {
        pendingHookEvents.removeAll { $0.session == incoming.id }
        let sortedEvents = matching.sorted { $0.ts < $1.ts }
        for event in sortedEvents {
          incoming = HutchbarCore.apply(event, to: incoming)
        }
      }
    }

    if let existing = sessions[key] {
      sessions[key] = mergeSession(incoming: incoming, existing: existing)
    } else {
      sessions[key] = incoming
    }
  }

  private func applyHookEventUpdate(_ event: HookEvent) {
    let key = SessionKey(agent: .claudeCode, id: event.session)
    if let existing = sessions[key] {
      sessions[key] = HutchbarCore.apply(event, to: existing)
    } else {
      pendingHookEvents.append(event)
      if pendingHookEvents.count > Self.maxPendingHookEvents {
        pendingHookEvents.removeFirst(pendingHookEvents.count - Self.maxPendingHookEvents)
      }
    }
  }

  private func mergeSession(
    incoming: SessionSnapshot,
    existing: SessionSnapshot
  ) -> SessionSnapshot {
    if incoming.lastActivity < existing.lastActivity {
      var merged = existing
      if merged.title == nil { merged.title = incoming.title }
      if merged.projectName.isEmpty { merged.projectName = incoming.projectName }
      if merged.cwd == nil || merged.cwd?.isEmpty == true { merged.cwd = incoming.cwd }
      return merged
    }

    if incoming.lastActivity == existing.lastActivity, existing.state == .waitingForApproval {
      var merged = existing
      if merged.title == nil { merged.title = incoming.title }
      if merged.projectName.isEmpty { merged.projectName = incoming.projectName }
      if merged.cwd == nil || merged.cwd?.isEmpty == true { merged.cwd = incoming.cwd }
      return merged
    }

    var merged = incoming
    if merged.title == nil { merged.title = existing.title }
    if merged.projectName.isEmpty { merged.projectName = existing.projectName }
    if merged.cwd == nil || merged.cwd?.isEmpty == true { merged.cwd = existing.cwd }
    return merged
  }
}

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
