// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3
import Testing

@testable import HutchbarCore

private func openCodeSessionCoordinatorTempDir() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func openCodeSessionCoordinatorExecute(database: OpaquePointer, sql: String) throws {
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

private final class OpenCodeSessionCoordinatorClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date) {
    self.current = date
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    current = current.addingTimeInterval(seconds)
  }
}

private actor OpenCodeSessionCoordinatorCollector {
  private var items: [SourceUpdate] = []
  func append(_ item: SourceUpdate) { items.append(item) }
  func drain() -> [SourceUpdate] {
    let current = items
    items.removeAll()
    return current
  }
}

/// Opens a new OpenCode 2 database (session_v2 + session_message) for the coordinator tests.
private func openCodeSessionCoordinatorMakeV2Database(at dbPath: String) throws -> OpaquePointer {
  var database: OpaquePointer?
  let openResult = sqlite3_open_v2(
    dbPath, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
  #expect(openResult == SQLITE_OK)
  let validDb = try #require(database)
  try openCodeSessionCoordinatorExecute(
    database: validDb,
    sql: """
      CREATE TABLE session_v2 (
        id TEXT PRIMARY KEY, directory TEXT, title TEXT, parent_id TEXT, time_updated INTEGER);
      CREATE TABLE session_message (
        id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER,
        type TEXT, data TEXT);
      """)
  return validDb
}

@Test func openCodeSessionCoordinatorPollingAndDisappearance() async throws {
  let tempDir = try openCodeSessionCoordinatorTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let dbPath = tempDir.appendingPathComponent("opencode.db").path
  let validDb = try openCodeSessionCoordinatorMakeV2Database(at: dbPath)
  defer { sqlite3_close_v2(validDb) }

  let baseDate = Date(timeIntervalSince1970: 1_731_150_000)
  let baseMs = Int64(baseDate.timeIntervalSince1970 * 1000)

  try openCodeSessionCoordinatorExecute(
    database: validDb,
    sql: """
      INSERT INTO session_v2 VALUES ('oc-1', '/work/app', 'Task 1', NULL, \(baseMs));
      INSERT INTO session_message VALUES ('m1', 'oc-1', \(baseMs), \(baseMs), 'assistant',
        '{"finish":"stop","time":{"completed":\(baseMs)}}');
      """)

  let testClock = OpenCodeSessionCoordinatorClock(date: baseDate)
  var config = SourceCoordinator.Configuration()
  config.openCodeDatabasePath = dbPath
  config.enabledSources = [.openCodeSessions]
  config.freshnessWindow = 3600

  let coordinator = SourceCoordinator(configuration: config, clock: testClock)
  let collector = OpenCodeSessionCoordinatorCollector()
  let listenTask = Task {
    for await update in coordinator.updates {
      await collector.append(update)
    }
  }
  defer { listenTask.cancel() }

  // 1. Initial poll yields the session
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 50_000_000)
  let updates1 = await collector.drain()
  #expect(updates1.count == 1)
  guard case .session(let snap1) = updates1.first else {
    Issue.record("Expected session update")
    return
  }
  #expect(snap1.id == "oc-1")
  #expect(snap1.state == .waitingForInput)

  // 2. Repeated poll without changes yields nothing
  testClock.advance(by: 10.0)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 50_000_000)
  let updates2 = await collector.drain()
  #expect(updates2.isEmpty)

  // 3. Advance clock past freshness window (3600 s) and past forced read interval (60 s).
  // Session drops out of query selection. Coordinator must emit .finished once.
  testClock.advance(by: 4000.0)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 50_000_000)
  let updates3 = await collector.drain()
  #expect(updates3.count == 1)
  guard case .session(let snapFinished) = updates3.first else {
    Issue.record("Expected finished session update")
    return
  }
  #expect(snapFinished.id == "oc-1")
  #expect(snapFinished.state == .finished)
  #expect(snapFinished.waitingSince == nil)

  // 4. Repeated poll after disappearance emits nothing (finished is emitted only once)
  testClock.advance(by: 70.0)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 50_000_000)
  let updates4 = await collector.drain()
  #expect(updates4.isEmpty)
}

@Test func openCodeSessionCoordinatorMissingDatabaseYieldsNothing() async throws {
  let testClock = OpenCodeSessionCoordinatorClock(date: Date())
  var config = SourceCoordinator.Configuration()
  config.openCodeDatabasePath = "/private/tmp/no_database_at_all.db"
  config.enabledSources = [.openCodeSessions]

  let coordinator = SourceCoordinator(configuration: config, clock: testClock)
  let collector = OpenCodeSessionCoordinatorCollector()
  let listenTask = Task {
    for await update in coordinator.updates {
      await collector.append(update)
    }
  }
  defer { listenTask.cancel() }

  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 50_000_000)

  let updates = await collector.drain()
  #expect(updates.isEmpty)
}
