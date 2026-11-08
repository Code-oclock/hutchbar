// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import HutchbarCore
import Testing

private func copilotMakeTempDirectory() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private final class CopilotTestCounter: @unchecked Sendable {
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

private final class CopilotTestTailFile: TailFile, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data
  private let readCounter: CopilotTestCounter

  init(data: Data, readCounter: CopilotTestCounter) {
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

private final class CopilotTestTailFileSystem: TailFileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [String: CopilotTestTailFile] = [:]

  init() {}

  func register(path: String, file: CopilotTestTailFile) {
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

private final class CopilotTestDirectoryLister: DirectoryLister, @unchecked Sendable {
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

private final class CopilotTestClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date) { self.current = date }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }
}

@Suite("CopilotUsageTests")
struct CopilotUsageTests {
  @Test func copilotParsesExampleWithTwoModelsAndPrecedence() throws {
    let line = """
      {"id":"e9","type":"session.shutdown","timestamp":"2026-11-09T10:00:00.000Z","data":{"modelMetrics":{\
      "claude-sonnet-4.5":{"usage":{"inputTokens":1111,"outputTokens":300,"cacheReadTokens":4444,\
      "cacheWriteTokens":800,"reasoningTokens":40},\
      "tokenDetails":{"input":{"tokenCount":1200},"cache_read":{"tokenCount":5000}}},\
      "gpt-5-mini":{"usage":{"inputTokens":90,"outputTokens":10}}}}}
      """
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let events = parseCopilotUsage(lines: [line], calendar: calendar)
    #expect(events.count == 2)

    let claudeEvent = try #require(
      events.first(where: { item in item.model == "claude-sonnet-4.5" }))
    #expect(claudeEvent.provider == .copilot)
    #expect(claudeEvent.tokens.input == 1200)
    #expect(claudeEvent.tokens.cacheRead == 5000)
    #expect(claudeEvent.tokens.cacheWrite5m == 800)
    #expect(claudeEvent.tokens.output == 340)
    #expect(claudeEvent.tokens.total == 7340)
    #expect(claudeEvent.hour == 10)

    let expectedDay = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
    #expect(claudeEvent.day == expectedDay)

    let gptEvent = try #require(events.first(where: { item in item.model == "gpt-5-mini" }))
    #expect(gptEvent.provider == .copilot)
    #expect(gptEvent.tokens.input == 90)
    #expect(gptEvent.tokens.output == 10)
    #expect(gptEvent.tokens.cacheRead == 0)
    #expect(gptEvent.tokens.cacheWrite5m == 0)
    #expect(gptEvent.tokens.total == 100)
  }

  @Test func copilotConsecutiveShutdownsEmitDeltasOnly() throws {
    let line1 = """
      {"id":"e1","type":"session.shutdown","timestamp":"2026-11-09T10:00:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":100,"outputTokens":20}}}}}
      """
    let line2 = """
      {"id":"e2","type":"session.shutdown","timestamp":"2026-11-09T10:15:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":150,"outputTokens":30}}}}}
      """
    let line3 = """
      {"id":"e3","type":"session.shutdown","timestamp":"2026-11-09T10:30:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":150,"outputTokens":30}}}}}
      """

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let events = parseCopilotUsage(lines: [line1, line2, line3], calendar: calendar)
    #expect(events.count == 2)

    let first = try #require(events.first)
    #expect(first.tokens.input == 100)
    #expect(first.tokens.output == 20)

    let second = events[1]
    #expect(second.tokens.input == 50)
    #expect(second.tokens.output == 10)
  }

  @Test func copilotResetDecreasedTotalCountsEntireTotal() throws {
    let line1 = """
      {"id":"e1","type":"session.shutdown","timestamp":"2026-11-09T10:00:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":500,"outputTokens":100}}}}}
      """
    let line2 = """
      {"id":"e2","type":"session.shutdown","timestamp":"2026-11-09T10:20:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":150,"outputTokens":50}}}}}
      """

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let events = parseCopilotUsage(lines: [line1, line2], calendar: calendar)
    #expect(events.count == 2)

    let first = events[0]
    #expect(first.tokens.input == 500)
    #expect(first.tokens.output == 100)

    let second = events[1]
    #expect(second.tokens.input == 150)
    #expect(second.tokens.output == 50)
  }

  @Test func copilotDuplicateEventIdDoesNotDuplicate() throws {
    let line1 = """
      {"id":"e-dup","type":"session.shutdown","timestamp":"2026-11-09T10:00:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":100,"outputTokens":20}}}}}
      """
    let line2 = """
      {"id":"e-dup","type":"session.shutdown","timestamp":"2026-11-09T10:05:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":200,"outputTokens":40}}}}}
      """

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let events = parseCopilotUsage(lines: [line1, line2], calendar: calendar)
    #expect(events.count == 1)
    let first = try #require(events.first)
    #expect(first.tokens.input == 100)
    #expect(first.tokens.output == 20)
  }

  @Test func copilotOtherEventTypesAndCorruptLinesSkipped() throws {
    let lines = [
      "",
      "not json at all",
      "{}",
      """
      {"id":"e-other","type":"session.start","timestamp":"2026-11-09T10:00:00.000Z","data":{}}
      """,
      """
      {"id":"e-empty","type":"session.shutdown","timestamp":"2026-11-09T10:00:00.000Z",\
      "data":{"modelMetrics":{}}}
      """,
      """
      {"id":"e-valid","type":"session.shutdown","timestamp":"2026-11-09T10:00:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":40,"outputTokens":10}}}}}
      """,
    ]

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let events = parseCopilotUsage(lines: lines, calendar: calendar)
    #expect(events.count == 1)
    let first = try #require(events.first)
    #expect(first.model == "gpt-5-mini")
    #expect(first.tokens.input == 40)
  }

  @Test func copilotFileDiscoveryFiltersAppropriately() async throws {
    let tempDir = try copilotMakeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let copilotRoot = tempDir.appendingPathComponent("copilot-sessions").path
    let validSessionDir = tempDir.appendingPathComponent("copilot-sessions/sess-valid").path
    let hiddenSessionDir = tempDir.appendingPathComponent("copilot-sessions/.hidden-sess").path
    let oldSessionDir = tempDir.appendingPathComponent("copilot-sessions/sess-old").path

    let validFilePath = tempDir.appendingPathComponent("copilot-sessions/sess-valid/events.jsonl")
      .path
    let extraFilePath = tempDir.appendingPathComponent("copilot-sessions/sess-valid/extra.txt").path
    let hiddenFilePath = tempDir.appendingPathComponent(
      "copilot-sessions/.hidden-sess/events.jsonl"
    ).path
    let oldFilePath = tempDir.appendingPathComponent("copilot-sessions/sess-old/events.jsonl").path
    let orphanFilePath = tempDir.appendingPathComponent("copilot-sessions/orphan.jsonl").path

    let validLine = """
      {"id":"e-scan","type":"session.shutdown","timestamp":"2026-11-09T10:00:00.000Z",\
      "data":{"modelMetrics":{"gpt-5-mini":{"usage":{"inputTokens":80,"outputTokens":20}}}}}
      """

    let counter = CopilotTestCounter()
    let tailFileSystem = CopilotTestTailFileSystem()
    tailFileSystem.register(
      path: validFilePath,
      file: CopilotTestTailFile(data: Data(validLine.utf8), readCounter: counter)
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let nowDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12)))
    let oldDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 10)))

    let lister = CopilotTestDirectoryLister()
    lister.set(
      items: [
        FileMetadata(path: validSessionDir, modificationDate: nowDate, isDirectory: true),
        FileMetadata(path: hiddenSessionDir, modificationDate: nowDate, isDirectory: true),
        FileMetadata(path: oldSessionDir, modificationDate: oldDate, isDirectory: true),
        FileMetadata(path: orphanFilePath, modificationDate: nowDate, isDirectory: false),
      ],
      forPath: copilotRoot
    )
    lister.set(
      items: [
        FileMetadata(path: validFilePath, modificationDate: nowDate, isDirectory: false),
        FileMetadata(path: extraFilePath, modificationDate: nowDate, isDirectory: false),
      ],
      forPath: validSessionDir
    )
    lister.set(
      items: [
        FileMetadata(path: hiddenFilePath, modificationDate: nowDate, isDirectory: false)
      ],
      forPath: hiddenSessionDir
    )
    lister.set(
      items: [
        FileMetadata(path: oldFilePath, modificationDate: oldDate, isDirectory: false)
      ],
      forPath: oldSessionDir
    )
    lister.set(items: [], forPath: tempDir.appendingPathComponent("claude").path)
    lister.set(items: [], forPath: tempDir.appendingPathComponent("codex").path)
    lister.set(items: [], forPath: tempDir.appendingPathComponent("qwen").path)

    let scanner = copilotMakeScanner(
      tempDir: tempDir, copilotRoot: copilotRoot, fileSystem: tailFileSystem, lister: lister,
      now: nowDate, calendar: calendar)

    let ledger = await scanner.scanOnce()
    let summary = ledger.summary(period: .today, now: nowDate, calendar: calendar)

    #expect(summary.tokens.input == 80)
    #expect(summary.tokens.output == 20)
    #expect(ledger.byDayProviderModel.count == 1)

    await scanner.stop()
  }
}

private func copilotMakeScanner(
  tempDir: URL,
  copilotRoot: String,
  fileSystem: CopilotTestTailFileSystem,
  lister: CopilotTestDirectoryLister,
  now: Date,
  calendar: Calendar
) -> UsageScanner {
  UsageScanner(
    cacheFilePath: tempDir.appendingPathComponent("cache.json").path,
    claudeProjectsRoot: tempDir.appendingPathComponent("claude").path,
    codexSessionsRoot: tempDir.appendingPathComponent("codex").path,
    qwenUsageRoot: tempDir.appendingPathComponent("qwen").path,
    copilotSessionRoot: copilotRoot,
    openCodeDatabasePath: tempDir.appendingPathComponent("opencode.db").path,
    fileSystem: fileSystem,
    directoryLister: lister,
    clock: CopilotTestClock(date: now),
    calendar: calendar,
    cutoffDays: 35
  )
}
