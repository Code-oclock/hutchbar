// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

/// Pure reader for OpenCode sessions from SQLite database.
public struct OpenCodeSessionReader: Sendable {
  public let databasePath: String

  public static var defaultDatabasePath: String {
    UsageScanner.defaultOpenCodeDatabasePath
  }

  public init(databasePath: String = OpenCodeSessionReader.defaultDatabasePath) {
    self.databasePath = databasePath
  }

  /// Reads sessions updated since `cutoff`. Returns empty array if database does not exist.
  /// Returns `nil` on SQLite read errors (e.g. busy, corrupt) so caller preserves prior state.
  public func readSessions(
    cutoff: Date,
    limit: Int = 200,
    now: Date = Date()
  ) -> [SessionSnapshot]? {
    let resolvedPath = (databasePath as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: resolvedPath) else {
      return []
    }

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
    let isV1 = checkTableExists(database: database, tableName: "session")
    guard isV2 || isV1 else {
      return []
    }

    let sessionTable = isV2 ? "session_v2" : "session"
    let messageTable = isV2 ? "session_message" : "message"

    let sessionCols = tableColumns(database: database, tableName: sessionTable)
    let messageCols = tableColumns(database: database, tableName: messageTable)

    let query = buildQuery(
      isV2: isV2,
      sessionTable: sessionTable,
      messageTable: messageTable,
      sessionCols: sessionCols,
      messageCols: messageCols
    )

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
    sqlite3_bind_int64(statement, 2, Int64(limit))

    return executeQuery(statement: statement, now: now)
  }

  private func executeQuery(statement: OpaquePointer, now: Date) -> [SessionSnapshot]? {
    var snapshots: [SessionSnapshot] = []
    while true {
      let stepResult = sqlite3_step(statement)
      if stepResult == SQLITE_ROW {
        if let snapshot = parseRow(statement: statement, now: now) {
          snapshots.append(snapshot)
        }
      } else if stepResult == SQLITE_DONE {
        break
      } else {
        return nil
      }
    }
    return snapshots
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

  private func tableColumns(database: OpaquePointer, tableName: String) -> Set<String> {
    let query = "PRAGMA table_info(\(tableName));"
    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, query, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
      if let statement {
        sqlite3_finalize(statement)
      }
      return []
    }
    defer { sqlite3_finalize(statement) }

    var columns: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let namePtr = sqlite3_column_text(statement, 1) {
        columns.insert(String(cString: namePtr).lowercased())
      }
    }
    return columns
  }

  private func buildQuery(
    isV2: Bool,
    sessionTable: String,
    messageTable: String,
    sessionCols: Set<String>,
    messageCols: Set<String>
  ) -> String {
    let titleExpr = sessionCols.contains("title") ? "s.title" : "NULL"
    let parentExpr = sessionCols.contains("parent_id") ? "s.parent_id" : "NULL"
    let sessionTimeExpr = sessionCols.contains("time_updated") ? "s.time_updated" : "0"

    let roleExpr =
      (isV2 && messageCols.contains("type"))
      ? "m.type"
      : "json_extract(m.data, '$.role')"

    let msgTimeUpdatedExpr = messageCols.contains("time_updated") ? "m.time_updated" : "NULL"
    let msgTimeCreatedExpr = messageCols.contains("time_created") ? "m.time_created" : "NULL"
    let msgOrderExpr =
      messageCols.contains("time_created") ? "m2.time_created DESC" : "m2.rowid DESC"

    let timeFilter = sessionCols.contains("time_updated") ? "s.time_updated >= ?" : "1=1"
    let orderClause = sessionCols.contains("time_updated") ? "s.time_updated DESC" : "s.rowid DESC"

    return """
      SELECT \
        s.id, \
        s.directory, \
        \(titleExpr), \
        \(parentExpr), \
        \(sessionTimeExpr), \
        \(roleExpr), \
        json_extract(m.data, '$.time.completed'), \
        json_extract(m.data, '$.finish'), \
        json_type(m.data, '$.error'), \
        \(msgTimeUpdatedExpr), \
        \(msgTimeCreatedExpr) \
      FROM \(sessionTable) s \
      LEFT JOIN \(messageTable) m ON m.rowid = ( \
        SELECT m2.rowid FROM \(messageTable) m2 \
        WHERE m2.session_id = s.id \
        ORDER BY \(msgOrderExpr), m2.rowid DESC \
        LIMIT 1 \
      ) \
      WHERE \(timeFilter) \
      ORDER BY \(orderClause) \
      LIMIT ?;
      """
  }
}

// MARK: - Row Parsing & State Determination

extension OpenCodeSessionReader {
  private func parseRow(statement: OpaquePointer, now: Date) -> SessionSnapshot? {
    guard let id = columnString(statement, 0), !id.isEmpty else { return nil }

    let directory = columnString(statement, 1)
    let rawTitle = columnString(statement, 2)
    let parentId = columnString(statement, 3)
    let sessionTimeUpdatedMs = sqlite3_column_int64(statement, 4)

    let role = columnString(statement, 5)
    let completedDate = columnDate(statement, 6)
    let finish = columnString(statement, 7)
    let errorType = columnString(statement, 8)
    let messageTimeUpdatedMs = columnInt64OrNil(statement, 9)
    let messageTimeCreatedMs = columnInt64OrNil(statement, 10)

    let sessionDate = parseMsDate(sessionTimeUpdatedMs) ?? now
    let messageDate =
      parseMsDate(messageTimeUpdatedMs ?? 0) ?? parseMsDate(messageTimeCreatedMs ?? 0)

    let (state, waitingSince) = determineState(
      role: role,
      completedDate: completedDate,
      finish: finish,
      errorType: errorType,
      fallbackDate: messageDate ?? sessionDate
    )

    let cwd = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
    let projectName = cwd.flatMap(extractProjectName) ?? "opencode"

    let title: String? = {
      guard let rawTitle else { return nil }
      let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return String(trimmed.prefix(80))
    }()

    let parentKey: SessionKey? = {
      guard let parentId else { return nil }
      let trimmed = parentId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return SessionKey(agent: .opencode, id: trimmed)
    }()
    let childKind: ChildKind? = (parentKey != nil) ? .subagent : nil

    return SessionSnapshot(
      id: id,
      agent: .opencode,
      state: state,
      projectName: projectName,
      title: title,
      lastActivity: sessionDate,
      waitingSince: waitingSince,
      cwd: (cwd?.isEmpty == false) ? cwd : nil,
      parentKey: parentKey,
      childKind: childKind
    )
  }

  private func determineState(
    role: String?,
    completedDate: Date?,
    finish: String?,
    errorType: String?,
    fallbackDate: Date
  ) -> (state: SessionState, waitingSince: Date?) {
    let isUser = (role == "user")
    let isAssistant = (role == "assistant")
    let hasError = (errorType != nil && errorType != "null")

    if isUser {
      return (.running, nil)
    }
    if isAssistant && completedDate == nil {
      return (.running, nil)
    }
    if isAssistant && finish == "tool-calls" && !hasError {
      return (.running, nil)
    }
    let waitDate = completedDate ?? fallbackDate
    return (.waitingForInput, waitDate)
  }

  private func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
      let textPointer = sqlite3_column_text(statement, index)
    else {
      return nil
    }
    let stringValue = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
    return stringValue.isEmpty ? nil : stringValue
  }

  private func columnInt64OrNil(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, index)
  }

  private func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
    let colType = sqlite3_column_type(statement, index)
    if colType == SQLITE_INTEGER {
      let value = sqlite3_column_int64(statement, index)
      return parseMsDate(value)
    }
    if colType == SQLITE_TEXT, let textPointer = sqlite3_column_text(statement, index) {
      let stringValue = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
      if let ms = Int64(stringValue) {
        return parseMsDate(ms)
      }
      return parseIsoDate(stringValue)
    }
    return nil
  }

  private func parseMsDate(_ ms: Int64) -> Date? {
    guard ms > 0 else { return nil }
    if ms > 1_000_000_000_000 {
      return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
    return Date(timeIntervalSince1970: Double(ms))
  }

  private func parseIsoDate(_ string: String) -> Date? {
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

  private func extractProjectName(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "opencode" }
    var url = URL(fileURLWithPath: trimmed)
    while url.pathComponents.count > 1 && url.lastPathComponent.isEmpty {
      url.deleteLastPathComponent()
    }
    let last = url.lastPathComponent
    return (last.isEmpty || last == "/") ? trimmed : last
  }
}
