// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import HutchbarCore
import Testing

private func makeQwenTempDirectory() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private final class QwenTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  init() {}

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }

  func get() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private final class QwenTestTailFile: TailFile, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data
  private let readCounter: QwenTestCounter

  init(data: Data, readCounter: QwenTestCounter) {
    self.data = data
    self.readCounter = readCounter
  }

  func snapshot() throws -> FileSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return FileSnapshot(device: 1, inode: 1, size: UInt64(data.count))
  }

  func read(from offset: UInt64, count: Int) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    readCounter.increment()
    guard offset < UInt64(data.count) else { return Data() }
    let start = Int(offset)
    let end = min(start + count, data.count)
    return data.subdata(in: start..<end)
  }

  func close() {}
}

private final class QwenTestTailFileSystem: TailFileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [String: QwenTestTailFile] = [:]

  init() {}

  func register(path: String, file: QwenTestTailFile) {
    lock.lock()
    defer { lock.unlock() }
    files[path] = file
  }

  func openRegularFile(at path: String) throws -> any TailFile {
    lock.lock()
    defer { lock.unlock() }
    guard let file = files[path] else { throw TailError.unavailable }
    return file
  }
}

private final class QwenTestDirectoryLister: DirectoryLister, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: [FileMetadata]] = [:]

  init() {}

  func set(items: [FileMetadata], forPath path: String) {
    lock.lock()
    defer { lock.unlock() }
    storage[path] = items
  }

  func contentsOfDirectory(atPath path: String) throws -> [FileMetadata] {
    lock.lock()
    defer { lock.unlock() }
    guard let items = storage[path] else { throw CocoaError(.fileReadNoSuchFile) }
    return items
  }
}

private final class QwenTestClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date) { self.current = date }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }
}

@Suite("QwenUsageTests")
struct QwenUsageTests {
  @Test func parsesLineWithLocalCalendarDayAndHour() throws {
    let line = """
      {"schemaVersion":1,"id":"req-123","timestamp":"2026-10-10T18:02:30.172Z",\
      "sessionId":"sess-1","model":"gpt-oss:20b","inputTokens":4098,"outputTokens":723,\
      "cachedTokens":0,"thoughtsTokens":226,"totalTokens":4821}
      """
    var calendar = Calendar(identifier: .gregorian)
    let gmt = try #require(TimeZone(secondsFromGMT: 0))
    calendar.timeZone = gmt

    var seenIds = Set<String>()
    let events = parseQwenUsage(lines: [line], seenIds: &seenIds, calendar: calendar)

    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.provider == .qwen)
    #expect(event.model == "gpt-oss:20b")
    #expect(event.tokens.input == 4098)
    #expect(event.tokens.output == 723)
    #expect(event.tokens.cacheRead == 0)
    #expect(event.tokens.cacheWrite5m == 0)
    #expect(event.tokens.cacheWrite1h == 0)
    #expect(event.tokens.total == 4821)
    #expect(event.hour == 18)

    let expectedDay = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 10)))
    #expect(event.day == expectedDay)
  }

  @Test func deductsCacheFromInputTokens() throws {
    let line = """
      {"schemaVersion":1,"id":"req-cached","timestamp":"2026-10-10T19:00:00.000Z",\
      "sessionId":"sess-2","model":"qwen-2.5-coder","inputTokens":5000,"outputTokens":800,\
      "cachedTokens":2000,"thoughtsTokens":100,"totalTokens":5800}
      """
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    var seenIds = Set<String>()
    let events = parseQwenUsage(lines: [line], seenIds: &seenIds, calendar: calendar)

    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.tokens.input == 3000)
    #expect(event.tokens.cacheRead == 2000)
    #expect(event.tokens.output == 800)
    #expect(event.tokens.total == 5800)
  }

  @Test func deduplicatesEventsByRecordId() throws {
    let line1 = """
      {"schemaVersion":1,"id":"req-duplicate","timestamp":"2026-10-10T18:00:00.000Z",\
      "sessionId":"sess-1","model":"gpt-oss:20b","inputTokens":100,"outputTokens":20,\
      "cachedTokens":0,"totalTokens":120}
      """
    let line2 = """
      {"schemaVersion":1,"id":"req-duplicate","timestamp":"2026-10-10T18:05:00.000Z",\
      "sessionId":"sess-1","model":"gpt-oss:20b","inputTokens":200,"outputTokens":50,\
      "cachedTokens":0,"totalTokens":250}
      """
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    var seenIds = Set<String>()
    let events = parseQwenUsage(lines: [line1, line2], seenIds: &seenIds, calendar: calendar)

    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.tokens.input == 100)
    #expect(event.tokens.output == 20)
  }

  @Test func scannerSkipsFileOlderThanCutoffWindow() async throws {
    let tempDir = try makeQwenTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cachePath = tempDir.appendingPathComponent("cache.json").path
    let qwenRoot = tempDir.appendingPathComponent("qwen-usage").path
    let recentFilePath = tempDir.appendingPathComponent("qwen-usage/token-usage-2026-11.jsonl").path
    let oldFilePath = tempDir.appendingPathComponent("qwen-usage/token-usage-2026-09.jsonl").path

    let recentLine = """
      {"schemaVersion":1,"id":"req-recent","timestamp":"2026-11-08T10:00:00Z",\
      "sessionId":"sess-r","model":"qwen-coder","inputTokens":600,"outputTokens":200,\
      "cachedTokens":100,"totalTokens":800}
      """
    let oldLine = """
      {"schemaVersion":1,"id":"req-old","timestamp":"2026-09-01T10:00:00Z",\
      "sessionId":"sess-o","model":"qwen-coder","inputTokens":1000,"outputTokens":500,\
      "cachedTokens":0,"totalTokens":1500}
      """

    let counter = QwenTestCounter()
    let tailFileSystem = QwenTestTailFileSystem()
    tailFileSystem.register(
      path: recentFilePath,
      file: QwenTestTailFile(data: Data(recentLine.utf8), readCounter: counter)
    )
    tailFileSystem.register(
      path: oldFilePath,
      file: QwenTestTailFile(data: Data(oldLine.utf8), readCounter: counter)
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let nowDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12)))
    let oldDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 10)))

    let lister = QwenTestDirectoryLister()
    lister.set(
      items: [
        FileMetadata(path: recentFilePath, modificationDate: nowDate, isDirectory: false),
        FileMetadata(path: oldFilePath, modificationDate: oldDate, isDirectory: false),
      ],
      forPath: qwenRoot
    )
    lister.set(items: [], forPath: tempDir.appendingPathComponent("claude").path)
    lister.set(items: [], forPath: tempDir.appendingPathComponent("codex").path)

    let clock = QwenTestClock(date: nowDate)
    let scanner = UsageScanner(
      cacheFilePath: cachePath,
      claudeProjectsRoot: tempDir.appendingPathComponent("claude").path,
      codexSessionsRoot: tempDir.appendingPathComponent("codex").path,
      qwenUsageRoot: qwenRoot,
      fileSystem: tailFileSystem,
      directoryLister: lister,
      clock: clock,
      calendar: calendar,
      cutoffDays: 35
    )

    let ledger = await scanner.scanOnce()
    let summary = ledger.summary(period: .today, now: nowDate, calendar: calendar)

    #expect(summary.tokens.input == 500)
    #expect(summary.tokens.cacheRead == 100)
    #expect(summary.tokens.output == 200)
    #expect(ledger.byDayProviderModel.count == 1)

    await scanner.stop()
  }
}
