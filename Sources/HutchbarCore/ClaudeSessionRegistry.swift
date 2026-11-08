// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Active session metadata decoded from Claude Code's ~/.claude/sessions/<pid>.json.
public struct ClaudeLiveSession: Sendable, Equatable, Decodable {
  public let pid: Int
  public let sessionId: String
  public let cwd: String
  public let status: ClaudeLiveStatus
  public let statusUpdatedAt: Date
  public let procStart: String

  public init(
    pid: Int,
    sessionId: String,
    cwd: String,
    status: ClaudeLiveStatus,
    statusUpdatedAt: Date,
    procStart: String
  ) {
    self.pid = pid
    self.sessionId = sessionId
    self.cwd = cwd
    self.status = status
    self.statusUpdatedAt = statusUpdatedAt
    self.procStart = procStart
  }

  private enum CodingKeys: String, CodingKey {
    case pid
    case sessionId
    case cwd
    case status
    case statusUpdatedAt
    case procStart
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.pid = try container.decode(Int.self, forKey: .pid)
    self.sessionId = try container.decode(String.self, forKey: .sessionId)
    self.cwd = try container.decode(String.self, forKey: .cwd)

    let rawStatus = try? container.decode(String.self, forKey: .status)
    switch rawStatus {
    case "busy":
      self.status = .busy
    case "idle":
      self.status = .idle
    default:
      self.status = .unknown
    }

    if let ms = try? container.decode(Int64.self, forKey: .statusUpdatedAt) {
      self.statusUpdatedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
    } else if let ms = try? container.decode(Double.self, forKey: .statusUpdatedAt) {
      self.statusUpdatedAt = Date(timeIntervalSince1970: ms / 1000.0)
    } else {
      throw DecodingError.dataCorruptedError(
        forKey: .statusUpdatedAt,
        in: container,
        debugDescription: "Invalid statusUpdatedAt timestamp"
      )
    }

    if let str = try? container.decode(String.self, forKey: .procStart) {
      self.procStart = str
    } else if let intVal = try? container.decode(Int64.self, forKey: .procStart) {
      self.procStart = String(intVal)
    } else if let dblVal = try? container.decode(Double.self, forKey: .procStart) {
      if dblVal.rounded() == dblVal {
        self.procStart = String(Int64(dblVal))
      } else {
        self.procStart = String(dblVal)
      }
    } else {
      throw DecodingError.dataCorruptedError(
        forKey: .procStart,
        in: container,
        debugDescription: "Invalid procStart value"
      )
    }
  }
}

/// Parser and validator for Claude Code session registry files (~/.claude/sessions/<pid>.json).
public enum ClaudeSessionRegistry {
  /// Maximum accepted size for a session file (64 KiB).
  public static let maxFileSizeBytes: UInt64 = 64 * 1024

  /// Parses session JSON bytes. Fails silently if corrupt, oversized, or missing required fields.
  public static func parse(data: Data) -> ClaudeLiveSession? {
    guard !data.isEmpty, UInt64(data.count) <= maxFileSizeBytes else {
      return nil
    }
    return try? JSONDecoder().decode(ClaudeLiveSession.self, from: data)
  }

  /// Reads and parses a single session file safely via TailFileSystem (rejects symlinks).
  public static func readSession(
    at path: String,
    fileSystem: any TailFileSystem = LocalTailFileSystem()
  ) -> ClaudeLiveSession? {
    guard let file = try? fileSystem.openRegularFile(at: path) else {
      return nil
    }
    defer { file.close() }

    guard let snapshot = try? file.snapshot() else {
      return nil
    }
    guard snapshot.size > 0, snapshot.size <= maxFileSizeBytes else {
      return nil
    }
    guard let data = try? file.read(from: 0, count: Int(snapshot.size)) else {
      return nil
    }
    return parse(data: data)
  }

  /// Parses a process start time representation into a Date.
  /// Handles numeric timestamps (seconds or milliseconds) and ISO 8601 strings.
  public static func parseProcStart(_ procStart: String) -> Date? {
    let trimmed = procStart.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let doubleVal = Double(trimmed) {
      if doubleVal > 100_000_000_000 {
        return Date(timeIntervalSince1970: doubleVal / 1000.0)
      } else {
        return Date(timeIntervalSince1970: doubleVal)
      }
    }

    let isoWithFraction = ISO8601DateFormatter()
    isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoWithFraction.date(from: trimmed) {
      return date
    }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: trimmed) {
      return date
    }

    // Observed format (Claude Code 2026-11): ctime-style UTC, e.g. "Sat Nov  7 13:17:01 2026".
    let ctime = DateFormatter()
    ctime.locale = Locale(identifier: "en_US_POSIX")
    ctime.timeZone = TimeZone(identifier: "UTC")
    ctime.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    let collapsed = trimmed.split(separator: " ", omittingEmptySubsequences: true).joined(
      separator: " ")
    return ctime.date(from: collapsed)
  }

  /// Verifies process liveness via ProcessTable.
  /// PID must exist and its start time must match procStart within tolerance to prevent PID reuse.
  public static func isProcessAlive(
    pid: Int,
    procStart: String,
    table: any ProcessTable
  ) -> Bool {
    guard let proc = table.allProcesses().first(where: { $0.pid == pid_t(pid) }) else {
      return false
    }
    guard let expectedDate = parseProcStart(procStart) else {
      return false
    }
    let diff = abs(proc.startTime.timeIntervalSince1970 - expectedDate.timeIntervalSince1970)
    return diff <= 2.0
  }

  /// Convenience wrapper to check liveness for a decoded ClaudeLiveSession.
  public static func isAlive(
    session: ClaudeLiveSession,
    table: any ProcessTable
  ) -> Bool {
    isProcessAlive(pid: session.pid, procStart: session.procStart, table: table)
  }

  /// Discovers and reads all valid session files in the given directory.
  public static func discoverSessions(
    in directoryPath: String,
    directoryLister: any DirectoryLister = LocalDirectoryLister(),
    fileSystem: any TailFileSystem = LocalTailFileSystem()
  ) -> [ClaudeLiveSession] {
    let resolved = (directoryPath as NSString).expandingTildeInPath
    guard let entries = try? directoryLister.contentsOfDirectory(atPath: resolved) else {
      return []
    }
    var sessions: [ClaudeLiveSession] = []
    for entry in entries where !entry.isDirectory && entry.path.hasSuffix(".json") {
      if let session = readSession(at: entry.path, fileSystem: fileSystem) {
        sessions.append(session)
      }
    }
    return sessions
  }
}
