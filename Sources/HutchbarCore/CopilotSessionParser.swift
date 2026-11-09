// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Result of parsing a batch of Copilot CLI JSONL log lines.
public struct CopilotParseResult: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let snapshot: SessionSnapshot?
  public let skippedLines: Int
  /// Turn state to pass into the next `parse` of the same log.
  public let turn: CopilotTurnTracker

  public init(
    snapshot: SessionSnapshot?, skippedLines: Int, turn: CopilotTurnTracker = CopilotTurnTracker()
  ) {
    self.snapshot = snapshot
    self.skippedLines = skippedLines
    self.turn = turn
  }

  public var description: String {
    "CopilotParseResult(hasSnapshot: \(snapshot != nil), skippedLines: \(skippedLines))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "hasSnapshot": snapshot != nil,
        "skippedLines": skippedLines,
      ]
    )
  }
}

/// What a Copilot log said about the open turn; kept by the caller between batches
/// (one per tracked log), so the parser itself stays pure.
public struct CopilotTurnTracker: Equatable, Sendable {
  public var turnId: String?
  public var lastMessageWasFinal: Bool

  public init(turnId: String? = nil, lastMessageWasFinal: Bool = false) {
    self.turnId = turnId
    self.lastMessageWasFinal = lastMessageWasFinal
  }
}

/// Pure parser for Copilot CLI session logs (events.jsonl).
public enum CopilotSessionParser {
  public typealias Result = CopilotParseResult

  /// Inactivity timeout (30 minutes) after which an active session transitions to finished.
  public static let inactivityTimeout: TimeInterval = 30 * 60

  public static func parse(
    lines: [JSONLLine],
    current: SessionSnapshot?,
    fallbackSessionId: String? = nil,
    turn: CopilotTurnTracker = CopilotTurnTracker(),
    now: Date
  ) -> CopilotParseResult {
    parseInternal(
      lines, current: current, fallbackSessionId: fallbackSessionId, turn: turn, now: now)
  }

  public static func parse(
    _ lines: [JSONLLine],
    current: SessionSnapshot?,
    fallbackSessionId: String? = nil,
    turn: CopilotTurnTracker = CopilotTurnTracker(),
    now: Date
  ) -> CopilotParseResult {
    parseInternal(
      lines, current: current, fallbackSessionId: fallbackSessionId, turn: turn, now: now)
  }

  public static func parseDate(_ string: String) -> Date? {
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

  public static func extractProjectName(from cwd: String) -> String {
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "copilot" }
    var url = URL(fileURLWithPath: trimmed)
    while url.pathComponents.count > 1 && url.lastPathComponent.isEmpty {
      url.deleteLastPathComponent()
    }
    let last = url.lastPathComponent
    return (last.isEmpty || last == "/") ? trimmed : last
  }

  private static func parseInternal(
    _ lines: [JSONLLine],
    current: SessionSnapshot?,
    fallbackSessionId: String?,
    turn: CopilotTurnTracker,
    now: Date
  ) -> CopilotParseResult {
    var snapshot = current
    var skippedLines = 0
    let decoder = JSONDecoder()

    var activeTurnId = turn.turnId
    var activeMessageFinal = turn.lastMessageWasFinal

    for line in lines {
      guard !line.bytes.isEmpty else {
        skippedLines += 1
        continue
      }
      guard let record = try? decoder.decode(CopilotRecord.self, from: line.bytes),
        let eventType = record.type
      else {
        skippedLines += 1
        continue
      }

      let eventDate = record.timestamp.flatMap(parseDate) ?? now

      if isSubagentEvent(record) {
        handleSubagentEvent(record: record, eventDate: eventDate, snapshot: &snapshot)
        continue
      }

      let consumed = handleRootEvent(
        eventType: eventType,
        record: record,
        eventDate: eventDate,
        fallbackSessionId: fallbackSessionId,
        activeTurnId: &activeTurnId,
        activeMessageFinal: &activeMessageFinal,
        snapshot: &snapshot
      )
      if !consumed {
        skippedLines += 1
      }
    }

    let nextTurn =
      snapshot?.state == .finished
      ? CopilotTurnTracker()
      : CopilotTurnTracker(turnId: activeTurnId, lastMessageWasFinal: activeMessageFinal)
    let finalSnapshot = applyInactivityTimeout(to: snapshot, now: now)
    return CopilotParseResult(snapshot: finalSnapshot, skippedLines: skippedLines, turn: nextTurn)
  }

  private static func isSubagentEvent(_ record: CopilotRecord) -> Bool {
    guard let agentId = record.agentId else { return false }
    return !agentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func handleSubagentEvent(
    record: CopilotRecord,
    eventDate: Date,
    snapshot: inout SessionSnapshot?
  ) {
    if var existing = snapshot {
      if eventDate >= existing.lastActivity {
        existing.lastActivity = eventDate
        snapshot = existing
      }
    }
  }

  private static func handleRootEvent(
    eventType: String,
    record: CopilotRecord,
    eventDate: Date,
    fallbackSessionId: String?,
    activeTurnId: inout String?,
    activeMessageFinal: inout Bool,
    snapshot: inout SessionSnapshot?
  ) -> Bool {
    switch eventType {
    case "session.start":
      handleSessionStart(
        record: record, eventDate: eventDate, fallbackSessionId: fallbackSessionId,
        activeTurnId: &activeTurnId, activeMessageFinal: &activeMessageFinal, snapshot: &snapshot)
      return true

    case "session.context_changed":
      handleContextChanged(
        record: record, eventDate: eventDate, fallbackSessionId: fallbackSessionId,
        snapshot: &snapshot)
      return true

    case "user.message":
      handleUserMessage(
        eventDate: eventDate, fallbackSessionId: fallbackSessionId,
        activeMessageFinal: &activeMessageFinal, snapshot: &snapshot)
      return true

    case "assistant.turn_start":
      handleTurnStart(
        record: record, eventDate: eventDate, fallbackSessionId: fallbackSessionId,
        activeTurnId: &activeTurnId, activeMessageFinal: &activeMessageFinal, snapshot: &snapshot)
      return true

    case "assistant.message":
      handleAssistantMessage(
        record: record, eventDate: eventDate, activeMessageFinal: &activeMessageFinal,
        snapshot: &snapshot)
      return true

    case "assistant.turn_end":
      handleTurnEnd(
        record: record, eventDate: eventDate, fallbackSessionId: fallbackSessionId,
        activeTurnId: activeTurnId, activeMessageFinal: activeMessageFinal, snapshot: &snapshot)
      return true

    case "abort":
      handleAbort(
        eventDate: eventDate, fallbackSessionId: fallbackSessionId,
        activeMessageFinal: &activeMessageFinal, snapshot: &snapshot)
      return true

    case "session.shutdown":
      handleShutdown(
        eventDate: eventDate, fallbackSessionId: fallbackSessionId,
        activeTurnId: &activeTurnId, activeMessageFinal: &activeMessageFinal, snapshot: &snapshot)
      return true

    default:
      return false
    }
  }
}

// MARK: - Event Handlers

extension CopilotSessionParser {
  private static func handleSessionStart(
    record: CopilotRecord,
    eventDate: Date,
    fallbackSessionId: String?,
    activeTurnId: inout String?,
    activeMessageFinal: inout Bool,
    snapshot: inout SessionSnapshot?
  ) {
    let data = record.data
    let candidateSessionId = data?.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedId: String = {
      if let candidateSessionId, !candidateSessionId.isEmpty { return candidateSessionId }
      if let existingId = snapshot?.id, !existingId.isEmpty { return existingId }
      if let fallbackSessionId, !fallbackSessionId.isEmpty { return fallbackSessionId }
      return "copilot"
    }()

    let contextCwd =
      data?.context?.gitRoot ?? data?.context?.cwd ?? data?.context?.repository
      ?? data?.gitRoot ?? data?.cwd ?? data?.repository
    let resolvedCwd = contextCwd ?? snapshot?.cwd
    let projectName = resolvedCwd.map(extractProjectName) ?? snapshot?.projectName ?? "copilot"

    activeTurnId = nil
    activeMessageFinal = false

    snapshot = SessionSnapshot(
      id: resolvedId,
      agent: .copilot,
      state: snapshot?.state ?? .waitingForInput,
      projectName: projectName,
      title: snapshot?.title,
      lastActivity: eventDate,
      waitingSince: snapshot?.waitingSince ?? eventDate,
      cwd: resolvedCwd,
      parentKey: nil,
      childKind: nil
    )
  }

  private static func handleContextChanged(
    record: CopilotRecord,
    eventDate: Date,
    fallbackSessionId: String?,
    snapshot: inout SessionSnapshot?
  ) {
    let data = record.data
    let candidateCwd =
      data?.gitRoot ?? data?.cwd ?? data?.context?.gitRoot ?? data?.context?.cwd
    if let newCwd = candidateCwd, !newCwd.isEmpty {
      let project = extractProjectName(from: newCwd)
      if var existing = snapshot {
        existing.cwd = newCwd
        existing.projectName = project
        if eventDate >= existing.lastActivity {
          existing.lastActivity = eventDate
        }
        snapshot = existing
      } else {
        let initialId = fallbackSessionId ?? "copilot"
        snapshot = SessionSnapshot(
          id: initialId,
          agent: .copilot,
          state: .waitingForInput,
          projectName: project,
          lastActivity: eventDate,
          waitingSince: eventDate,
          cwd: newCwd
        )
      }
    } else if var existing = snapshot {
      if eventDate >= existing.lastActivity {
        existing.lastActivity = eventDate
        snapshot = existing
      }
    }
  }

  private static func handleUserMessage(
    eventDate: Date,
    fallbackSessionId: String?,
    activeMessageFinal: inout Bool,
    snapshot: inout SessionSnapshot?
  ) {
    activeMessageFinal = false
    if var existing = snapshot {
      existing.state = .running
      existing.waitingSince = nil
      if eventDate >= existing.lastActivity {
        existing.lastActivity = eventDate
      }
      snapshot = existing
    } else {
      let initialId = fallbackSessionId ?? "copilot"
      snapshot = SessionSnapshot(
        id: initialId,
        agent: .copilot,
        state: .running,
        projectName: "copilot",
        lastActivity: eventDate,
        waitingSince: nil
      )
    }
  }

  private static func handleTurnStart(
    record: CopilotRecord,
    eventDate: Date,
    fallbackSessionId: String?,
    activeTurnId: inout String?,
    activeMessageFinal: inout Bool,
    snapshot: inout SessionSnapshot?
  ) {
    activeTurnId = record.data?.turnId
    activeMessageFinal = false
    if var existing = snapshot {
      existing.state = .running
      existing.waitingSince = nil
      if eventDate >= existing.lastActivity {
        existing.lastActivity = eventDate
      }
      snapshot = existing
    } else {
      let initialId = fallbackSessionId ?? "copilot"
      snapshot = SessionSnapshot(
        id: initialId,
        agent: .copilot,
        state: .running,
        projectName: "copilot",
        lastActivity: eventDate,
        waitingSince: nil
      )
    }
  }

  private static func handleAssistantMessage(
    record: CopilotRecord,
    eventDate: Date,
    activeMessageFinal: inout Bool,
    snapshot: inout SessionSnapshot?
  ) {
    let data = record.data
    let hasToolRequests = !(data?.toolRequests?.isEmpty ?? true)
    let phase = data?.phase?.lowercased()
    let isThinkingOrCommentary = (phase == "thinking" || phase == "commentary")
    activeMessageFinal = !hasToolRequests && !isThinkingOrCommentary
    if var existing = snapshot {
      if eventDate >= existing.lastActivity {
        existing.lastActivity = eventDate
        snapshot = existing
      }
    }
  }

  private static func handleTurnEnd(
    record: CopilotRecord,
    eventDate: Date,
    fallbackSessionId: String?,
    activeTurnId: String?,
    activeMessageFinal: Bool,
    snapshot: inout SessionSnapshot?
  ) {
    let endTurnId = record.data?.turnId
    let turnMatches = (activeTurnId == nil) || (endTurnId == nil) || (activeTurnId == endTurnId)
    if turnMatches && activeMessageFinal {
      if var existing = snapshot {
        existing.state = .waitingForInput
        existing.waitingSince = eventDate
        if eventDate >= existing.lastActivity {
          existing.lastActivity = eventDate
        }
        snapshot = existing
      } else {
        let initialId = fallbackSessionId ?? "copilot"
        snapshot = SessionSnapshot(
          id: initialId,
          agent: .copilot,
          state: .waitingForInput,
          projectName: "copilot",
          lastActivity: eventDate,
          waitingSince: eventDate
        )
      }
    } else {
      if var existing = snapshot {
        existing.state = .running
        existing.waitingSince = nil
        if eventDate >= existing.lastActivity {
          existing.lastActivity = eventDate
        }
        snapshot = existing
      }
    }
  }

  private static func handleAbort(
    eventDate: Date,
    fallbackSessionId: String?,
    activeMessageFinal: inout Bool,
    snapshot: inout SessionSnapshot?
  ) {
    activeMessageFinal = false
    if var existing = snapshot {
      existing.state = .waitingForInput
      existing.waitingSince = eventDate
      if eventDate >= existing.lastActivity {
        existing.lastActivity = eventDate
      }
      snapshot = existing
    } else {
      let initialId = fallbackSessionId ?? "copilot"
      snapshot = SessionSnapshot(
        id: initialId,
        agent: .copilot,
        state: .waitingForInput,
        projectName: "copilot",
        lastActivity: eventDate,
        waitingSince: eventDate
      )
    }
  }

  private static func handleShutdown(
    eventDate: Date,
    fallbackSessionId: String?,
    activeTurnId: inout String?,
    activeMessageFinal: inout Bool,
    snapshot: inout SessionSnapshot?
  ) {
    activeTurnId = nil
    activeMessageFinal = false
    if var existing = snapshot {
      existing.state = .finished
      existing.waitingSince = nil
      if eventDate >= existing.lastActivity {
        existing.lastActivity = eventDate
      }
      snapshot = existing
    } else {
      let initialId = fallbackSessionId ?? "copilot"
      snapshot = SessionSnapshot(
        id: initialId,
        agent: .copilot,
        state: .finished,
        projectName: "copilot",
        lastActivity: eventDate,
        waitingSince: nil
      )
    }
  }
}
