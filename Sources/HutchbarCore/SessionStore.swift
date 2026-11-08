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

  /// Duration after which waiting sessions are considered quiet (nil = never).
  public var quietAfter: TimeInterval?

  /// Registered sessions keyed by `(agent, id)`.
  private var sessions: [SessionKey: SessionSnapshot] = [:]

  /// Recent hook events that arrived before their corresponding session snapshot was created.
  private var pendingHookEvents: [HookEvent] = []

  /// Quotas indexed by `AccountQuota.id`. Newer quotas replace older ones.
  public private(set) var quotas: [String: AccountQuota] = [:]

  /// Active process identifiers mapped by session key, kept outside SessionSnapshot.
  private var sessionPids: [SessionKey: Int] = [:]

  /// Availability status of data sources for UI indicators.
  public private(set) var sourceStatus: [SourceKind: Bool] = [:]

  /// Maximum number of pending hook events to buffer before dropping the oldest.
  public static let maxPendingHookEvents = 50

  /// Maximum number of total sessions retained before pruning excess finished sessions.
  public static let maxRetainedSessions = 500

  /// Age after which finished sessions are pruned (24 hours).
  public static let finishedSessionTtl: TimeInterval = 24 * 60 * 60

  public init(showFinished: Bool = false, quietAfter: TimeInterval? = 3600) {
    self.showFinished = showFinished
    self.quietAfter = quietAfter
  }

  /// Sessions waiting for user action that are not quiet at `now`.
  /// `waitingForApproval` comes before `waitingForInput`,
  /// sorted by `waitingSince` ascending (longest waiting first).
  public func waiting(now: Date = Date()) -> [SessionSnapshot] {
    sessions.values
      .filter { session in
        guard session.state == .waitingForApproval || session.state == .waitingForInput else {
          return false
        }
        if let quietAfter, let waitingSince = session.waitingSince {
          if now.timeIntervalSince(waitingSince) > quietAfter {
            return false
          }
        }
        return true
      }
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

  /// Total count of sessions currently waiting for human intervention that are not quiet at `now`.
  public func waitingCount(now: Date = Date()) -> Int {
    waiting(now: now).count
  }

  /// Sessions waiting for user action whose `waitingSince` is older than `quietAfter` at `now`.
  /// Sorted by `lastActivity` descending (most recent first).
  public func quiet(now: Date = Date()) -> [SessionSnapshot] {
    guard let quietAfter else { return [] }
    return sessions.values
      .filter { session in
        guard session.state == .waitingForApproval || session.state == .waitingForInput else {
          return false
        }
        guard let waitingSince = session.waitingSince else { return false }
        return now.timeIntervalSince(waitingSince) > quietAfter
      }
      .sorted { lhs, rhs in
        if lhs.lastActivity != rhs.lastActivity {
          return lhs.lastActivity > rhs.lastActivity
        }
        return lhs.id < rhs.id
      }
  }

  /// Sessions waiting for user action (non-quiet).
  public var waiting: [SessionSnapshot] {
    waiting(now: Date())
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

  /// Total count of sessions currently waiting for human intervention (non-quiet).
  public var waitingCount: Int {
    waitingCount(now: Date())
  }

  /// Sessions currently waiting for human intervention that are quiet.
  public var quiet: [SessionSnapshot] {
    quiet(now: Date())
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

  /// Process ID stored for the session key, if currently live.
  public func pid(for key: SessionKey) -> Int? {
    sessionPids[key]
  }

  /// Process ID stored for the agent and session id, if currently live.
  public func pid(agent: AgentKind, id: String) -> Int? {
    sessionPids[SessionKey(agent: agent, id: id)]
  }

  /// Applies a data source update to the store.
  public func apply(_ update: SourceUpdate, now: Date = Date()) {
    switch update {
    case .session(var incoming):
      applySessionUpdate(&incoming)
    case .hookEvent(let event):
      applyHookEventUpdate(event)
    case .quota(let quota):
      if let existing = quotas[quota.id], quota.observedAt < existing.observedAt {
        break
      }
      quotas[quota.id] = quota
    case .liveStatus(let sessionId, let pid, let status, let at, let cwd):
      applyLiveStatusUpdate(sessionId: sessionId, pid: pid, status: status, at: at, cwd: cwd)
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

    let currentKeys = Set(sessions.keys)
    sessionPids = sessionPids.filter { currentKeys.contains($0.key) }
  }

  /// Pure decision evaluation helper for the attention pill.
  public func attentionDecision(
    now: Date = Date(),
    threshold: TimeInterval?,
    state: AttentionPolicy.State
  ) -> AttentionPolicy.Decision {
    AttentionPolicy.decide(waiting: waiting(now: now), now: now, threshold: threshold, state: state)
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

// MARK: - Live Status Updates

extension SessionStore {
  func applyLiveStatusUpdate(
    sessionId: String,
    pid: Int,
    status: ClaudeLiveStatus,
    at: Date,
    cwd: String? = nil
  ) {
    let key = SessionKey(agent: .claudeCode, id: sessionId)
    let liveProjectName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    if status != .finished {
      sessionPids[key] = pid
    } else {
      sessionPids.removeValue(forKey: key)
    }

    guard var existing = sessions[key] else {
      let state: SessionState
      let waitingSince: Date?
      switch status {
      case .busy:
        state = .running
        waitingSince = nil
      case .idle:
        state = .waitingForInput
        waitingSince = at
      case .finished:
        state = .finished
        waitingSince = nil
      case .unknown:
        state = .running
        waitingSince = nil
      }
      sessions[key] = SessionSnapshot(
        id: sessionId,
        agent: .claudeCode,
        state: state,
        projectName: liveProjectName,
        lastActivity: at,
        waitingSince: waitingSince,
        cwd: cwd
      )
      return
    }
    if existing.projectName.isEmpty { existing.projectName = liveProjectName }
    if existing.cwd == nil { existing.cwd = cwd }

    switch status {
    case .busy:
      existing.state = .running
      existing.waitingSince = nil
      existing.lastActivity = max(existing.lastActivity, at)
      sessions[key] = existing

    case .idle:
      if existing.state == .waitingForApproval {
        let approvalTime = existing.waitingSince ?? existing.lastActivity
        if approvalTime > at {
          existing.lastActivity = max(existing.lastActivity, at)
          sessions[key] = existing
          return
        }
      }
      existing.state = .waitingForInput
      existing.waitingSince = at
      existing.lastActivity = max(existing.lastActivity, at)
      sessions[key] = existing

    case .finished:
      existing.state = .finished
      existing.waitingSince = nil
      existing.lastActivity = max(existing.lastActivity, at)
      sessions[key] = existing

    case .unknown:
      existing.lastActivity = max(existing.lastActivity, at)
      sessions[key] = existing
    }
  }
}
