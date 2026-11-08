// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

/// Reads Claude subscription quotas from claude-code-router's SQLite database.
public struct CcrQuotaReader: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public let databasePath: String

  public static var defaultDatabasePath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/claude-code-router/ccr.db")
      .path
  }

  public var description: String { "CcrQuotaReader" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(self, children: ["summary": description])
  }

  public init(databasePath: String = CcrQuotaReader.defaultDatabasePath) {
    self.databasePath = databasePath
  }

  public func read(now: Date = Date()) -> [AccountQuota] {
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
      return []
    }
    defer {
      sqlite3_close_v2(database)
    }

    sqlite3_busy_timeout(database, 200)

    let query = """
      SELECT account_name, observed_at, five_hour_utilization, five_hour_resets_at, \
      seven_day_utilization, seven_day_resets_at \
      FROM claude_account_quotas;
      """

    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, query, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
      if let statement {
        sqlite3_finalize(statement)
      }
      return []
    }
    defer {
      sqlite3_finalize(statement)
    }

    let parser = QuotaRowParser()
    var quotas: [AccountQuota] = []

    while true {
      let stepResult = sqlite3_step(statement)
      if stepResult == SQLITE_ROW {
        if let quota = parser.parseRow(statement: statement, now: now) {
          quotas.append(quota)
        }
      } else if stepResult == SQLITE_DONE {
        break
      } else {
        return []
      }
    }

    return quotas
  }
}

private struct QuotaRowParser {
  private let fractionalFormatter: ISO8601DateFormatter
  private let standardFormatter: ISO8601DateFormatter

  init() {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.fractionalFormatter = fractional

    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    self.standardFormatter = standard
  }

  func parseRow(statement: OpaquePointer?, now: Date) -> AccountQuota? {
    guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
      let namePointer = sqlite3_column_text(statement, 0)
    else {
      return nil
    }
    let accountName = String(cString: namePointer)
    guard !accountName.isEmpty else { return nil }

    let observedAt = parseDate(statement: statement, columnIndex: 1) ?? now
    var windows: [QuotaWindow] = []

    if let fiveHour = columnDouble(statement: statement, columnIndex: 2) {
      let resetsAt = parseDate(statement: statement, columnIndex: 3)
      windows.append(
        QuotaWindow(
          windowMinutes: 300,
          usedPercent: fiveHour * 100.0,
          resetsAt: resetsAt
        )
      )
    }

    if let sevenDay = columnDouble(statement: statement, columnIndex: 4) {
      let resetsAt = parseDate(statement: statement, columnIndex: 5)
      windows.append(
        QuotaWindow(
          windowMinutes: 10080,
          usedPercent: sevenDay * 100.0,
          resetsAt: resetsAt
        )
      )
    }

    return AccountQuota(
      agent: .claudeCode,
      accountName: accountName,
      windows: windows,
      observedAt: observedAt,
      source: .ccr
    )
  }

  private func parseDate(statement: OpaquePointer?, columnIndex: Int32) -> Date? {
    guard sqlite3_column_type(statement, columnIndex) != SQLITE_NULL,
      let pointer = sqlite3_column_text(statement, columnIndex)
    else {
      return nil
    }
    let trimmed = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return fractionalFormatter.date(from: trimmed) ?? standardFormatter.date(from: trimmed)
  }

  private func columnDouble(statement: OpaquePointer?, columnIndex: Int32) -> Double? {
    guard sqlite3_column_type(statement, columnIndex) != SQLITE_NULL else { return nil }
    let value = sqlite3_column_double(statement, columnIndex)
    guard !value.isNaN else { return nil }
    return value
  }
}
