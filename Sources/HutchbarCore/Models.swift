// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which coding agent produced a session.
public enum AgentKind: String, CaseIterable, Sendable, Codable {
  case claudeCode
  case codex
}

/// Content-free view of one agent session. Never holds prompts, code or tool output.
public struct SessionSnapshot: Equatable, Sendable, Identifiable {
  public let id: String
  public let agent: AgentKind
  public var state: SessionState
  /// Last path component of the working directory only, never the full path.
  public var projectName: String
  /// User-set session title (Claude Code `custom-title`), if any. Capped at 80 characters.
  public var title: String?
  public var lastActivity: Date
  /// When the session entered its current waiting state; nil while running or finished.
  public var waitingSince: Date?
  /// Full working directory, kept in memory only to locate the agent process.
  /// Never displayed, logged or persisted (see docs/specs/panel-v2.md, section 3).
  public var cwd: String?

  public init(
    id: String, agent: AgentKind, state: SessionState, projectName: String, title: String? = nil,
    lastActivity: Date, waitingSince: Date? = nil, cwd: String? = nil
  ) {
    self.id = id
    self.agent = agent
    self.state = state
    self.projectName = projectName
    self.title = title
    self.lastActivity = lastActivity
    self.waitingSince = waitingSince
    self.cwd = cwd
  }
}

/// One rate-limit window of a subscription (for example 5 hours or 7 days).
public struct QuotaWindow: Equatable, Sendable {
  public let windowMinutes: Int
  /// 0...100.
  public let usedPercent: Double
  public let resetsAt: Date?

  public init(windowMinutes: Int, usedPercent: Double, resetsAt: Date?) {
    self.windowMinutes = windowMinutes
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
  }
}

/// Quota of one account at the moment it was observed.
public struct AccountQuota: Equatable, Sendable, Identifiable {
  public var id: String { "\(agent.rawValue):\(accountName)" }
  public let agent: AgentKind
  public let accountName: String
  public let windows: [QuotaWindow]
  public let observedAt: Date

  public init(agent: AgentKind, accountName: String, windows: [QuotaWindow], observedAt: Date) {
    self.agent = agent
    self.accountName = accountName
    self.windows = windows
    self.observedAt = observedAt
  }
}

/// One change emitted by the source layer and consumed by SessionStore.
public enum SourceUpdate: Sendable, Equatable {
  case session(SessionSnapshot)
  case quota(AccountQuota)
  case hookEvent(HookEvent)
  /// A source became available or unavailable (for the panel footer).
  case sourceStatus(SourceKind, available: Bool)
}

/// Data sources hutchbar can read.
public enum SourceKind: String, CaseIterable, Sendable, Codable {
  case claudeTranscripts
  case claudeHooks
  case codexSessions
  case ccrQuotas
}
