// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private struct TranscriptRecord: Decodable {
  let type: String?
  let subtype: String?
  let sessionId: String?
  let cwd: String?
  let timestamp: String?
  let isSidechain: Bool?
  let customTitle: String?
  let message: TranscriptMessage?
  let hasToolUseResult: Bool

  private enum CodingKeys: String, CodingKey {
    case type, subtype, sessionId, cwd, timestamp, isSidechain, customTitle, message, toolUseResult
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type)
    subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
    sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    isSidechain = try container.decodeIfPresent(Bool.self, forKey: .isSidechain)
    customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    message = try container.decodeIfPresent(TranscriptMessage.self, forKey: .message)
    if container.contains(.toolUseResult) {
      hasToolUseResult = !(try container.decodeNil(forKey: .toolUseResult))
    } else {
      hasToolUseResult = false
    }
  }
}

private struct TranscriptMessage: Decodable {
  let stopReason: String?
  let content: TranscriptContent?

  private enum CodingKeys: String, CodingKey {
    case stopReason = "stop_reason"
    case content
  }
}

private struct TranscriptContent: Decodable {
  let hasText: Bool
  let hasToolResult: Bool

  init(from decoder: Decoder) throws {
    if let single = try? decoder.singleValueContainer(),
      (try? single.decode(String.self)) != nil
    {
      hasText = true
      hasToolResult = false
      return
    }
    if var array = try? decoder.unkeyedContainer() {
      var foundText = false
      var foundToolResult = false
      while !array.isAtEnd {
        if let block = try? array.decode(ContentBlock.self) {
          if block.type == "text" { foundText = true }
          if block.type == "tool_result" { foundToolResult = true }
        } else {
          _ = try? array.decode(IgnoredField.self)
        }
      }
      hasText = foundText
      hasToolResult = foundToolResult
      return
    }
    hasText = false
    hasToolResult = false
  }
}

private struct ContentBlock: Decodable {
  let type: String?
}

private struct IgnoredField: Decodable {
  init(from decoder: Decoder) throws {}
}

/// A pure parser for Claude Code JSONL transcripts.
public struct ClaudeTranscriptParser: Sendable {
  public static let inactivityThreshold: TimeInterval = 1800

  private static let knownTypes: Set<String> = [
    "user", "assistant", "system", "custom-title", "queue-operation", "attachment",
    "file-history-snapshot", "file-history-delta", "atis-latch", "last-prompt", "ai-title",
    "cost-state", "api-request-shape", "api-request-blob", "api-request", "tools-used",
    "mode", "permission-mode", "frame-link", "artifact-comment-monitor",
    "artifact-autoreact-ledger",
  ]

  public init() {}

  public static func parseISO8601Date(_ string: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: string) { return date }
    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    return basic.date(from: string)
  }

  public static func extractProjectName(from cwd: String) -> String {
    let cleaned = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n\r"))
    guard !cleaned.isEmpty else { return "" }
    guard let last = cleaned.split(separator: "/").last else { return "" }
    return String(last)
  }

  public static func sanitizeTitle(_ rawTitle: String) -> String {
    String(rawTitle.prefix(80))
  }

  public static func applyInactivity(to snapshot: SessionSnapshot?, now: Date) -> SessionSnapshot? {
    guard var snapshot else { return nil }
    if snapshot.state != .finished,
      now.timeIntervalSince(snapshot.lastActivity) >= inactivityThreshold
    {
      snapshot.state = .finished
      snapshot.waitingSince = nil
    }
    return snapshot
  }

  public func applyInactivity(to snapshot: SessionSnapshot?, now: Date) -> SessionSnapshot? {
    Self.applyInactivity(to: snapshot, now: now)
  }

  public func parse(
    _ lines: [JSONLLine],
    current: SessionSnapshot?,
    now: Date
  ) -> (snapshot: SessionSnapshot?, skippedLines: Int) {
    var snapshot = current
    var skippedCount = 0
    let decoder = JSONDecoder()

    for line in lines {
      guard let record = try? decoder.decode(TranscriptRecord.self, from: line.bytes),
        let recordType = record.type,
        Self.knownTypes.contains(recordType)
      else {
        skippedCount += 1
        continue
      }

      var recordDate: Date?
      if let timestampString = record.timestamp {
        guard let parsedDate = Self.parseISO8601Date(timestampString) else {
          skippedCount += 1
          continue
        }
        recordDate = parsedDate
      }

      snapshot = updateSnapshot(
        snapshot: snapshot,
        record: record,
        recordType: recordType,
        recordDate: recordDate,
        now: now
      )
    }

    if let existing = snapshot {
      snapshot = Self.applyInactivity(to: existing, now: now)
    }
    return (snapshot: snapshot, skippedLines: skippedCount)
  }

  public func parse(
    lines: [JSONLLine],
    current: SessionSnapshot?,
    now: Date
  ) -> (snapshot: SessionSnapshot?, skippedLines: Int) {
    parse(lines, current: current, now: now)
  }
}

extension ClaudeTranscriptParser: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public var description: String { "ClaudeTranscriptParser()" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension ClaudeTranscriptParser {
  private func updateSnapshot(
    snapshot: SessionSnapshot?,
    record: TranscriptRecord,
    recordType: String,
    recordDate: Date?,
    now: Date
  ) -> SessionSnapshot? {
    if record.isSidechain == true {
      return applySidechainRecord(snapshot: snapshot, date: recordDate)
    }
    switch recordType {
    case "user":
      return applyUserRecord(snapshot: snapshot, record: record, date: recordDate, now: now)
    case "assistant":
      return applyAssistantRecord(snapshot: snapshot, record: record, date: recordDate, now: now)
    case "system":
      return applySystemRecord(snapshot: snapshot, record: record, date: recordDate, now: now)
    case "custom-title":
      return applyCustomTitleRecord(snapshot: snapshot, record: record, date: recordDate, now: now)
    default:
      return applyOtherRecord(snapshot: snapshot, record: record, date: recordDate)
    }
  }

  private func applySidechainRecord(snapshot: SessionSnapshot?, date: Date?) -> SessionSnapshot? {
    guard var current = snapshot else { return nil }
    if let date { current.lastActivity = max(current.lastActivity, date) }
    return current
  }

  private func applyUserRecord(
    snapshot: SessionSnapshot?,
    record: TranscriptRecord,
    date: Date?,
    now: Date
  ) -> SessionSnapshot? {
    let isTool = record.hasToolUseResult || (record.message?.content?.hasToolResult == true)
    let isPrompt = (record.message?.content?.hasText == true) && !isTool
    guard isPrompt || isTool else {
      return applyOtherRecord(snapshot: snapshot, record: record, date: date)
    }

    let effectiveDate = date ?? .distantPast
    var current: SessionSnapshot
    if let snapshot {
      current = snapshot
    } else {
      guard let sessionId = record.sessionId, !sessionId.isEmpty else { return nil }
      current = SessionSnapshot(
        id: sessionId,
        agent: .claudeCode,
        state: .running,
        projectName: record.cwd.map(Self.extractProjectName(from:)) ?? "",
        title: nil,
        lastActivity: effectiveDate,
        waitingSince: nil,
        cwd: record.cwd
      )
    }
    current.state = .running
    current.waitingSince = nil
    if let date { current.lastActivity = max(current.lastActivity, date) }
    if let cwd = record.cwd {
      let projectName = Self.extractProjectName(from: cwd)
      if !projectName.isEmpty { current.projectName = projectName }
      current.cwd = cwd
    }
    return current
  }

  private func applyAssistantRecord(
    snapshot: SessionSnapshot?,
    record: TranscriptRecord,
    date: Date?,
    now: Date
  ) -> SessionSnapshot? {
    let stopReason = record.message?.stopReason
    let effectiveDate = date ?? .distantPast

    var current: SessionSnapshot
    if let snapshot {
      current = snapshot
    } else {
      guard let sessionId = record.sessionId, !sessionId.isEmpty else { return nil }
      let initialWaiting = (stopReason == "end_turn") ? effectiveDate : nil
      current = SessionSnapshot(
        id: sessionId,
        agent: .claudeCode,
        state: (stopReason == "end_turn") ? .waitingForInput : .running,
        projectName: record.cwd.map(Self.extractProjectName(from:)) ?? "",
        title: nil,
        lastActivity: effectiveDate,
        waitingSince: initialWaiting,
        cwd: record.cwd
      )
    }
    if stopReason == "tool_use" {
      current.state = .running
      current.waitingSince = nil
    } else if stopReason == "end_turn", current.state != .waitingForInput {
      current.state = .waitingForInput
      current.waitingSince = effectiveDate
    }
    if let cwd = record.cwd {
      let projectName = Self.extractProjectName(from: cwd)
      if !projectName.isEmpty { current.projectName = projectName }
      current.cwd = cwd
    }
    if let date { current.lastActivity = max(current.lastActivity, date) }
    return current
  }

  private func applySystemRecord(
    snapshot: SessionSnapshot?,
    record: TranscriptRecord,
    date: Date?,
    now: Date
  ) -> SessionSnapshot? {
    guard record.subtype == "turn_duration" else {
      return applyOtherRecord(snapshot: snapshot, record: record, date: date)
    }
    let effectiveDate = date ?? .distantPast
    var current: SessionSnapshot
    if let snapshot {
      current = snapshot
    } else {
      guard let sessionId = record.sessionId, !sessionId.isEmpty else { return nil }
      current = SessionSnapshot(
        id: sessionId,
        agent: .claudeCode,
        state: .waitingForInput,
        projectName: record.cwd.map(Self.extractProjectName(from:)) ?? "",
        title: nil,
        lastActivity: effectiveDate,
        waitingSince: effectiveDate,
        cwd: record.cwd
      )
    }
    if current.state != .waitingForInput {
      current.state = .waitingForInput
      current.waitingSince = effectiveDate
    }
    if let cwd = record.cwd {
      let projectName = Self.extractProjectName(from: cwd)
      if !projectName.isEmpty { current.projectName = projectName }
      current.cwd = cwd
    }
    if let date { current.lastActivity = max(current.lastActivity, date) }
    return current
  }

  private func applyCustomTitleRecord(
    snapshot: SessionSnapshot?,
    record: TranscriptRecord,
    date: Date?,
    now: Date
  ) -> SessionSnapshot? {
    guard let title = record.customTitle else {
      return applyOtherRecord(snapshot: snapshot, record: record, date: date)
    }
    let sanitized = Self.sanitizeTitle(title)
    let effectiveDate = date ?? .distantPast
    var current: SessionSnapshot
    if let snapshot {
      current = snapshot
    } else {
      guard let sessionId = record.sessionId, !sessionId.isEmpty else { return nil }
      current = SessionSnapshot(
        id: sessionId,
        agent: .claudeCode,
        state: .waitingForInput,
        projectName: record.cwd.map(Self.extractProjectName(from:)) ?? "",
        title: sanitized,
        lastActivity: effectiveDate,
        waitingSince: effectiveDate,
        cwd: record.cwd
      )
    }
    current.title = sanitized
    if let cwd = record.cwd {
      let projectName = Self.extractProjectName(from: cwd)
      if !projectName.isEmpty { current.projectName = projectName }
      current.cwd = cwd
    }
    if let date { current.lastActivity = max(current.lastActivity, date) }
    return current
  }

  private func applyOtherRecord(
    snapshot: SessionSnapshot?,
    record: TranscriptRecord? = nil,
    date: Date?
  ) -> SessionSnapshot? {
    guard var current = snapshot else { return nil }
    if let date { current.lastActivity = max(current.lastActivity, date) }
    if let cwd = record?.cwd {
      let projectName = Self.extractProjectName(from: cwd)
      if !projectName.isEmpty { current.projectName = projectName }
      current.cwd = cwd
    }
    return current
  }
}

extension SessionSnapshot {
  public mutating func applyInactivity(now: Date) {
    if state != .finished,
      now.timeIntervalSince(lastActivity) >= ClaudeTranscriptParser.inactivityThreshold
    {
      state = .finished
      waitingSince = nil
    }
  }

  public func applyingInactivity(now: Date) -> SessionSnapshot {
    var copy = self
    copy.applyInactivity(now: now)
    return copy
  }
}
