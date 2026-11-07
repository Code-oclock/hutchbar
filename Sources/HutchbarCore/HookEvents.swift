// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Kinds of events reported by Claude Code hooks.
public enum HookEventKind: String, Sendable, Codable, CaseIterable, Equatable {
  case approval
  case idle
  case stop
  case prompt
  case end
}

/// A content-free event received from a Claude Code hook.
/// Never holds prompts, code, tool output, or directory paths.
public struct HookEvent: Equatable, Sendable, Codable {
  public let ts: Date
  public let session: String
  public let kind: HookEventKind

  public init(ts: Date, session: String, kind: HookEventKind) {
    self.ts = ts
    self.session = session
    self.kind = kind
  }
}

extension HookEvent: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String {
    "HookEvent(\(kind.rawValue), session: \(session))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "kind": kind.rawValue,
        "session": session,
        "ts": ts,
      ]
    )
  }
}

private struct RawHookInput: Decodable {
  let sessionId: String?
  let hookEventName: String?
  let notificationType: String?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case altSessionId = "sessionId"
    case hookEventName = "hook_event_name"
    case notificationType = "notification_type"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let primaryId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
    let fallbackId = try? container.decodeIfPresent(String.self, forKey: .altSessionId)
    self.sessionId = primaryId ?? fallbackId
    self.hookEventName = try? container.decodeIfPresent(String.self, forKey: .hookEventName)
    self.notificationType = try? container.decodeIfPresent(String.self, forKey: .notificationType)
  }
}

/// Parses Claude Code hook stdin JSON into a HookEvent.
/// Rejects stdin payloads exceeding 64 KiB (65,536 bytes).
/// Session ids come from untrusted stdin: accept only short ASCII identifiers.
func isSafeSessionIdentifier(_ value: String) -> Bool {
  guard !value.isEmpty, value.utf8.count <= 128 else { return false }
  return value.utf8.allSatisfy { byte in
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
      || (byte >= 0x61 && byte <= 0x7A)
      || byte == 0x2D || byte == 0x5F
  }
}

public func makeHookEvent(stdin: Data, now: Date = Date()) -> HookEvent? {
  guard stdin.count <= 64 * 1024, !stdin.isEmpty else { return nil }
  guard let payload = try? JSONDecoder().decode(RawHookInput.self, from: stdin) else {
    return nil
  }
  guard let rawSession = payload.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
    isSafeSessionIdentifier(rawSession)
  else {
    return nil
  }
  guard let eventName = payload.hookEventName else { return nil }

  let kind: HookEventKind
  switch eventName {
  case "Notification":
    switch payload.notificationType {
    case "permission_prompt":
      kind = .approval
    case "idle_prompt":
      kind = .idle
    default:
      return nil
    }
  case "Stop":
    kind = .stop
  case "UserPromptSubmit":
    kind = .prompt
  case "SessionEnd":
    kind = .end
  default:
    return nil
  }

  return HookEvent(ts: now, session: rawSession, kind: kind)
}

private func formatISO8601Date(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  return formatter.string(from: date)
}

private func jsonEscapeString(_ string: String) -> String {
  if let data = try? JSONEncoder().encode(string),
    let json = String(data: data, encoding: .utf8)
  {
    return json
  }
  let escaped =
    string
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  return "\"\(escaped)\""
}

/// Encodes a HookEvent into a single-line JSON Data payload of format {"v":1,...}.
public func encode(_ event: HookEvent) -> Data {
  let dateStr = formatISO8601Date(event.ts)
  let sessionStr = jsonEscapeString(event.session)
  let line =
    "{\"v\":1,\"ts\":\"\(dateStr)\",\"session\":\(sessionStr),\"event\":\"\(event.kind.rawValue)\"}"
  return Data(line.utf8)
}

/// Convenience overload for encode(_:).
public func encode(event: HookEvent) -> Data {
  encode(event)
}

private struct WireHookEvent: Decodable {
  let version: Int?
  let ts: String?
  let session: String?
  let event: String?

  enum CodingKeys: String, CodingKey {
    case version = "v"
    case ts, session, event
  }
}

/// Parses a JSONL line from events.jsonl into a HookEvent.
public func parseHookEventLine(_ line: JSONLLine) -> HookEvent? {
  guard !line.bytes.isEmpty else { return nil }
  guard let wire = try? JSONDecoder().decode(WireHookEvent.self, from: line.bytes) else {
    return nil
  }
  guard wire.version == 1 else { return nil }
  guard let tsString = wire.ts,
    let tsDate = ClaudeTranscriptParser.parseISO8601Date(tsString)
  else {
    return nil
  }
  guard let session = wire.session?.trimmingCharacters(in: .whitespacesAndNewlines),
    !session.isEmpty
  else {
    return nil
  }
  guard let eventString = wire.event,
    let kind = HookEventKind(rawValue: eventString)
  else {
    return nil
  }
  return HookEvent(ts: tsDate, session: session, kind: kind)
}

/// Convenience overload for parseHookEventLine(_:).
public func parseHookEventLine(line: JSONLLine) -> HookEvent? {
  parseHookEventLine(line)
}

/// Applies a HookEvent to a SessionSnapshot according to the v0.1 merge rules.
/// Events older than snapshot.lastActivity are ignored.
public func apply(_ event: HookEvent, to snapshot: SessionSnapshot) -> SessionSnapshot {
  guard event.ts >= snapshot.lastActivity else {
    return snapshot
  }
  var updated = snapshot
  updated.lastActivity = max(updated.lastActivity, event.ts)

  switch event.kind {
  case .approval:
    updated.state = .waitingForApproval
    updated.waitingSince = event.ts
  case .idle, .stop:
    if updated.state != .waitingForInput {
      updated.waitingSince = event.ts
    }
    updated.state = .waitingForInput
  case .prompt:
    updated.state = .running
    updated.waitingSince = nil
  case .end:
    updated.state = .finished
    updated.waitingSince = nil
  }

  return updated
}

extension HookEvent {
  public static func make(stdin: Data, now: Date = Date()) -> HookEvent? {
    makeHookEvent(stdin: stdin, now: now)
  }

  public static func parse(line: JSONLLine) -> HookEvent? {
    parseHookEventLine(line)
  }

  public func encode() -> Data {
    HutchbarCore.encode(self)
  }

  public func apply(to snapshot: SessionSnapshot) -> SessionSnapshot {
    HutchbarCore.apply(self, to: snapshot)
  }
}

extension SessionSnapshot {
  public func applying(_ event: HookEvent) -> SessionSnapshot {
    HutchbarCore.apply(event, to: self)
  }

  public mutating func apply(_ event: HookEvent) {
    self = HutchbarCore.apply(event, to: self)
  }
}

// MARK: - Hooks Configuration for Claude Code settings.json

public struct ClaudeHookCommand: Codable, Sendable, Equatable {
  public let type: String
  public let command: String

  public init(type: String = "command", command: String) {
    self.type = type
    self.command = command
  }
}

public struct ClaudeHookEntry: Codable, Sendable, Equatable {
  public let matcher: String?
  public let hooks: [ClaudeHookCommand]

  public init(matcher: String? = nil, command: String) {
    self.matcher = matcher
    self.hooks = [ClaudeHookCommand(type: "command", command: command)]
  }

  enum CodingKeys: String, CodingKey {
    case matcher
    case hooks
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.matcher = try container.decodeIfPresent(String.self, forKey: .matcher)
    self.hooks = try container.decode([ClaudeHookCommand].self, forKey: .hooks)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let matcher {
      try container.encode(matcher, forKey: .matcher)
    }
    try container.encode(hooks, forKey: .hooks)
  }
}

public struct ClaudeHooksCollection: Codable, Sendable, Equatable {
  public let notification: [ClaudeHookEntry]
  public let stop: [ClaudeHookEntry]
  public let userPromptSubmit: [ClaudeHookEntry]
  public let sessionEnd: [ClaudeHookEntry]

  enum CodingKeys: String, CodingKey {
    case notification = "Notification"
    case stop = "Stop"
    case userPromptSubmit = "UserPromptSubmit"
    case sessionEnd = "SessionEnd"
  }

  public init(command: String) {
    self.notification = [
      ClaudeHookEntry(matcher: "permission_prompt|idle_prompt", command: command)
    ]
    self.stop = [ClaudeHookEntry(command: command)]
    self.userPromptSubmit = [ClaudeHookEntry(command: command)]
    self.sessionEnd = [ClaudeHookEntry(command: command)]
  }
}

public struct ClaudeHooksSnippet: Codable, Sendable, Equatable {
  public let hooks: ClaudeHooksCollection

  public init(command: String) {
    self.hooks = ClaudeHooksCollection(command: command)
  }
}

/// Quotes a path for a POSIX shell command line.
func shellQuoted(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Generates the JSON snippet of `hooks` for `~/.claude/settings.json`.
public func generateHooksConfiguration(binaryPath: String) -> String {
  let command = "\(shellQuoted(binaryPath)) --hook"
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
  guard let data = try? encoder.encode(ClaudeHooksSnippet(command: command)),
    let string = String(data: data, encoding: .utf8)
  else { return "{}" }
  return string
}
