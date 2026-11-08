// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

/// Reads OpenCode SQLite usage messages for local spend tracking.
public struct OpenCodeUsageReader: Sendable {
  public let databasePath: String

  public static var defaultDatabasePath: String {
    UsageScanner.defaultOpenCodeDatabasePath
  }

  public init(databasePath: String = OpenCodeUsageReader.defaultDatabasePath) {
    self.databasePath = databasePath
  }

  /// Usage events of assistant replies since `cutoff`; nil when the database could not
  /// be read (locked, corrupt), so the caller keeps what it read before.
  public func readEvents(cutoff: Date, calendar: Calendar) -> [UsageEvent]? {
    let resolvedPath = (databasePath as NSString).expandingTildeInPath
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      resolvedPath,
      &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
      nil
    )
    guard openResult == SQLITE_OK, let database else {
      if let database {
        sqlite3_close_v2(database)
      }
      return nil
    }
    defer {
      sqlite3_close_v2(database)
    }

    sqlite3_busy_timeout(database, 2000)

    let isV2 = checkTableExists(database: database, tableName: "session_v2")
    let query = isV2 ? makeQueryV2() : makeQueryV1()

    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, query, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
      if let statement {
        sqlite3_finalize(statement)
      }
      return nil
    }
    defer {
      sqlite3_finalize(statement)
    }

    let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)
    sqlite3_bind_int64(statement, 1, cutoffMs)

    var events: [UsageEvent] = []
    while true {
      let stepResult = sqlite3_step(statement)
      if stepResult == SQLITE_ROW {
        if let event = parseRow(statement: statement, calendar: calendar) {
          events.append(event)
        }
      } else if stepResult == SQLITE_DONE {
        break
      } else {
        return nil
      }
    }

    return events
  }

  private func checkTableExists(database: OpaquePointer, tableName: String) -> Bool {
    let query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, query, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
      if let statement {
        sqlite3_finalize(statement)
      }
      return false
    }
    defer { sqlite3_finalize(statement) }

    var isFound = false
    let utf8 = tableName.utf8CString
    utf8.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      sqlite3_bind_text(statement, 1, baseAddress, -1, nil)
      let stepResult = sqlite3_step(statement)
      isFound = (stepResult == SQLITE_ROW)
    }
    return isFound
  }

  private static let selectColumns = """
    m.time_created, \
    json_extract(m.data, '$.modelID'), \
    json_extract(m.data, '$.model_id'), \
    CASE WHEN json_type(m.data, '$.model') = 'text' \
      THEN json_extract(m.data, '$.model') ELSE NULL END, \
    json_extract(m.data, '$.model.modelID'), \
    json_extract(m.data, '$.tokens.input'), \
    json_extract(m.data, '$.tokens.output'), \
    json_extract(m.data, '$.tokens.reasoning'), \
    json_extract(m.data, '$.tokens.cache.read'), \
    json_extract(m.data, '$.tokens.cache.write')
    """

  private func makeQueryV2() -> String {
    """
    SELECT \(Self.selectColumns) \
    FROM session_message m \
    WHERE m.type = 'assistant' \
      AND m.time_created >= ? \
      AND json_valid(m.data) = 1 \
    ORDER BY m.time_created ASC \
    LIMIT 200000;
    """
  }

  private func makeQueryV1() -> String {
    """
    SELECT \(Self.selectColumns) \
    FROM message m \
    WHERE json_extract(m.data, '$.role') = 'assistant' \
      AND m.time_created >= ? \
      AND json_valid(m.data) = 1 \
    ORDER BY m.time_created ASC \
    LIMIT 200000;
    """
  }

  private func parseRow(statement: OpaquePointer?, calendar: Calendar) -> UsageEvent? {
    let timeCreatedMs = sqlite3_column_int64(statement, 0)
    let date = Date(timeIntervalSince1970: Double(timeCreatedMs) / 1000.0)

    let candidate1 = columnString(statement, 1)
    let candidate2 = columnString(statement, 2)
    let candidate3 = columnString(statement, 3)
    let candidate4 = columnString(statement, 4)

    guard let model = candidate1 ?? candidate2 ?? candidate3 ?? candidate4,
      !model.isEmpty
    else {
      return nil
    }

    let input = columnInt(statement, 5)
    let baseOutput = columnInt(statement, 6)
    let reasoning = columnInt(statement, 7)
    let cacheRead = columnInt(statement, 8)
    let cacheWrite = columnInt(statement, 9)

    let totalOutput = baseOutput + reasoning
    let totalTokens = input + totalOutput + cacheRead + cacheWrite
    guard totalTokens > 0 else {
      return nil
    }

    let day = calendar.startOfDay(for: date)
    let hour = calendar.component(.hour, from: date)

    let tokens = TokenUsage(
      input: input,
      output: totalOutput,
      cacheWrite5m: cacheWrite,
      cacheWrite1h: 0,
      cacheRead: cacheRead
    )

    return UsageEvent(
      provider: .opencode,
      model: model,
      day: day,
      hour: hour,
      tokens: tokens,
      isFast: false
    )
  }

  private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let textPointer = sqlite3_column_text(statement, index)
    else {
      return nil
    }
    let stringValue = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
    return stringValue.isEmpty ? nil : stringValue
  }

  private func columnInt(_ statement: OpaquePointer?, _ index: Int32) -> Int {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
      return 0
    }
    let value = sqlite3_column_int64(statement, index)
    return value > 0 ? Int(value) : 0
  }
}

extension OpenCodeUsageReader: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public var description: String { "OpenCodeUsageReader" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: ["databasePath": databasePath])
  }
}
