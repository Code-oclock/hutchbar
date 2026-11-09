// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which coding agent produced a session.
public enum AgentKind: String, CaseIterable, Sendable, Codable {
  case claudeCode
  case codex
  /// Google Antigravity CLI (`agy`).
  case antigravity
  /// Qwen Code (`qwen`).
  case qwen
  /// OpenCode (`opencode`).
  case opencode
  /// GitHub Copilot CLI (`copilot`).
  case copilot
  /// Google Gemini CLI (`gemini`).
  case geminiCLI
}

/// What kind of child relationship produces a nested session.
public enum ChildKind: String, CaseIterable, Sendable, Codable, Equatable {
  case subagent
  case process
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
  /// Parent session key if this session is a child, otherwise nil.
  public var parentKey: SessionKey?
  /// Nature of the child relationship (subagent or process).
  public var childKind: ChildKind?

  public init(
    id: String,
    agent: AgentKind,
    state: SessionState,
    projectName: String,
    title: String? = nil,
    lastActivity: Date,
    waitingSince: Date? = nil,
    cwd: String? = nil,
    parentKey: SessionKey? = nil,
    childKind: ChildKind? = nil
  ) {
    self.id = id
    self.agent = agent
    self.state = state
    self.projectName = projectName
    self.title = title
    self.lastActivity = lastActivity
    self.waitingSince = waitingSince
    self.cwd = cwd
    self.parentKey = parentKey
    self.childKind = childKind
  }
}

extension SessionSnapshot: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public var description: String {
    let idPrefix = String(id.prefix(8))
    return "SessionSnapshot(id: \(idPrefix), agent: \(agent), state: \(state), "
      + "projectName: \(projectName))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": String(id.prefix(8)),
        "agent": agent,
        "state": state,
        "projectName": projectName,
      ]
    )
  }
}

/// One rate-limit window of a subscription (for example 5 hours or 7 days).
public struct QuotaWindow: Equatable, Sendable {
  public let windowMinutes: Int
  /// 0...100.
  public let usedPercent: Double
  /// nil when the window has not started yet (nothing used in it).
  public let resetsAt: Date?
  /// nil for the general window, otherwise the model family it limits ("Opus", "Sonnet").
  public let scope: String?

  public init(windowMinutes: Int, usedPercent: Double, resetsAt: Date?, scope: String? = nil) {
    self.windowMinutes = windowMinutes
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.scope = scope
  }
}

/// Where a quota reading came from (see docs/specs/limits-v3.md).
public enum QuotaSource: String, CaseIterable, Sendable, Codable {
  /// Asked the agent itself (`claude` get_usage, `codex app-server`).
  case agentCLI
  /// A reading the agent wrote into its own session log.
  case sessionLog
  /// The ccr gateway's quota table.
  case ccr
  /// The Claude desktop app's usage history.
  case claudeApp
  /// Queried the agent's remote service API over the network.
  case serviceAPI
}

/// Quota of one account at the moment it was observed.
public struct AccountQuota: Equatable, Sendable, Identifiable {
  public var id: String { "\(agent.rawValue):\(accountName)" }
  public let agent: AgentKind
  public let accountName: String
  public let windows: [QuotaWindow]
  public let observedAt: Date
  public let source: QuotaSource
  /// Subscription as the source names it ("pro", "max", "plus"), if known.
  public let plan: String?
  /// Free limit resets available (Codex), if known.
  public let resetCredits: Int?

  public init(
    agent: AgentKind, accountName: String, windows: [QuotaWindow], observedAt: Date,
    source: QuotaSource = .sessionLog, plan: String? = nil, resetCredits: Int? = nil
  ) {
    self.agent = agent
    self.accountName = accountName
    self.windows = windows
    self.observedAt = observedAt
    self.source = source
    self.plan = plan
    self.resetCredits = resetCredits
  }
}

/// Live process and activity status reported in Claude Code session registry.
public enum ClaudeLiveStatus: String, CaseIterable, Sendable, Codable, Equatable {
  case busy
  case idle
  case unknown
  case finished
}

/// One change emitted by the source layer and consumed by SessionStore.
public enum SourceUpdate: Sendable, Equatable {
  case session(SessionSnapshot)
  case quota(AccountQuota)
  case hookEvent(HookEvent)
  case liveStatus(
    sessionId: String, pid: Int, status: ClaudeLiveStatus, at: Date, cwd: String? = nil)
  /// A source became available or unavailable (for the panel footer).
  case sourceStatus(SourceKind, available: Bool)
}

/// Data sources hutchbar can read.
public enum SourceKind: String, CaseIterable, Sendable, Codable {
  case claudeTranscripts
  case claudeHooks
  case codexSessions
  case ccrQuotas
  case claudeLive
  case claudeUsage
  case codexUsage
  case antigravityUsage
  case copilotUsage
  case copilotSessions
  case openCodeSessions
}
