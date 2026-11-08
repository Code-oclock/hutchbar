// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum TailError: Error, CustomStringConvertible, Sendable {
  case invalidConfiguration
  case unavailable
  case unsafeFile
  case ioFailure
  case stopped

  public var description: String {
    switch self {
    case .invalidConfiguration: "Invalid tail reader configuration."
    case .unavailable: "Log file is unavailable."
    case .unsafeFile: "Log path must contain only directories and a regular file, without symlinks."
    case .ioFailure: "Log file operation failed."
    case .stopped: "Tail reader has stopped."
    }
  }
}

public struct FileSnapshot: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let size: UInt64

  public init(device: UInt64, inode: UInt64, size: UInt64) {
    self.device = device
    self.inode = inode
    self.size = size
  }
}

/// Implementations must reject symlinks and nonregular files, including during races.
/// Errors from implementations are replaced with content-free TailError values.
public protocol TailFileSystem {
  func openRegularFile(at path: String) throws -> any TailFile
}

public protocol TailFile: AnyObject {
  func snapshot() throws -> FileSnapshot
  func read(from offset: UInt64, count: Int) throws -> Data
  func close()
}

public protocol TailClock {
  func now() -> Date
}

public struct SystemTailClock: TailClock {
  public init() {}
  public func now() -> Date { Date() }
}

/// Bytes are deliberately available only through an explicit property.
public struct JSONLLine: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let bytes: Data
  public var description: String { "JSONLLine(\(bytes.count) bytes)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["byteCount": bytes.count]) }
}

public struct TailBatch: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let lines: [JSONLLine]
  public let skippedLongLines: Int
  public let observedAt: Date
  public var description: String {
    "TailBatch(lines: \(lines.count), skippedLongLines: \(skippedLongLines))"
  }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["summary": description]) }
}

/// A single-owner, synchronous byte framer. Call poll on one serial executor.
/// It never logs, decodes, persists, or interprets JSON payloads.
public final class JSONLTailReader: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  private let path: String
  private let fileSystem: any TailFileSystem
  private let clock: any TailClock
  private let maximumLineBytes: Int
  private let maximumReadBytes: Int
  private let startFromTail: UInt64?
  private var isFirstPoll = true
  private var identity: FileSnapshot?
  private var offset: UInt64 = 0
  private var pending = Data()
  private var discarding = false
  private var isStopped = false
  public private(set) var skippedLongLines = 0

  public var description: String { "JSONLTailReader(stopped: \(isStopped))" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["summary": description]) }

  public init(
    path: String,
    fileSystem: any TailFileSystem = LocalTailFileSystem(),
    clock: any TailClock = SystemTailClock(),
    maximumLineBytes: Int = 1_048_576,
    maximumReadBytes: Int = 65_536,
    startFromTail: UInt64? = nil
  ) throws {
    guard maximumLineBytes > 0, maximumReadBytes > 0 else {
      throw TailError.invalidConfiguration
    }
    self.path = path
    self.fileSystem = fileSystem
    self.clock = clock
    self.maximumLineBytes = maximumLineBytes
    self.maximumReadBytes = maximumReadBytes
    self.startFromTail = startFromTail
  }

  public func poll() throws -> TailBatch {
    guard !isStopped else { throw TailError.stopped }
    do {
      let file = try fileSystem.openRegularFile(at: path)
      defer { file.close() }
      let snapshot = try file.snapshot()
      if let previous = identity,
        previous.device != snapshot.device || previous.inode != snapshot.inode
          || snapshot.size < offset
      {
        resetTail()
      }
      if isFirstPoll {
        isFirstPoll = false
        if let startFromTail, snapshot.size > startFromTail {
          offset = snapshot.size - startFromTail
          discarding = true
        }
      }
      identity = snapshot
      let data = try file.read(from: offset, count: maximumReadBytes)
      guard data.count <= maximumReadBytes else { throw TailError.ioFailure }
      offset += UInt64(data.count)
      let skippedBefore = skippedLongLines
      var lines: [JSONLLine] = []
      var currentIndex = data.startIndex
      while currentIndex < data.endIndex {
        if discarding {
          if let newlineIndex = data[currentIndex...].firstIndex(of: 0x0A) {
            discarding = false
            currentIndex = data.index(after: newlineIndex)
          } else {
            currentIndex = data.endIndex
          }
        } else {
          if let newlineIndex = data[currentIndex...].firstIndex(of: 0x0A) {
            let chunk = data[currentIndex..<newlineIndex]
            let availableCapacity = maximumLineBytes - pending.count
            if chunk.count <= availableCapacity {
              pending.append(contentsOf: chunk)
              lines.append(JSONLLine(bytes: pending))
              pending.removeAll(keepingCapacity: true)
            } else {
              pending.removeAll(keepingCapacity: true)
              skippedLongLines += 1
            }
            currentIndex = data.index(after: newlineIndex)
          } else {
            let chunk = data[currentIndex...]
            let availableCapacity = maximumLineBytes - pending.count
            if chunk.count <= availableCapacity {
              pending.append(contentsOf: chunk)
            } else {
              pending.removeAll(keepingCapacity: true)
              discarding = true
              skippedLongLines += 1
            }
            currentIndex = data.endIndex
          }
        }
      }
      return TailBatch(
        lines: lines, skippedLongLines: skippedLongLines - skippedBefore, observedAt: clock.now())
    } catch {
      // Never propagate arbitrary filesystem errors: they may carry private payloads/paths.
      resetTail()
      if let safeError = error as? TailError { throw safeError }
      throw TailError.ioFailure
    }
  }

  /// Idempotent; releases buffered bytes. No descriptor or background work survives a poll.
  public func stop() {
    isStopped = true
    resetTail()
  }

  private func resetTail() {
    identity = nil
    offset = 0
    pending = Data()
    discarding = false
  }
}
