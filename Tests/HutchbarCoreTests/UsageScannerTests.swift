// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing

@testable import HutchbarCore

private func makeTempDirectory() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private final class ReadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

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

private final class MockTailFile: TailFile, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data
  private let readCounter: ReadCounter

  init(data: Data, readCounter: ReadCounter) {
    self.data = data
    self.readCounter = readCounter
  }

  func updateData(_ newData: Data) {
    lock.lock()
    defer { lock.unlock() }
    self.data = newData
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

private final class MockTailFileSystem: TailFileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [String: MockTailFile] = [:]

  func register(path: String, file: MockTailFile) {
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

private final class MockScannerDirectoryLister: DirectoryLister, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: [FileMetadata]] = [:]

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

private final class MockScannerClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date) { self.current = date }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func set(date: Date) {
    lock.lock()
    defer { lock.unlock() }
    current = date
  }
}

@Test func usageScanner_cacheAvoidsRereadingUnchangedFiles() async throws {
  let tempDir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let cachePath = tempDir.appendingPathComponent("cache.json").path
  let claudeRoot = tempDir.appendingPathComponent("claude-projects").path
  let projectDir = tempDir.appendingPathComponent("claude-projects/proj-1").path
  let transcriptPath = tempDir.appendingPathComponent("claude-projects/proj-1/session-1.jsonl").path

  let line = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:00Z",\
    "message":{"id":"msg-c-1","model":"claude-opus-5-5",\
    "usage":{"input_tokens":500,"output_tokens":100}}}
    """
  let lineData = Data(line.utf8)

  let readCounter = ReadCounter()
  let mockFile = MockTailFile(data: lineData, readCounter: readCounter)
  let fs = MockTailFileSystem()
  fs.register(path: transcriptPath, file: mockFile)

  let initialMtime = Date(timeIntervalSince1970: 1_700_000_000)
  let lister = MockScannerDirectoryLister()
  lister.set(
    items: [FileMetadata(path: projectDir, modificationDate: initialMtime, isDirectory: true)],
    forPath: claudeRoot
  )
  lister.set(
    items: [FileMetadata(path: transcriptPath, modificationDate: initialMtime, isDirectory: false)],
    forPath: projectDir
  )

  let clock = MockScannerClock(date: initialMtime)
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

  let scanner = UsageScanner(
    cacheFilePath: cachePath,
    claudeProjectsRoot: claudeRoot,
    codexSessionsRoot: tempDir.appendingPathComponent("codex").path,
    fileSystem: fs,
    directoryLister: lister,
    clock: clock,
    calendar: calendar
  )

  let ledger1 = await scanner.scanOnce()
  let readsAfterFirst = readCounter.get()
  #expect(readsAfterFirst > 0)
  #expect(ledger1.byDayProviderModel.count == 1)

  let ledger2 = await scanner.scanOnce()
  let readsAfterSecond = readCounter.get()
  #expect(readsAfterSecond == readsAfterFirst)
  #expect(ledger2.byDayProviderModel.count == 1)

  await scanner.stop()
}

@Test func usageScanner_mtimeChangeCausesRecalculation() async throws {
  let tempDir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let cachePath = tempDir.appendingPathComponent("cache.json").path
  let claudeRoot = tempDir.appendingPathComponent("claude-projects").path
  let projectDir = tempDir.appendingPathComponent("claude-projects/proj-1").path
  let transcriptPath = tempDir.appendingPathComponent("claude-projects/proj-1/session-1.jsonl").path

  let line1 = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:00Z",\
    "message":{"id":"msg-mtime-1","model":"claude-opus-5-5",\
    "usage":{"input_tokens":500,"output_tokens":100}}}
    """
  let line2 = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:00Z",\
    "message":{"id":"msg-mtime-1","model":"claude-opus-5-5",\
    "usage":{"input_tokens":500,"output_tokens":100}}}
    {"type":"assistant","timestamp":"2026-11-08T10:05:00Z",\
    "message":{"id":"msg-mtime-2","model":"claude-opus-5-5",\
    "usage":{"input_tokens":800,"output_tokens":300}}}
    """

  let readCounter = ReadCounter()
  let mockFile = MockTailFile(data: Data(line1.utf8), readCounter: readCounter)
  let fs = MockTailFileSystem()
  fs.register(path: transcriptPath, file: mockFile)

  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let mtime1 = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 10)))
  let lister = MockScannerDirectoryLister()
  lister.set(
    items: [FileMetadata(path: projectDir, modificationDate: mtime1, isDirectory: true)],
    forPath: claudeRoot
  )
  lister.set(
    items: [FileMetadata(path: transcriptPath, modificationDate: mtime1, isDirectory: false)],
    forPath: projectDir
  )

  let clock = MockScannerClock(date: mtime1)

  let scanner = UsageScanner(
    cacheFilePath: cachePath,
    claudeProjectsRoot: claudeRoot,
    codexSessionsRoot: tempDir.appendingPathComponent("codex").path,
    fileSystem: fs,
    directoryLister: lister,
    clock: clock,
    calendar: calendar
  )

  let ledger1 = await scanner.scanOnce()
  let summary1 = ledger1.summary(period: .today, now: mtime1, calendar: calendar)
  #expect(summary1.tokens.input == 500)
  let readsAfterFirst = readCounter.get()

  // Update file contents and bump mtime
  let mtime2 = mtime1.addingTimeInterval(300)
  mockFile.updateData(Data(line2.utf8))
  lister.set(
    items: [FileMetadata(path: transcriptPath, modificationDate: mtime2, isDirectory: false)],
    forPath: projectDir
  )
  clock.set(date: mtime2)

  let ledger2 = await scanner.scanOnce()
  let readsAfterSecond = readCounter.get()
  #expect(readsAfterSecond > readsAfterFirst)

  let summary2 = ledger2.summary(period: .today, now: mtime2, calendar: calendar)
  #expect(summary2.tokens.input == 1300)
  #expect(summary2.tokens.output == 400)

  await scanner.stop()
}

@Test func usageScanner_cacheFilePermissions0600() async throws {
  let tempDir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let cachePath = tempDir.appendingPathComponent("cache.json").path
  let claudeRoot = tempDir.appendingPathComponent("claude-projects").path
  let projectDir = tempDir.appendingPathComponent("claude-projects/proj-1").path
  let transcriptPath = tempDir.appendingPathComponent("claude-projects/proj-1/session-1.jsonl").path

  let line = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:00Z",\
    "message":{"id":"msg-perm-1","model":"claude-sonnet-5-5",\
    "usage":{"input_tokens":100,"output_tokens":50}}}
    """
  let fs = MockTailFileSystem()
  fs.register(
    path: transcriptPath, file: MockTailFile(data: Data(line.utf8), readCounter: ReadCounter()))

  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let lister = MockScannerDirectoryLister()
  lister.set(
    items: [FileMetadata(path: projectDir, modificationDate: now, isDirectory: true)],
    forPath: claudeRoot
  )
  lister.set(
    items: [FileMetadata(path: transcriptPath, modificationDate: now, isDirectory: false)],
    forPath: projectDir
  )

  let clock = MockScannerClock(date: now)
  let scanner = UsageScanner(
    cacheFilePath: cachePath,
    claudeProjectsRoot: claudeRoot,
    codexSessionsRoot: tempDir.appendingPathComponent("codex").path,
    fileSystem: fs,
    directoryLister: lister,
    clock: clock
  )

  await scanner.scanOnce()
  await scanner.stop()

  #expect(FileManager.default.fileExists(atPath: cachePath))

  var statBuf = stat()
  let statResult = stat(cachePath, &statBuf)
  #expect(statResult == 0)
  let permissions = statBuf.st_mode & 0o777
  #expect(permissions == 0o600)
}
