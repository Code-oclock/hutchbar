// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import HutchbarCore
import SQLite3
import Testing

private func openCodeMakeScanner(
  tempDir: URL, cachePath: String, dbPath: String, now: Date, calendar: Calendar
) -> UsageScanner {
  UsageScanner(
    cacheFilePath: cachePath,
    claudeProjectsRoot: tempDir.appendingPathComponent("claude").path,
    codexSessionsRoot: tempDir.appendingPathComponent("codex").path,
    qwenUsageRoot: tempDir.appendingPathComponent("qwen").path,
    copilotSessionRoot: tempDir.appendingPathComponent("copilot").path,
    openCodeDatabasePath: dbPath,
    directoryLister: OpenCodeTestDirectoryLister(),
    clock: OpenCodeTestClock(date: now),
    calendar: calendar,
    cutoffDays: 35
  )
}

private func openCodeMakeTempDirectory() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func openCodeExecute(database: OpaquePointer, sql: String) throws {
  var errorMessage: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
  if result != SQLITE_OK {
    let errorString = errorMessage.map { ptr in String(cString: ptr) } ?? "Unknown error"
    sqlite3_free(errorMessage)
    throw CocoaError(
      .fileWriteUnknown,
      userInfo: [NSLocalizedDescriptionKey: "sqlite3_exec failed: \(errorString)"]
    )
  }
}

private final class OpenCodeTestClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date) { self.current = date }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }
}

private final class OpenCodeTestDirectoryLister: DirectoryLister, @unchecked Sendable {
  init() {}

  func contentsOfDirectory(atPath path: String) throws -> [FileMetadata] {
    []
  }
}

@Suite("OpenCodeUsageTests")
struct OpenCodeUsageTests {
  @Test func openCodeSchema1ParsesAssistantAndAppliesReasoning() throws {
    let tempDir = try openCodeMakeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("opencode.db").path
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      dbPath,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
      nil
    )
    #expect(openResult == SQLITE_OK)
    let validDb = try #require(database)
    defer { sqlite3_close_v2(validDb) }

    try openCodeExecute(
      database: validDb,
      sql: """
        CREATE TABLE session (id TEXT PRIMARY KEY);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        """
    )

    let nowMs = Int64(1_731_150_000_000)  // Approx 2024-11-09T11:00:00Z
    let assistantData = """
      {"role":"assistant","modelID":"claude-sonnet-4-5",\
      "tokens":{"input":100,"output":50,"reasoning":15,"cache":{"read":20,"write":5}}}
      """
    let userData = """
      {"role":"user","content":"hello world"}
      """
    let zeroData = """
      {"role":"assistant","modelID":"claude-sonnet-4-5",\
      "tokens":{"input":0,"output":0,"reasoning":0}}
      """

    try openCodeExecute(
      database: validDb,
      sql: """
        INSERT INTO message (id, session_id, time_created, data) \
        VALUES ('m1', 's1', \(nowMs), '\(assistantData)');
        INSERT INTO message (id, session_id, time_created, data) \
        VALUES ('m2', 's1', \(nowMs + 1000), '\(userData)');
        INSERT INTO message (id, session_id, time_created, data) \
        VALUES ('m3', 's1', \(nowMs + 2000), '\(zeroData)');
        """
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let reader = OpenCodeUsageReader(databasePath: dbPath)
    let cutoff = Date(timeIntervalSince1970: Double(nowMs - 10_000) / 1000.0)
    let events = try #require(reader.readEvents(cutoff: cutoff, calendar: calendar))

    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.provider == .opencode)
    #expect(event.model == "claude-sonnet-4-5")
    #expect(event.tokens.input == 100)
    #expect(event.tokens.output == 65)  // 50 output + 15 reasoning
    #expect(event.tokens.cacheRead == 20)
    #expect(event.tokens.cacheWrite5m == 5)
  }

  @Test func openCodeSchema2ParsesSessionMessageWithType() throws {
    let tempDir = try openCodeMakeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("opencode.db").path
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      dbPath,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
      nil
    )
    #expect(openResult == SQLITE_OK)
    let validDb = try #require(database)
    defer { sqlite3_close_v2(validDb) }

    try openCodeExecute(
      database: validDb,
      sql: """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, \
        time_created INTEGER, data TEXT);
        """
    )

    let nowMs = Int64(1_731_150_000_000)
    let assistantData = """
      {"model":"gpt-4o","tokens":{"input":200,"output":80,"reasoning":0}}
      """
    let userData = """
      {"content":"test message"}
      """

    try openCodeExecute(
      database: validDb,
      sql: """
        INSERT INTO session_message (id, session_id, type, time_created, data) \
        VALUES ('sm1', 's1', 'assistant', \(nowMs), '\(assistantData)');
        INSERT INTO session_message (id, session_id, type, time_created, data) \
        VALUES ('sm2', 's1', 'user', \(nowMs + 1000), '\(userData)');
        """
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let reader = OpenCodeUsageReader(databasePath: dbPath)
    let cutoff = Date(timeIntervalSince1970: Double(nowMs - 10_000) / 1000.0)
    let events = try #require(reader.readEvents(cutoff: cutoff, calendar: calendar))

    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.provider == .opencode)
    #expect(event.model == "gpt-4o")
    #expect(event.tokens.input == 200)
    #expect(event.tokens.output == 80)
  }

  @Test func openCodeExtractsModelFromNestedModelObject() throws {
    let tempDir = try openCodeMakeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("opencode.db").path
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      dbPath,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
      nil
    )
    #expect(openResult == SQLITE_OK)
    let validDb = try #require(database)
    defer { sqlite3_close_v2(validDb) }

    try openCodeExecute(
      database: validDb,
      sql: """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, \
        time_created INTEGER, data TEXT);
        """
    )

    let nowMs = Int64(1_731_150_000_000)
    let assistantData = """
      {"model":{"modelID":"custom-claude-v2"},\
      "tokens":{"input":300,"output":120,"cache":{"read":0,"write":0}}}
      """

    try openCodeExecute(
      database: validDb,
      sql: """
        INSERT INTO session_message (id, session_id, type, time_created, data) \
        VALUES ('sm1', 's1', 'assistant', \(nowMs), '\(assistantData)');
        """
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let reader = OpenCodeUsageReader(databasePath: dbPath)
    let cutoff = Date(timeIntervalSince1970: Double(nowMs - 10_000) / 1000.0)
    let events = try #require(reader.readEvents(cutoff: cutoff, calendar: calendar))

    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.model == "custom-claude-v2")
    #expect(event.tokens.input == 300)
    #expect(event.tokens.output == 120)
  }

  @Test func openCodeFiltersOldMessagesAndSkipsInvalidJson() throws {
    let tempDir = try openCodeMakeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbPath = tempDir.appendingPathComponent("opencode.db").path
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      dbPath,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
      nil
    )
    #expect(openResult == SQLITE_OK)
    let validDb = try #require(database)
    defer { sqlite3_close_v2(validDb) }

    try openCodeExecute(
      database: validDb,
      sql: """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, \
        time_created INTEGER, data TEXT);
        """
    )

    let nowMs = Int64(1_731_150_000_000)
    let oldMs = nowMs - (40 * 86400 * 1000)
    let validData = """
      {"modelID":"gpt-5","tokens":{"input":150,"output":50}}
      """
    let invalidJson = "not-valid-json{"

    try openCodeExecute(
      database: validDb,
      sql: """
        INSERT INTO session_message (id, session_id, type, time_created, data) \
        VALUES ('sm-recent', 's1', 'assistant', \(nowMs), '\(validData)');
        INSERT INTO session_message (id, session_id, type, time_created, data) \
        VALUES ('sm-old', 's1', 'assistant', \(oldMs), '\(validData)');
        INSERT INTO session_message (id, session_id, type, time_created, data) \
        VALUES ('sm-invalid', 's1', 'assistant', \(nowMs + 1000), '\(invalidJson)');
        """
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let reader = OpenCodeUsageReader(databasePath: dbPath)
    let cutoff = Date(timeIntervalSince1970: Double(nowMs - (35 * 86400 * 1000)) / 1000.0)
    let events = try #require(reader.readEvents(cutoff: cutoff, calendar: calendar))

    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.model == "gpt-5")
    #expect(event.tokens.input == 150)
  }

  @Test func openCodeMissingDatabaseReturnsNil() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let reader = OpenCodeUsageReader(databasePath: "/nonexistent/path/to/opencode.db")
    // Read-only open of a missing file fails: nil, the scanner keeps what it had.
    #expect(reader.readEvents(cutoff: Date.distantPast, calendar: calendar) == nil)
  }

  @Test func openCodeScannerCachingAvoidsReReadingAndReReadsOnChange() async throws {
    let tempDir = try openCodeMakeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cachePath = tempDir.appendingPathComponent("cache.json").path
    let dbPath = tempDir.appendingPathComponent("opencode.db").path

    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      dbPath,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
      nil
    )
    #expect(openResult == SQLITE_OK)
    let validDb = try #require(database)

    try openCodeExecute(
      database: validDb,
      sql: """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY);
        CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, \
        time_created INTEGER, data TEXT);
        """
    )

    let nowMs = Int64(1_731_150_000_000)
    let firstData = """
      {"modelID":"claude-opus","tokens":{"input":400,"output":100}}
      """
    try openCodeExecute(
      database: validDb,
      sql: """
        INSERT INTO session_message (id, session_id, type, time_created, data) \
        VALUES ('sm-1', 's1', 'assistant', \(nowMs), '\(firstData)');
        """
    )
    sqlite3_close_v2(validDb)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let nowDate = Date(timeIntervalSince1970: Double(nowMs) / 1000.0)

    let scanner = openCodeMakeScanner(
      tempDir: tempDir, cachePath: cachePath, dbPath: dbPath, now: nowDate, calendar: calendar)

    let ledger1 = await scanner.scanOnce()
    let summary1 = ledger1.summary(period: .today, now: nowDate, calendar: calendar)
    #expect(summary1.tokens.input == 400)
    #expect(summary1.tokens.output == 100)

    // Second scan without modification should yield same ledger from cache
    let ledger2 = await scanner.scanOnce()
    let summary2 = ledger2.summary(period: .today, now: nowDate, calendar: calendar)
    #expect(summary2.tokens.input == 400)

    // Open and insert a new message into the DB
    var secondDb: OpaquePointer?
    let reOpenResult = sqlite3_open_v2(dbPath, &secondDb, SQLITE_OPEN_READWRITE, nil)
    #expect(reOpenResult == SQLITE_OK)
    let validSecondDb = try #require(secondDb)

    let secondData = """
      {"modelID":"gpt-5-mini","tokens":{"input":250,"output":50}}
      """
    try openCodeExecute(
      database: validSecondDb,
      sql: """
        INSERT INTO session_message (id, session_id, type, time_created, data) \
        VALUES ('sm-2', 's1', 'assistant', \(nowMs + 1000), '\(secondData)');
        """
    )
    sqlite3_close_v2(validSecondDb)

    // Third scan detects database change and updates ledger
    let ledger3 = await scanner.scanOnce()
    let summary3 = ledger3.summary(period: .today, now: nowDate, calendar: calendar)
    #expect(summary3.tokens.input == 650)
    #expect(summary3.tokens.output == 150)

    // A database that cannot be read keeps what was counted before.
    try Data("not a database, a different size".utf8).write(to: URL(fileURLWithPath: dbPath))
    let ledger4 = await scanner.scanOnce()
    let summary4 = ledger4.summary(period: .today, now: nowDate, calendar: calendar)
    #expect(summary4.tokens.input == 650)

    await scanner.stop()
  }
}
