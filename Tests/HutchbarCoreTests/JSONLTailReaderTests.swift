// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private struct FakeClock: TailClock {
  let date = Date(timeIntervalSince1970: 123)
  func now() -> Date { date }
}

private final class FakeFileSystem: TailFileSystem {
  var bytes = Data()
  var inode: UInt64 = 1
  var device: UInt64 = 1
  var opens = 0
  var closes = 0
  var offsets: [UInt64] = []
  var error: (any Error)?
  var readError: (any Error)?

  func append(_ string: String) { bytes.append(contentsOf: string.utf8) }
  func replace(_ string: String) { bytes = Data(string.utf8) }
  func openRegularFile(at path: String) throws -> any TailFile {
    if let error { throw error }
    opens += 1
    return FakeFile(owner: self)
  }
}

private final class FakeFile: TailFile {
  let owner: FakeFileSystem
  private var closed = false
  init(owner: FakeFileSystem) { self.owner = owner }
  func snapshot() -> FileSnapshot {
    FileSnapshot(device: owner.device, inode: owner.inode, size: UInt64(owner.bytes.count))
  }
  func read(from offset: UInt64, count: Int) throws -> Data {
    if let error = owner.readError { throw error }
    owner.offsets.append(offset)
    let start = min(Int(offset), owner.bytes.count)
    return owner.bytes.subdata(in: start..<min(start + count, owner.bytes.count))
  }
  func close() {
    if !closed { owner.closes += 1 }
    closed = true
  }
}

private func strings(_ batch: TailBatch) -> [String] {
  batch.lines.map { String(decoding: $0.bytes, as: UTF8.self) }
}

@Test func sessionStatesRoundTrip() throws {
  #expect(SessionState.allCases.count == 4)
  for state in SessionState.allCases {
    #expect(try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state)) == state)
  }
}

@Test func incrementalReadsAndPartialTail() throws {
  let fs = FakeFileSystem()
  let clock = FakeClock()
  let reader = try JSONLTailReader(path: "unused", fileSystem: fs, clock: clock)
  fs.append("{\"n\":1}\n{\"n\":")
  let first = try reader.poll()
  #expect(strings(first) == ["{\"n\":1}"])
  #expect(first.observedAt == clock.date)
  #expect(try reader.poll().lines.isEmpty)
  fs.append("2}\n")
  #expect(try strings(reader.poll()) == ["{\"n\":2}"])
  #expect(fs.offsets == [0, 13, 13])
  #expect(fs.opens == fs.closes)
}

@Test func lineLimitAcrossPollsCountsOnceAndRecovers() throws {
  let fs = FakeFileSystem()
  let reader = try JSONLTailReader(path: "unused", fileSystem: fs, maximumLineBytes: 4)
  fs.append("1234")
  #expect(try reader.poll().lines.isEmpty)
  fs.append("5")
  #expect(try reader.poll().skippedLongLines == 1)
  fs.append("6789")
  #expect(try reader.poll().skippedLongLines == 0)
  fs.append("\nok\n1234\n12345\n")
  let batch = try reader.poll()
  #expect(strings(batch) == ["ok", "1234"])
  #expect(batch.skippedLongLines == 1)
  #expect(reader.skippedLongLines == 2)
}

@Test func defaultLimitIsOneMiBAndReadsAreBounded() throws {
  let fs = FakeFileSystem()
  let reader = try JSONLTailReader(path: "unused", fileSystem: fs)
  fs.bytes = Data(repeating: 65, count: 1_048_576)
  for _ in 0..<16 { #expect(try reader.poll().lines.isEmpty) }
  fs.append("\n")
  #expect(try reader.poll().lines.first?.bytes.count == 1_048_576)
  fs.bytes.append(Data(repeating: 66, count: 1_048_577))
  fs.append("\n{}\n")
  for _ in 0..<16 { #expect(try reader.poll().lines.isEmpty) }
  let batch = try reader.poll()
  #expect(batch.skippedLongLines == 1)
  #expect(strings(batch) == ["{}"])
}

@Test func rotationAndTruncationDiscardOldPartialBytes() throws {
  let fs = FakeFileSystem()
  let reader = try JSONLTailReader(path: "unused", fileSystem: fs)
  fs.append("old-partial")
  _ = try reader.poll()
  fs.inode += 1
  fs.replace("rotated\n")
  #expect(try strings(reader.poll()) == ["rotated"])
  fs.append("partial")
  _ = try reader.poll()
  fs.replace("x\n")
  #expect(try strings(reader.poll()) == ["x"])
  fs.device += 1
  fs.replace("new-device\n")
  #expect(try strings(reader.poll()) == ["new-device"])
}

@Test func rotationResetsOversizeDiscardMode() throws {
  let fs = FakeFileSystem()
  let reader = try JSONLTailReader(path: "unused", fileSystem: fs, maximumLineBytes: 2)
  fs.append("secret")
  _ = try reader.poll()
  fs.inode += 1
  fs.replace("{}\n")
  #expect(try strings(reader.poll()) == ["{}"])
  #expect(reader.skippedLongLines == 1)
}

@Test func smallChunksPreserveBytesAndDoNotDuplicate() throws {
  let fs = FakeFileSystem()
  let reader = try JSONLTailReader(path: "unused", fileSystem: fs, maximumReadBytes: 2)
  fs.bytes = Data([0xFF, 0x00, 0x0A, 0x0A])
  #expect(try reader.poll().lines.isEmpty)
  let batch = try reader.poll()
  #expect(batch.lines.map(\.bytes) == [Data([0xFF, 0x00]), Data()])
  #expect(try reader.poll().lines.isEmpty)
  #expect(fs.offsets == [0, 2, 4])
}

@Test func errorsAndDescriptionsNeverContainContent() throws {
  let secret = "PRIVATE-PROMPT-DO-NOT-REPORT"
  let fs = FakeFileSystem()
  let reader = try JSONLTailReader(path: secret, fileSystem: fs)
  fs.append(secret + "\n" + secret)
  let batch = try reader.poll()
  for value in [
    String(describing: reader), String(reflecting: reader),
    String(describing: batch), String(reflecting: batch), String(reflecting: batch.lines),
  ] {
    #expect(!value.contains(secret))
  }
  var dumped = ""
  dump(reader, to: &dumped)
  dump(batch, to: &dumped)
  #expect(!dumped.contains(secret))
  fs.readError = NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
  do {
    _ = try reader.poll()
    Issue.record("Expected a sanitized read failure")
  } catch {
    #expect(String(describing: error) == TailError.ioFailure.description)
    #expect(!String(reflecting: error).contains(secret))
  }
  #expect(fs.opens == fs.closes)
  fs.readError = nil
  fs.error = NSError(domain: secret, code: 2)
  #expect(throws: TailError.ioFailure) { try reader.poll() }
  fs.error = TailError.unsafeFile
  #expect(throws: TailError.unsafeFile) { try reader.poll() }
}

@Test func invalidConfigurationAndStoppedReader() throws {
  let fs = FakeFileSystem()
  #expect(throws: TailError.invalidConfiguration) {
    try JSONLTailReader(path: "unused", fileSystem: fs, maximumLineBytes: 0)
  }
  #expect(throws: TailError.invalidConfiguration) {
    try JSONLTailReader(path: "unused", fileSystem: fs, maximumReadBytes: -1)
  }
  let reader = try JSONLTailReader(path: "unused", fileSystem: fs)
  reader.stop()
  reader.stop()
  #expect(throws: TailError.stopped) { try reader.poll() }
  #expect(fs.opens == 0)
}

@Test func stoppedReaderIsReleased() throws {
  let fs = FakeFileSystem()
  weak var weakReader: JSONLTailReader?
  do {
    let reader = try JSONLTailReader(path: "unused", fileSystem: fs)
    weakReader = reader
    fs.append("uncompleted private data")
    _ = try reader.poll()
    reader.stop()
  }
  #expect(weakReader == nil)
  #expect(fs.opens == fs.closes)
}

@Test func realFileAdapterRejectsSymlinksAndDirectoriesAndTracksRotation() throws {
  let fm = FileManager.default
  let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? fm.removeItem(at: root) }
  let log = root.appendingPathComponent("log.jsonl")
  try Data("one\npart".utf8).write(to: log)
  let reader = try JSONLTailReader(path: log.path)
  #expect(try strings(reader.poll()) == ["one"])
  let handle = try FileHandle(forWritingTo: log)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("ial\n".utf8))
  try handle.close()
  #expect(try strings(reader.poll()) == ["partial"])
  try fm.moveItem(at: log, to: root.appendingPathComponent("old"))
  try Data("new\n".utf8).write(to: log)
  #expect(try strings(reader.poll()) == ["new"])
  let short = try FileHandle(forWritingTo: log)
  try short.truncate(atOffset: 0)
  try short.write(contentsOf: Data("x\n".utf8))
  try short.close()
  #expect(try strings(reader.poll()) == ["x"])
  let link = root.appendingPathComponent("link")
  try fm.createSymbolicLink(at: link, withDestinationURL: log)
  let linkedReader = try JSONLTailReader(path: link.path)
  #expect(throws: TailError.unsafeFile) { try linkedReader.poll() }
  let parentLink = root.appendingPathComponent("parent")
  try fm.createSymbolicLink(at: parentLink, withDestinationURL: root)
  let parentReader = try JSONLTailReader(path: parentLink.appendingPathComponent("log.jsonl").path)
  #expect(throws: TailError.unsafeFile) { try parentReader.poll() }
  let directoryReader = try JSONLTailReader(path: root.path)
  #expect(throws: TailError.unsafeFile) { try directoryReader.poll() }
  let missingReader = try JSONLTailReader(path: root.appendingPathComponent("missing").path)
  #expect(throws: TailError.unavailable) { try missingReader.poll() }
  reader.stop()
}
