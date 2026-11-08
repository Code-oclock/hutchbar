// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Result of parsing a batch of Codex JSONL log lines.
public struct CodexParseResult: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let snapshot: SessionSnapshot?
  public let quota: AccountQuota?
  public let skippedLines: Int

  public init(snapshot: SessionSnapshot?, quota: AccountQuota?, skippedLines: Int) {
    self.snapshot = snapshot
    self.quota = quota
    self.skippedLines = skippedLines
  }

  public var description: String {
    "CodexParseResult(hasSnapshot: \(snapshot != nil), hasQuota: \(quota != nil), "
      + "skippedLines: \(skippedLines))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "hasSnapshot": snapshot != nil,
        "hasQuota": quota != nil,
        "skippedLines": skippedLines,
      ]
    )
  }

  public var elements: (snapshot: SessionSnapshot?, quota: AccountQuota?, skippedLines: Int) {
    (snapshot, quota, skippedLines)
  }
}

/// Pure parser for Codex session logs (rollout-*.jsonl).
public enum CodexSessionParser {
  public typealias Result = CodexParseResult

  /// Inactivity timeout (30 minutes) after which an active session transitions to finished.
  public static let inactivityTimeout: TimeInterval = 30 * 60

  /// Parses a batch of Codex JSONL lines into an updated session snapshot, latest quota,
  /// and skipped lines count.
  public static func parse(
    lines: [JSONLLine], current: SessionSnapshot?, now: Date
  ) -> CodexParseResult {
    parseInternal(lines, current: current, now: now)
  }

  /// Convenience overload without argument label for lines.
  public static func parse(
    _ lines: [JSONLLine], current: SessionSnapshot?, now: Date
  ) -> CodexParseResult {
    parseInternal(lines, current: current, now: now)
  }

  static func parseDate(_ string: String) -> Date? {
    if let date = try? Date(string, strategy: .iso8601) {
      return date
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }

  static func extractProjectName(from cwd: String) -> String {
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent
    return lastComponent.isEmpty ? trimmed : lastComponent
  }

  private static func makeQuotaWindow(from payload: CodexRateLimitWindow) -> QuotaWindow {
    let minutes = payload.windowMinutes ?? 0
    let clampedPercent = min(100.0, max(0.0, payload.usedPercent ?? 0.0))
    return QuotaWindow(
      windowMinutes: minutes,
      usedPercent: clampedPercent,
      resetsAt: payload.resetsAt?.date
    )
  }

  private static func makeAccountQuota(
    from rateLimits: CodexRateLimits,
    observedAt: Date
  ) -> AccountQuota {
    var windows: [QuotaWindow] = []
    if let primary = rateLimits.primary {
      windows.append(makeQuotaWindow(from: primary))
    }
    if let secondary = rateLimits.secondary {
      windows.append(makeQuotaWindow(from: secondary))
    }
    let planType = rateLimits.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
    let accountName = (planType?.isEmpty == false) ? (planType ?? "codex") : "codex"
    return AccountQuota(
      agent: .codex,
      accountName: accountName,
      windows: windows,
      observedAt: observedAt
    )
  }

  private static func handleSessionMeta(
    record: CodexRecord,
    snapshot: SessionSnapshot?,
    pendingProjectName: inout String?,
    pendingCwd: inout String?,
    recordDate: Date?,
    now: Date
  ) -> (updatedSnapshot: SessionSnapshot?, lineConsumed: Bool) {
    let payload = record.payload
    let candidateId = payload?.id?.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidateSessionId = payload?.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedId: String? = {
      if let candidateId, !candidateId.isEmpty { return candidateId }
      if let candidateSessionId, !candidateSessionId.isEmpty { return candidateSessionId }
      return snapshot?.id
    }()

    let project: String? = {
      if let cwd = payload?.cwd, !cwd.isEmpty {
        return extractProjectName(from: cwd)
      }
      return nil
    }()
    if let project {
      pendingProjectName = project
    }
    if let cwd = payload?.cwd, !cwd.isEmpty {
      pendingCwd = cwd
    }

    let activityDate = payload?.timestamp?.date ?? recordDate ?? snapshot?.lastActivity ?? now

    guard let resolvedId, !resolvedId.isEmpty else {
      return (snapshot, false)
    }

    let projectName = project ?? pendingProjectName ?? snapshot?.projectName ?? ""
    let resolvedCwd = payload?.cwd ?? pendingCwd ?? snapshot?.cwd

    let isChild = payload?.source?.isChild == true
    let parentThreadId = payload?.parentThreadId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sessionIdField = payload?.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let parentCandidate: String? = {
      if let parentThreadId, !parentThreadId.isEmpty { return parentThreadId }
      if let sessionIdField, !sessionIdField.isEmpty { return sessionIdField }
      return nil
    }()
    let hasParent = isChild && parentCandidate != nil && parentCandidate != resolvedId
    let parentKey: SessionKey? =
      hasParent ? parentCandidate.map { SessionKey(agent: .codex, id: $0) } : nil
    let childKind: ChildKind? = hasParent ? .subagent : nil

    if var existing = snapshot {
      existing.projectName = projectName
      if let resolvedCwd, !resolvedCwd.isEmpty {
        existing.cwd = resolvedCwd
      }
      if activityDate >= existing.lastActivity {
        existing.lastActivity = activityDate
      }
      if hasParent {
        existing.parentKey = parentKey
        existing.childKind = childKind
      }
      if existing.id != resolvedId {
        existing = SessionSnapshot(
          id: resolvedId,
          agent: .codex,
          state: existing.state,
          projectName: existing.projectName,
          title: existing.title,
          lastActivity: existing.lastActivity,
          waitingSince: existing.waitingSince,
          cwd: existing.cwd,
          parentKey: existing.parentKey,
          childKind: existing.childKind
        )
      }
      return (existing, true)
    }

    let createdSnapshot = SessionSnapshot(
      id: resolvedId,
      agent: .codex,
      state: .waitingForInput,
      projectName: projectName,
      title: nil,
      lastActivity: activityDate,
      waitingSince: activityDate,
      cwd: resolvedCwd,
      parentKey: parentKey,
      childKind: childKind
    )
    return (createdSnapshot, true)
  }

  private static func handleTurnContext(
    payload: CodexPayload?,
    recordDate: Date?,
    snapshot: inout SessionSnapshot?,
    pendingProjectName: inout String?,
    pendingCwd: inout String?
  ) {
    if let cwd = payload?.cwd, !cwd.isEmpty {
      let project = extractProjectName(from: cwd)
      pendingProjectName = project
      pendingCwd = cwd
      if var existing = snapshot {
        existing.projectName = project
        existing.cwd = cwd
        snapshot = existing
      }
    }
    if let recordDate, var existing = snapshot {
      if recordDate >= existing.lastActivity {
        existing.lastActivity = recordDate
        snapshot = existing
      }
    }
  }

  private static func handleEventMessage(
    payload: CodexPayload?,
    recordDate: Date?,
    snapshot: inout SessionSnapshot?,
    latestQuota: inout AccountQuota?,
    now: Date
  ) -> Bool {
    guard let eventType = payload?.type else { return false }
    switch eventType {
    case "task_started":
      let activityDate = recordDate ?? now
      if var existing = snapshot {
        existing.state = .running
        existing.waitingSince = nil
        if activityDate >= existing.lastActivity {
          existing.lastActivity = activityDate
        }
        snapshot = existing
      }
      return true

    case "task_complete":
      let activityDate = recordDate ?? now
      if var existing = snapshot {
        if existing.state != .waitingForInput && existing.state != .waitingForApproval {
          existing.waitingSince = activityDate
        }
        existing.state = .waitingForInput
        if activityDate >= existing.lastActivity {
          existing.lastActivity = activityDate
        }
        snapshot = existing
      }
      return true

    case "token_count":
      if let recordDate, var existing = snapshot {
        if recordDate >= existing.lastActivity {
          existing.lastActivity = recordDate
          snapshot = existing
        }
      }
      if let rateLimits = payload?.rateLimits {
        latestQuota = makeAccountQuota(from: rateLimits, observedAt: recordDate ?? now)
      }
      return true

    default:
      return false
    }
  }

  private static func parseInternal(
    _ lines: [JSONLLine],
    current: SessionSnapshot?,
    now: Date
  ) -> CodexParseResult {
    var snapshot = current
    var latestQuota: AccountQuota?
    var skippedLines = 0
    var pendingProjectName: String?
    var pendingCwd: String?
    let decoder = JSONDecoder()

    for line in lines {
      guard !line.bytes.isEmpty else {
        skippedLines += 1
        continue
      }

      guard let record = try? decoder.decode(CodexRecord.self, from: line.bytes),
        let recordType = record.type
      else {
        skippedLines += 1
        continue
      }

      let recordDate = record.timestamp?.date

      switch recordType {
      case "session_meta":
        let (updated, lineConsumed) = handleSessionMeta(
          record: record,
          snapshot: snapshot,
          pendingProjectName: &pendingProjectName,
          pendingCwd: &pendingCwd,
          recordDate: recordDate,
          now: now
        )
        snapshot = updated
        if !lineConsumed {
          skippedLines += 1
        }

      case "turn_context":
        handleTurnContext(
          payload: record.payload,
          recordDate: recordDate,
          snapshot: &snapshot,
          pendingProjectName: &pendingProjectName,
          pendingCwd: &pendingCwd
        )

      case "event_msg":
        let recognized = handleEventMessage(
          payload: record.payload,
          recordDate: recordDate,
          snapshot: &snapshot,
          latestQuota: &latestQuota,
          now: now
        )
        if !recognized {
          skippedLines += 1
        }

      default:
        skippedLines += 1
      }
    }

    let finalSnapshot = applyInactivityTimeout(to: snapshot, now: now)
    return CodexParseResult(snapshot: finalSnapshot, quota: latestQuota, skippedLines: skippedLines)
  }
}

// Inactivity helpers, kept outside the main body to respect type length limits.
extension CodexSessionParser {
  /// Determines whether a session is inactive based on last activity and the current clock time.
  public static func isInactive(
    lastActivity: Date,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> Bool {
    now.timeIntervalSince(lastActivity) >= timeout
  }

  /// Applies the 30-minute inactivity rule to an active session snapshot.
  public static func applyInactivityTimeout(
    to snapshot: SessionSnapshot,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot {
    guard snapshot.state != .finished,
      isInactive(lastActivity: snapshot.lastActivity, now: now, timeout: timeout)
    else {
      return snapshot
    }
    var updated = snapshot
    updated.state = .finished
    updated.waitingSince = nil
    return updated
  }

  /// Overload for optional session snapshot.
  public static func applyInactivityTimeout(
    to optionalSnapshot: SessionSnapshot?,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot? {
    guard let snapshot = optionalSnapshot else { return nil }
    let updated: SessionSnapshot = applyInactivityTimeout(to: snapshot, now: now, timeout: timeout)
    return updated
  }

  /// Alias for applying the inactivity rule to a session snapshot.
  public static func applyInactivityRule(
    to snapshot: SessionSnapshot, now: Date, timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot {
    applyInactivityTimeout(to: snapshot, now: now, timeout: timeout)
  }

  /// Overload for optional session snapshot.
  public static func applyInactivityRule(
    to optionalSnapshot: SessionSnapshot?, now: Date, timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot? {
    applyInactivityTimeout(to: optionalSnapshot, now: now, timeout: timeout)
  }
}
