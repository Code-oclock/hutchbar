// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Project information resolved for a Gemini CLI session.
public struct GeminiProjectInfo: Equatable, Sendable {
  public let projectName: String
  public let cwd: String?

  public init(projectName: String, cwd: String? = nil) {
    self.projectName = projectName
    self.cwd = cwd
  }
}

/// Pure parser for Gemini CLI session files (`session-*.json`).
public enum GeminiSessionParser {
  /// Inactivity timeout (30 minutes) after which an active session transitions to finished.
  public static let inactivityTimeout: TimeInterval = 30 * 60

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
    guard !trimmed.isEmpty else { return "gemini" }
    var url = URL(fileURLWithPath: trimmed)
    while url.pathComponents.count > 1 && url.lastPathComponent.isEmpty {
      url.deleteLastPathComponent()
    }
    let last = url.lastPathComponent
    return (last.isEmpty || last == "/") ? trimmed : last
  }

  public static func is64Hex(_ string: String) -> Bool {
    string.count == 64 && string.allSatisfy(\.isHexDigit)
  }

  public static func resolveProject(
    projectDirName: String,
    projectRootContent: String? = nil
  ) -> GeminiProjectInfo {
    if let content = projectRootContent {
      let lines = content.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if let firstLine = lines.first {
        let projectName = extractProjectName(from: firstLine)
        return GeminiProjectInfo(projectName: projectName, cwd: firstLine)
      }
    }

    if is64Hex(projectDirName) {
      return GeminiProjectInfo(projectName: "gemini", cwd: nil)
    } else {
      return GeminiProjectInfo(projectName: projectDirName, cwd: nil)
    }
  }

  public static func parse(
    data: Data,
    filePath: String,
    projectInfo: GeminiProjectInfo,
    fileMtime: Date? = nil,
    now: Date
  ) -> SessionSnapshot? {
    let decoder = JSONDecoder()
    guard let record = try? decoder.decode(GeminiSessionRecord.self, from: data) else {
      return nil
    }

    let candidateId = record.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedId: String
    if let candidateId, !candidateId.isEmpty {
      resolvedId = candidateId
    } else {
      let fallback = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
      resolvedId = fallback.isEmpty ? "gemini" : fallback
    }

    let messages = record.messages ?? []
    let rootLastUpdated = record.lastUpdated.flatMap(parseDate)
    let lastMessage = messages.last
    let lastMessageDate = lastMessage?.timestamp.flatMap(parseDate)

    let lastActivity = rootLastUpdated ?? lastMessageDate ?? fileMtime ?? now

    let stateAndWaiting: (state: SessionState, waitingSince: Date?)
    if let lastMessage {
      stateAndWaiting = resolveMessageState(
        lastMessage: lastMessage, fileMtime: fileMtime, now: now)
    } else {
      let startDate = record.startTime.flatMap(parseDate)
      stateAndWaiting = (.waitingForInput, startDate ?? fileMtime ?? now)
    }

    let snapshot = SessionSnapshot(
      id: resolvedId,
      agent: .geminiCLI,
      state: stateAndWaiting.state,
      projectName: projectInfo.projectName,
      title: nil,
      lastActivity: lastActivity,
      waitingSince: stateAndWaiting.waitingSince,
      cwd: projectInfo.cwd,
      parentKey: nil,
      childKind: nil
    )

    let finalSnapshot: SessionSnapshot = applyInactivityRule(to: snapshot, now: now)
    return finalSnapshot
  }

  public static func parse(
    data: Data,
    fileURL: URL,
    projectInfo: GeminiProjectInfo,
    fileMtime: Date? = nil,
    now: Date
  ) -> SessionSnapshot? {
    parse(
      data: data,
      filePath: fileURL.path,
      projectInfo: projectInfo,
      fileMtime: fileMtime,
      now: now
    )
  }

  private static func resolveMessageState(
    lastMessage: GeminiMessageRecord,
    fileMtime: Date?,
    now: Date
  ) -> (state: SessionState, waitingSince: Date?) {
    let msgType = lastMessage.type?.lowercased()
    let msgDate = lastMessage.timestamp.flatMap(parseDate) ?? fileMtime ?? now

    switch msgType {
    case "user":
      return (.running, nil)
    case "gemini":
      let toolCalls = lastMessage.toolCalls ?? []
      if toolCalls.contains(where: { $0.status?.lowercased() == "awaiting_approval" }) {
        return (.waitingForApproval, msgDate)
      }
      if toolCalls.contains(where: {
        let status = $0.status?.lowercased()
        return status == "validating" || status == "scheduled" || status == "executing"
      }) {
        return (.running, nil)
      }
      return (.waitingForInput, msgDate)
    case "info", "error", "warning":
      return (.waitingForInput, msgDate)
    default:
      return (.waitingForInput, msgDate)
    }
  }

  public static func applyInactivityRule(
    to snapshot: SessionSnapshot,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot {
    guard snapshot.state != .finished,
      now.timeIntervalSince(snapshot.lastActivity) >= timeout
    else {
      return snapshot
    }
    var updated = snapshot
    updated.state = .finished
    updated.waitingSince = nil
    return updated
  }

  public static func applyInactivityRule(
    to optionalSnapshot: SessionSnapshot?,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot? {
    guard let snapshot = optionalSnapshot else { return nil }
    let updated: SessionSnapshot = applyInactivityRule(to: snapshot, now: now, timeout: timeout)
    return updated
  }
}

// MARK: - Decodable models

private struct GeminiSessionRecord: Decodable {
  let sessionId: String?
  let startTime: String?
  let lastUpdated: String?
  let messages: [GeminiMessageRecord]?

  init(
    sessionId: String? = nil,
    startTime: String? = nil,
    lastUpdated: String? = nil,
    messages: [GeminiMessageRecord]? = nil
  ) {
    self.sessionId = sessionId
    self.startTime = startTime
    self.lastUpdated = lastUpdated
    self.messages = messages
  }
}

private struct GeminiMessageRecord: Decodable {
  let id: String?
  let timestamp: String?
  let type: String?
  let toolCalls: [GeminiToolCallRecord]?

  init(
    id: String? = nil,
    timestamp: String? = nil,
    type: String? = nil,
    toolCalls: [GeminiToolCallRecord]? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.type = type
    self.toolCalls = toolCalls
  }
}

private struct GeminiToolCallRecord: Decodable {
  let status: String?

  init(status: String? = nil) {
    self.status = status
  }
}
