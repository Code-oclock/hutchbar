// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import HutchbarCore
import Testing

private func geminiMakeTempDirectory() throws -> URL {
  let tempURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
  return tempURL
}

private final class GeminiTestCounter: @unchecked Sendable {
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

private final class GeminiTestTailFile: TailFile, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data
  private let readCounter: GeminiTestCounter

  init(data: Data, readCounter: GeminiTestCounter) {
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
    let startIdx = Int(offset)
    let endIdx = min(startIdx + count, data.count)
    return data.subdata(in: startIdx..<endIdx)
  }

  func close() {}
}

private final class GeminiTestTailFileSystem: TailFileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [String: GeminiTestTailFile] = [:]

  init() {}

  func register(path: String, file: GeminiTestTailFile) {
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

private final class GeminiTestDirectoryLister: DirectoryLister, @unchecked Sendable {
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

private final class GeminiTestClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date) { self.current = date }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }
}

@Suite("GeminiUsageTests")
struct GeminiUsageTests {
  @Test func geminiParsesExampleWithCacheDeductionAndThoughtsInOutput() throws {
    let jsonContent = """
      {
        "sessionId": "5f1c-test",
        "projectHash": "ab12-hash",
        "startTime": "2026-11-09T09:00:00.000Z",
        "lastUpdated": "2026-11-09T09:05:00.000Z",
        "messages": [
          {"id": "m1", "timestamp": "2026-11-09T09:00:00.000Z", "type": "user", "content": "hello"},
          {
            "id": "m2",
            "timestamp": "2026-11-09T09:00:10.000Z",
            "type": "gemini",
            "content": "thinking...",
            "model": "gemini-2.5-pro",
            "tokens": {"input": 1200, "output": 300, "cached": 800, "thoughts": 50,
                       "tool": 20, "total": 1570},
            "toolCalls": [{"id": "t1", "name": "run_shell_command", "status": "success",
                           "timestamp": "2026-11-09T09:00:05.000Z"}]
          }
        ]
      }
      """

    var calendar = Calendar(identifier: .gregorian)
    let gmtZone = try #require(TimeZone(secondsFromGMT: 0))
    calendar.timeZone = gmtZone

    let events = parseGeminiUsage(lines: [jsonContent], calendar: calendar)
    #expect(events.count == 1)

    let event = try #require(events.first)
    #expect(event.provider == .geminiCLI)
    #expect(event.model == "gemini-2.5-pro")
    #expect(event.tokens.input == 400)
    #expect(event.tokens.cacheRead == 800)
    #expect(event.tokens.output == 350)
    #expect(event.tokens.cacheWrite5m == 0)
    #expect(event.tokens.cacheWrite1h == 0)
    #expect(event.tokens.total == 1550)
    #expect(event.hour == 9)

    let expectedDay = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
    #expect(event.day == expectedDay)
  }

  @Test func geminiUserMessagesAndMessagesWithoutTokensAreSkipped() throws {
    let jsonContent = """
      {
        "messages": [
          {"id": "u1", "timestamp": "2026-11-09T09:00:00.000Z", "type": "user", "content": "hi"},
          {"id": "g-no-tokens", "timestamp": "2026-11-09T09:00:01.000Z", "type": "gemini"},
          {"id": "g-zero-tokens", "timestamp": "2026-11-09T09:00:02.000Z", "type": "gemini",
           "tokens": {"input": 0, "output": 0}},
          {
            "id": "g-valid-no-model",
            "timestamp": "2026-11-09T09:00:03.000Z",
            "type": "gemini",
            "tokens": {"input": 100, "output": 20}
          }
        ]
      }
      """

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let events = parseGeminiUsage(lines: [jsonContent], calendar: calendar)
    #expect(events.count == 1)

    let event = try #require(events.first)
    #expect(event.model == "gemini")
    #expect(event.tokens.input == 100)
    #expect(event.tokens.output == 20)
  }

  @Test func geminiDuplicateMessageIdInSameFileDeduplicated() throws {
    let jsonContent = """
      {
        "messages": [
          {
            "id": "dup-1",
            "timestamp": "2026-11-09T09:00:00.000Z",
            "type": "gemini",
            "model": "gemini-2.5-flash",
            "tokens": {"input": 200, "output": 50}
          },
          {
            "id": "dup-1",
            "timestamp": "2026-11-09T09:01:00.000Z",
            "type": "gemini",
            "model": "gemini-2.5-flash",
            "tokens": {"input": 500, "output": 80}
          }
        ]
      }
      """

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let events = parseGeminiUsage(lines: [jsonContent], calendar: calendar)
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.tokens.input == 200)
    #expect(event.tokens.output == 50)
  }

  @Test func geminiCorruptedJSONYieldsEmptyEvents() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

    #expect(parseGeminiUsage(lines: [], calendar: calendar).isEmpty)
    #expect(parseGeminiUsage(lines: ["not a json string"], calendar: calendar).isEmpty)
    #expect(parseGeminiUsage(lines: ["{", "broken: json"], calendar: calendar).isEmpty)
    #expect(parseGeminiUsage(lines: ["{\"messages\": null}"], calendar: calendar).isEmpty)
  }

  @Test func geminiFileDiscoveryFiltersHiddenDirsNonSessionFilesAndOldFiles() async throws {
    let tempDir = try geminiMakeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    func path(_ relative: String) -> String {
      tempDir.appendingPathComponent("gemini-tmp" + relative).path
    }
    let geminiRoot = path("")
    let validProjDir = path("/hash-valid")
    let hiddenProjDir = path("/.hidden-hash")
    let oldProjDir = path("/hash-old")
    let validChatsDir = path("/hash-valid/chats")
    let hiddenChatsDir = path("/.hidden-hash/chats")
    let oldChatsDir = path("/hash-old/chats")
    let validSessionFile = path("/hash-valid/chats/session-valid.json")
    let nonSessionFile = path("/hash-valid/chats/notes.txt")
    let oldSessionFile = path("/hash-old/chats/session-old.json")
    let hiddenSessionFile = path("/.hidden-hash/chats/session-hidden.json")

    let jsonContent = """
      {"messages": [{"id": "gemini-msg-1", "timestamp": "2026-11-09T10:00:00.000Z",
        "type": "gemini", "model": "gemini-2.5-pro",
        "tokens": {"input": 600, "output": 100, "cached": 200, "thoughts": 25}}]}
      """

    let counter = GeminiTestCounter()
    let tailFileSystem = GeminiTestTailFileSystem()
    tailFileSystem.register(
      path: validSessionFile,
      file: GeminiTestTailFile(data: Data(jsonContent.utf8), readCounter: counter)
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let nowDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12)))
    let oldDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 10)))

    let lister = GeminiTestDirectoryLister()
    lister.set(
      items: [
        FileMetadata(path: validProjDir, modificationDate: nowDate, isDirectory: true),
        FileMetadata(path: hiddenProjDir, modificationDate: nowDate, isDirectory: true),
        FileMetadata(path: oldProjDir, modificationDate: oldDate, isDirectory: true),
      ],
      forPath: geminiRoot
    )
    lister.set(
      items: [
        FileMetadata(path: validSessionFile, modificationDate: nowDate, isDirectory: false),
        FileMetadata(path: nonSessionFile, modificationDate: nowDate, isDirectory: false),
      ],
      forPath: validChatsDir
    )
    lister.set(
      items: [
        FileMetadata(path: hiddenSessionFile, modificationDate: nowDate, isDirectory: false)
      ],
      forPath: hiddenChatsDir
    )
    lister.set(
      items: [
        FileMetadata(path: oldSessionFile, modificationDate: oldDate, isDirectory: false)
      ],
      forPath: oldChatsDir
    )
    for other in ["claude", "codex", "qwen", "copilot"] {
      lister.set(items: [], forPath: tempDir.appendingPathComponent(other).path)
    }

    let scanner = geminiMakeScanner(
      tempDir: tempDir,
      geminiRoot: geminiRoot,
      fileSystem: tailFileSystem,
      lister: lister,
      now: nowDate,
      calendar: calendar
    )

    let ledger = await scanner.scanOnce()
    let summary = ledger.summary(period: .today, now: nowDate, calendar: calendar)

    #expect(summary.tokens.input == 400)
    #expect(summary.tokens.cacheRead == 200)
    #expect(summary.tokens.output == 125)
    #expect(ledger.byDayProviderModel.count == 1)

    await scanner.stop()
  }
}

private func geminiMakeScanner(
  tempDir: URL,
  geminiRoot: String,
  fileSystem: GeminiTestTailFileSystem,
  lister: GeminiTestDirectoryLister,
  now: Date,
  calendar: Calendar
) -> UsageScanner {
  UsageScanner(
    cacheFilePath: tempDir.appendingPathComponent("cache.json").path,
    claudeProjectsRoot: tempDir.appendingPathComponent("claude").path,
    codexSessionsRoot: tempDir.appendingPathComponent("codex").path,
    qwenUsageRoot: tempDir.appendingPathComponent("qwen").path,
    copilotSessionRoot: tempDir.appendingPathComponent("copilot").path,
    geminiTmpRoot: geminiRoot,
    openCodeDatabasePath: tempDir.appendingPathComponent("opencode.db").path,
    fileSystem: fileSystem,
    directoryLister: lister,
    clock: GeminiTestClock(date: now),
    calendar: calendar,
    cutoffDays: 35
  )
}
