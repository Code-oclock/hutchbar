// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import HutchbarCore
import SQLite3
import Testing

private enum TestDatabaseError: Error, CustomStringConvertible {
  case cannotOpenDatabase
  case executionFailed

  var description: String {
    switch self {
    case .cannotOpenDatabase: "Failed to open SQLite database for test."
    case .executionFailed: "Failed to execute SQL statement in test."
    }
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return directory
}

private func executeSQL(databasePath: String, sql: String) throws {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(
    databasePath,
    &database,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
    nil
  )
  guard openResult == SQLITE_OK, let database else {
    if let database {
      sqlite3_close_v2(database)
    }
    throw TestDatabaseError.cannotOpenDatabase
  }
  defer {
    sqlite3_close_v2(database)
  }

  var errorMessage: UnsafeMutablePointer<CChar>?
  let execResult = sqlite3_exec(database, sql, nil, nil, &errorMessage)
  if let errorMessage {
    sqlite3_free(errorMessage)
  }
  guard execResult == SQLITE_OK else {
    throw TestDatabaseError.executionFailed
  }
}

private let createTableSQL = """
  CREATE TABLE claude_account_quotas (
    account_name TEXT PRIMARY KEY,
    observed_at TEXT,
    five_hour_utilization REAL,
    five_hour_resets_at TEXT,
    seven_day_utilization REAL,
    seven_day_resets_at TEXT
  );
  """

@Test func parsesQuotasWithFractionalSecondsAndStandardRFC3339() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let dbPath = directory.appendingPathComponent("ccr.db").path
  try executeSQL(databasePath: dbPath, sql: createTableSQL)

  let insertSQL = """
    INSERT INTO claude_account_quotas (
      account_name, observed_at, five_hour_utilization, five_hour_resets_at,
      seven_day_utilization, seven_day_resets_at
    ) VALUES
    ('pro-1', '2026-11-04T16:02:19.388720000Z', 0.34, '2026-11-04T21:00:00.000000000Z',
     0.51, '2026-11-05T10:00:00.000000000Z'),
    ('pro-2', '2026-11-04T16:02:19Z', 0.0, '2026-11-04T21:00:00Z',
     1.0, '2026-11-05T10:00:00Z');
    """
  try executeSQL(databasePath: dbPath, sql: insertSQL)

  let fallbackDate = Date(timeIntervalSince1970: 1_000_000)
  let reader = CcrQuotaReader(databasePath: dbPath)
  let quotas = reader.read(now: fallbackDate)

  #expect(quotas.count == 2)

  let firstQuota = quotas.first { $0.accountName == "pro-1" }
  guard let firstQuota else {
    Issue.record("Missing pro-1 quota")
    return
  }
  #expect(firstQuota.agent == .claudeCode)
  #expect(firstQuota.id == "claudeCode:pro-1")
  #expect(firstQuota.windows.count == 2)

  let firstFiveHour = firstQuota.windows.first { $0.windowMinutes == 300 }
  guard let firstFiveHour else {
    Issue.record("Missing 5h window for pro-1")
    return
  }
  #expect(firstFiveHour.usedPercent == 34.0)
  #expect(firstFiveHour.resetsAt != nil)

  let firstSevenDay = firstQuota.windows.first { $0.windowMinutes == 10080 }
  guard let firstSevenDay else {
    Issue.record("Missing 7d window for pro-1")
    return
  }
  #expect(firstSevenDay.usedPercent == 51.0)
  #expect(firstSevenDay.resetsAt != nil)

  let secondQuota = quotas.first { $0.accountName == "pro-2" }
  guard let secondQuota else {
    Issue.record("Missing pro-2 quota")
    return
  }
  #expect(secondQuota.agent == .claudeCode)
  #expect(secondQuota.windows.count == 2)

  let secondFiveHour = secondQuota.windows.first { $0.windowMinutes == 300 }
  guard let secondFiveHour else {
    Issue.record("Missing 5h window for pro-2")
    return
  }
  #expect(secondFiveHour.usedPercent == 0.0)
  #expect(secondFiveHour.resetsAt != nil)

  let secondSevenDay = secondQuota.windows.first { $0.windowMinutes == 10080 }
  guard let secondSevenDay else {
    Issue.record("Missing 7d window for pro-2")
    return
  }
  #expect(secondSevenDay.usedPercent == 100.0)
  #expect(secondSevenDay.resetsAt != nil)
}

@Test func handlesNullAndEmptyValuesGracefully() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let dbPath = directory.appendingPathComponent("ccr.db").path
  try executeSQL(databasePath: dbPath, sql: createTableSQL)

  let insertSQL = """
    INSERT INTO claude_account_quotas (
      account_name, observed_at, five_hour_utilization, five_hour_resets_at,
      seven_day_utilization, seven_day_resets_at
    ) VALUES
    ('empty-dates', '', 0.25, '', 0.75, ''),
    ('null-values', '', NULL, NULL, 0.85, NULL),
    ('all-nulls', '', NULL, NULL, NULL, NULL),
    ('', '2026-11-04T16:02:19Z', 0.5, '', 0.5, '');
    """
  try executeSQL(databasePath: dbPath, sql: insertSQL)

  let fallbackDate = Date(timeIntervalSince1970: 1_700_000_000)
  let reader = CcrQuotaReader(databasePath: dbPath)
  let quotas = reader.read(now: fallbackDate)

  #expect(quotas.count == 3)

  let emptyDates = quotas.first { $0.accountName == "empty-dates" }
  guard let emptyDates else {
    Issue.record("Missing empty-dates quota")
    return
  }
  #expect(emptyDates.observedAt == fallbackDate)
  #expect(emptyDates.windows.count == 2)
  #expect(emptyDates.windows[0].windowMinutes == 300)
  #expect(emptyDates.windows[0].usedPercent == 25.0)
  #expect(emptyDates.windows[0].resetsAt == nil)
  #expect(emptyDates.windows[1].windowMinutes == 10080)
  #expect(emptyDates.windows[1].usedPercent == 75.0)
  #expect(emptyDates.windows[1].resetsAt == nil)

  let nullValues = quotas.first { $0.accountName == "null-values" }
  guard let nullValues else {
    Issue.record("Missing null-values quota")
    return
  }
  #expect(nullValues.observedAt == fallbackDate)
  #expect(nullValues.windows.count == 1)
  #expect(nullValues.windows[0].windowMinutes == 10080)
  #expect(nullValues.windows[0].usedPercent == 85.0)
  #expect(nullValues.windows[0].resetsAt == nil)

  let allNulls = quotas.first { $0.accountName == "all-nulls" }
  guard let allNulls else {
    Issue.record("Missing all-nulls quota")
    return
  }
  #expect(allNulls.observedAt == fallbackDate)
  #expect(allNulls.windows.isEmpty)
}

@Test func missingDatabaseFileReturnsEmpty() {
  let reader = CcrQuotaReader(databasePath: "/private/tmp/nonexistent-\(UUID().uuidString).db")
  let quotas = reader.read()
  #expect(quotas.isEmpty)
}

@Test func missingTableReturnsEmpty() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let dbPath = directory.appendingPathComponent("other.db").path
  let otherTableSQL = "CREATE TABLE unrelated_table (id INTEGER PRIMARY KEY, name TEXT);"
  try executeSQL(databasePath: dbPath, sql: otherTableSQL)

  let reader = CcrQuotaReader(databasePath: dbPath)
  #expect(reader.read().isEmpty)
}

@Test func lockedDatabaseReturnsEmpty() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let dbPath = directory.appendingPathComponent("locked.db").path
  try executeSQL(databasePath: dbPath, sql: createTableSQL)

  let insertSQL = """
    INSERT INTO claude_account_quotas (
      account_name, observed_at, five_hour_utilization, five_hour_resets_at,
      seven_day_utilization, seven_day_resets_at
    ) VALUES ('locked-account', '2026-11-04T16:02:19Z', 0.5, '', 0.5, '');
    """
  try executeSQL(databasePath: dbPath, sql: insertSQL)

  var writerDb: OpaquePointer?
  let openResult = sqlite3_open_v2(
    dbPath,
    &writerDb,
    SQLITE_OPEN_READWRITE,
    nil
  )
  #expect(openResult == SQLITE_OK)
  guard let writerDb else {
    Issue.record("Failed to open writer DB")
    return
  }
  defer {
    sqlite3_close_v2(writerDb)
  }

  let beginResult = sqlite3_exec(writerDb, "BEGIN EXCLUSIVE;", nil, nil, nil)
  #expect(beginResult == SQLITE_OK)

  let reader = CcrQuotaReader(databasePath: dbPath)
  let lockedQuotas = reader.read()
  #expect(lockedQuotas.isEmpty)

  let rollbackResult = sqlite3_exec(writerDb, "ROLLBACK;", nil, nil, nil)
  #expect(rollbackResult == SQLITE_OK)

  let unlockedQuotas = reader.read()
  #expect(unlockedQuotas.count == 1)
}

@Test func databaseFileIsUnchangedAfterRead() throws {
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let dbPath = directory.appendingPathComponent("stat.db").path
  try executeSQL(databasePath: dbPath, sql: createTableSQL)

  let insertSQL = """
    INSERT INTO claude_account_quotas (
      account_name, observed_at, five_hour_utilization, five_hour_resets_at,
      seven_day_utilization, seven_day_resets_at
    ) VALUES ('pro-stat', '2026-11-04T16:02:19Z', 0.2, '', 0.4, '');
    """
  try executeSQL(databasePath: dbPath, sql: insertSQL)

  var infoBefore = stat()
  #expect(stat(dbPath, &infoBefore) == 0)

  let reader = CcrQuotaReader(databasePath: dbPath)
  let quotas = reader.read()
  #expect(quotas.count == 1)

  var infoAfter = stat()
  #expect(stat(dbPath, &infoAfter) == 0)

  #expect(infoAfter.st_size == infoBefore.st_size)
  #expect(infoAfter.st_mtimespec.tv_sec == infoBefore.st_mtimespec.tv_sec)
  #expect(infoAfter.st_mtimespec.tv_nsec == infoBefore.st_mtimespec.tv_nsec)
}

@Test func privacyDescriptionsAndErrorsNeverContainFixtureContent() throws {
  let secret = "SENSITIVE-FIXTURE-TOKEN-SECRET"
  let directory = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let dbPath = directory.appendingPathComponent("secret-\(secret).db").path
  try executeSQL(databasePath: dbPath, sql: createTableSQL)

  let insertSQL = """
    INSERT INTO claude_account_quotas (
      account_name, observed_at, five_hour_utilization, five_hour_resets_at,
      seven_day_utilization, seven_day_resets_at
    ) VALUES ('\(secret)', '2026-11-04T16:02:19Z', 0.1, '', 0.2, '');
    """
  try executeSQL(databasePath: dbPath, sql: insertSQL)

  let reader = CcrQuotaReader(databasePath: dbPath)

  for descriptionValue in [
    String(describing: reader),
    String(reflecting: reader),
  ] {
    #expect(!descriptionValue.contains(secret))
    #expect(!descriptionValue.contains(dbPath))
  }

  var dumped = ""
  dump(reader, to: &dumped)
  #expect(!dumped.contains(secret))
  #expect(!dumped.contains(dbPath))

  let testError = TestDatabaseError.executionFailed
  #expect(!testError.description.contains(secret))
  #expect(!String(describing: testError).contains(secret))
  #expect(!String(reflecting: testError).contains(secret))
}

@Test func defaultDatabasePathResolvesUnderHomeDirectory() {
  let defaultPath = CcrQuotaReader.defaultDatabasePath
  let homePath = FileManager.default.homeDirectoryForCurrentUser.path
  #expect(defaultPath.hasPrefix(homePath))
  #expect(defaultPath.hasSuffix(".local/share/claude-code-router/ccr.db"))

  let reader = CcrQuotaReader()
  #expect(reader.databasePath == defaultPath)
}
