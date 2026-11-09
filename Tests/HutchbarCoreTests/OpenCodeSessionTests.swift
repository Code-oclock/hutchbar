// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3
import Testing

@testable import HutchbarCore

private func openCodeSessionMakeTempDir() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func openCodeSessionExecute(database: OpaquePointer, sql: String) throws {
  var errorMessage: UnsafeMutablePointer<CChar>?
  let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
  if result != SQLITE_OK {
    let errorString = errorMessage.map { String(cString: $0) } ?? "Unknown error"
    sqlite3_free(errorMessage)
    throw CocoaError(
      .fileWriteUnknown,
      userInfo: [NSLocalizedDescriptionKey: "sqlite3_exec failed: \(errorString)"]
    )
  }
}

private func openCodeSessionCreateDb(at path: String) throws -> OpaquePointer {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(
    path,
    &database,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
    nil
  )
  guard openResult == SQLITE_OK, let validDb = database else {
    throw CocoaError(.fileWriteUnknown)
  }
  return validDb
}

@Test func openCodeSessionSchema2AllStateBranches() throws {
  let tempDir = try openCodeSessionMakeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let dbPath = tempDir.appendingPathComponent("opencode.db").path
  let database = try openCodeSessionCreateDb(at: dbPath)
  defer { sqlite3_close_v2(database) }

  let schemaSql = """
    CREATE TABLE session_v2 (
      id TEXT PRIMARY KEY, directory TEXT, title TEXT, parent_id TEXT, time_updated INTEGER);
    CREATE TABLE session_message (
      id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER,
      type TEXT, data TEXT);
    """
  try openCodeSessionExecute(database: database, sql: schemaSql)

  let nowMs = Int64(1_731_150_000_000)

  // 1. User message -> .running
  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session_v2 VALUES ('s-user', '/work/proj-user', 'User Task', NULL, \(nowMs));
      INSERT INTO session_message VALUES ('m1', 's-user', \(nowMs), \(nowMs), 'user',
        '{"role":"user"}');
      """)

  // 2. Assistant without completed -> .running
  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session_v2 VALUES ('s-incomplete', '/work/proj-inc', 'Inc Task', NULL, \(nowMs));
      INSERT INTO session_message VALUES ('m2', 's-incomplete', \(nowMs), \(nowMs), 'assistant',
        '{"role":"assistant"}');
      """)

  // 3. Assistant with tool-calls and no error -> .running
  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session_v2 VALUES ('s-tools', '/work/proj-tools', 'Tool Task', NULL, \(nowMs));
      INSERT INTO session_message VALUES ('m3', 's-tools', \(nowMs), \(nowMs), 'assistant',
        '{"finish":"tool-calls","time":{"completed":\(nowMs)}}');
      """)

  // 4. Assistant with stop -> .waitingForInput
  let completedMs = nowMs - 5000
  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session_v2 VALUES ('s-stop', '/work/proj-stop', 'Stop Task', NULL, \(nowMs));
      INSERT INTO session_message VALUES ('m4', 's-stop', \(nowMs), \(nowMs), 'assistant',
        '{"finish":"stop","time":{"completed":\(completedMs)}}');
      """)

  // 5. Assistant with tool-calls but with error -> .waitingForInput
  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session_v2 VALUES ('s-error', '/work/proj-err', 'Err Task', NULL, \(nowMs));
      INSERT INTO session_message VALUES ('m5', 's-error', \(nowMs), \(nowMs), 'assistant',
        '{"finish":"tool-calls","error":{"code":"E101"},"time":{"completed":\(nowMs)}}');
      """)

  // 6. Assistant with length -> .waitingForInput
  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session_v2 VALUES ('s-length', '/work/proj-len', 'Len Task', NULL, \(nowMs));
      INSERT INTO session_message VALUES ('m6', 's-length', \(nowMs), \(nowMs), 'assistant',
        '{"finish":"length","time":{"completed":\(nowMs)}}');
      """)

  let reader = OpenCodeSessionReader(databasePath: dbPath)
  let cutoff = Date(timeIntervalSince1970: Double(nowMs - 60_000) / 1000.0)
  let sessions = try #require(reader.readSessions(cutoff: cutoff))
  let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

  let snapUser = try #require(byId["s-user"])
  #expect(snapUser.state == .running)
  #expect(snapUser.waitingSince == nil)

  let snapInc = try #require(byId["s-incomplete"])
  #expect(snapInc.state == .running)
  #expect(snapInc.waitingSince == nil)

  let snapTools = try #require(byId["s-tools"])
  #expect(snapTools.state == .running)
  #expect(snapTools.waitingSince == nil)

  let snapStop = try #require(byId["s-stop"])
  #expect(snapStop.state == .waitingForInput)
  #expect(snapStop.waitingSince == Date(timeIntervalSince1970: Double(completedMs) / 1000.0))

  let snapErr = try #require(byId["s-error"])
  #expect(snapErr.state == .waitingForInput)

  let snapLen = try #require(byId["s-length"])
  #expect(snapLen.state == .waitingForInput)
}

@Test func openCodeSessionSubagentAndMetadata() throws {
  let tempDir = try openCodeSessionMakeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let dbPath = tempDir.appendingPathComponent("opencode.db").path
  let database = try openCodeSessionCreateDb(at: dbPath)
  defer { sqlite3_close_v2(database) }

  let schemaSql = """
    CREATE TABLE session_v2 (
      id TEXT PRIMARY KEY,
      directory TEXT,
      title TEXT,
      parent_id TEXT,
      time_updated INTEGER
    );
    CREATE TABLE session_message (
      id TEXT PRIMARY KEY,
      session_id TEXT,
      time_created INTEGER,
      time_updated INTEGER,
      type TEXT,
      data TEXT
    );
    """
  try openCodeSessionExecute(database: database, sql: schemaSql)

  let nowMs = Int64(1_731_150_000_000)
  let veryLongTitle = String(repeating: "A", count: 120)

  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session_v2 VALUES (
        'child-sess-1',
        '/Users/developer/code/super-app/',
        '\(veryLongTitle)',
        'parent-sess-99',
        \(nowMs)
      );
      INSERT INTO session_message VALUES (
        'msg-1',
        'child-sess-1',
        \(nowMs),
        \(nowMs),
        'user',
        '{}'
      );
      """)

  let reader = OpenCodeSessionReader(databasePath: dbPath)
  let cutoff = Date(timeIntervalSince1970: Double(nowMs - 60_000) / 1000.0)
  let sessions = try #require(reader.readSessions(cutoff: cutoff))
  let snapshot = try #require(sessions.first)

  #expect(snapshot.id == "child-sess-1")
  #expect(snapshot.agent == .opencode)
  #expect(snapshot.projectName == "super-app")
  #expect(snapshot.cwd == "/Users/developer/code/super-app/")
  #expect(snapshot.parentKey == SessionKey(agent: .opencode, id: "parent-sess-99"))
  #expect(snapshot.childKind == .subagent)
  let title = try #require(snapshot.title)
  #expect(title.count == 80)
}

@Test func openCodeSessionSchema1ParsesRoleFromData() throws {
  let tempDir = try openCodeSessionMakeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let dbPath = tempDir.appendingPathComponent("opencode.db").path
  let database = try openCodeSessionCreateDb(at: dbPath)
  defer { sqlite3_close_v2(database) }

  let schemaSql = """
    CREATE TABLE session (
      id TEXT PRIMARY KEY,
      directory TEXT,
      title TEXT,
      time_updated INTEGER
    );
    CREATE TABLE message (
      id TEXT PRIMARY KEY,
      session_id TEXT,
      time_created INTEGER,
      time_updated INTEGER,
      data TEXT
    );
    """
  try openCodeSessionExecute(database: database, sql: schemaSql)

  let nowMs = Int64(1_731_150_000_000)
  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session VALUES ('s-v1', '/work/v1-proj', 'V1 Session', \(nowMs));
      INSERT INTO message VALUES ('m-v1', 's-v1', \(nowMs), \(nowMs),
        '{"role":"assistant","finish":"stop","time":{"completed":\(nowMs)}}');
      """)

  let reader = OpenCodeSessionReader(databasePath: dbPath)
  let cutoff = Date(timeIntervalSince1970: Double(nowMs - 60_000) / 1000.0)
  let sessions = try #require(reader.readSessions(cutoff: cutoff))
  let snapshot = try #require(sessions.first)

  #expect(snapshot.id == "s-v1")
  #expect(snapshot.state == .waitingForInput)
  #expect(snapshot.projectName == "v1-proj")
  #expect(snapshot.title == "V1 Session")
}

@Test func openCodeSessionOldSessionExcludedAndNoDbReturnsEmpty() throws {
  let tempDir = try openCodeSessionMakeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let dbPath = tempDir.appendingPathComponent("opencode.db").path
  let database = try openCodeSessionCreateDb(at: dbPath)
  defer { sqlite3_close_v2(database) }

  let schemaSql = """
    CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, time_updated INTEGER);
    CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
    """
  try openCodeSessionExecute(database: database, sql: schemaSql)

  let oldMs = Int64(1_700_000_000_000)
  try openCodeSessionExecute(
    database: database,
    sql: """
      INSERT INTO session_v2 VALUES ('s-old', '/work/old', \(oldMs));
      """)

  let reader = OpenCodeSessionReader(databasePath: dbPath)
  let recentCutoff = Date(timeIntervalSince1970: 1_730_000_000)
  let sessions = try #require(reader.readSessions(cutoff: recentCutoff))
  #expect(sessions.isEmpty)

  let nonexistentReader = OpenCodeSessionReader(databasePath: "/private/tmp/no_such_file.db")
  let emptyResult = try #require(nonexistentReader.readSessions(cutoff: recentCutoff))
  #expect(emptyResult.isEmpty)
}
