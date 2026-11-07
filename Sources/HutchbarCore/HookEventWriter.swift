// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Appends hook event records to a secure local JSONL log file.
/// Enforces directory permissions 0700 and file permissions 0600.
/// Truncates files exceeding 1 MiB to 0 before appending.
public struct HookEventWriter: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public static let maximumFileBytes: off_t = 1_048_576

  public let path: String

  public init(path: String = HookEventWriter.defaultEventsPath) {
    self.path = path
  }

  public var description: String { "HookEventWriter()" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }

  public static var defaultEventsPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Application Support/hutchbar/events.jsonl").path
  }

  public static func expandPath(_ path: String) -> String {
    if path == "~" {
      return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if path.hasPrefix("~/") {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      return home + path.dropFirst()
    }
    return path
  }

  @discardableResult
  public func write(line: Data) -> Bool {
    Self.write(line: line, to: path)
  }

  @discardableResult
  public func write(line: String) -> Bool {
    Self.write(line: Data(line.utf8), to: path)
  }

  @discardableResult
  public func write(event: HookEvent) -> Bool {
    Self.write(event: event, to: path)
  }

  @discardableResult
  public func append(line: Data) -> Bool {
    Self.write(line: line, to: path)
  }

  @discardableResult
  public func append(line: String) -> Bool {
    Self.write(line: Data(line.utf8), to: path)
  }

  @discardableResult
  public func append(event: HookEvent) -> Bool {
    Self.write(event: event, to: path)
  }

  @discardableResult
  public static func write(line: String, to path: String) -> Bool {
    write(line: Data(line.utf8), to: path)
  }

  @discardableResult
  public static func write(event: HookEvent, to path: String) -> Bool {
    write(line: encode(event), to: path)
  }

  @discardableResult
  public static func append(line: Data, to path: String) -> Bool {
    write(line: line, to: path)
  }

  @discardableResult
  public static func append(line: String, to path: String) -> Bool {
    write(line: Data(line.utf8), to: path)
  }

  @discardableResult
  public static func append(event: HookEvent, to path: String) -> Bool {
    write(event: event, to: path)
  }

  @discardableResult
  public static func write(line: Data, to path: String) -> Bool {
    guard !path.isEmpty, !path.utf8.contains(0) else { return false }
    let resolved = expandPath(path)
    let fileURL = URL(fileURLWithPath: resolved)
    let dirPath = fileURL.deletingLastPathComponent().path
    guard !dirPath.isEmpty else { return false }

    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: dirPath) {
      do {
        try fileManager.createDirectory(
          atPath: dirPath,
          withIntermediateDirectories: true,
          attributes: nil
        )
      } catch {
        return false
      }
    }

    var dirStat = stat()
    guard lstat(dirPath, &dirStat) == 0 else { return false }
    guard (dirStat.st_mode & S_IFMT) == S_IFDIR else { return false }
    if dirPath != "/" {
      chmod(dirPath, 0o700)
    }

    let descriptor = Darwin.open(
      resolved,
      O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    fchmod(descriptor, 0o600)

    var fileStat = stat()
    guard fstat(descriptor, &fileStat) == 0 else { return false }
    guard (fileStat.st_mode & S_IFMT) == S_IFREG else { return false }

    if fileStat.st_size > maximumFileBytes {
      guard ftruncate(descriptor, 0) == 0 else { return false }
      lseek(descriptor, 0, SEEK_SET)
    }

    var bytesToWrite = line
    if bytesToWrite.last != 0x0A {
      bytesToWrite.append(0x0A)
    }

    var written = 0
    let total = bytesToWrite.count
    let success = bytesToWrite.withUnsafeBytes { rawBuffer -> Bool in
      guard let base = rawBuffer.baseAddress else { return false }
      while written < total {
        let result = Darwin.write(descriptor, base.advanced(by: written), total - written)
        if result < 0 {
          if errno == EINTR { continue }
          return false
        }
        if result == 0 { return false }
        written += result
      }
      return true
    }
    return success
  }
}

@discardableResult
public func writeHookEventLine(_ line: Data, to path: String) -> Bool {
  HookEventWriter.write(line: line, to: path)
}

@discardableResult
public func writeHookEvent(_ event: HookEvent, to path: String) -> Bool {
  HookEventWriter.write(event: event, to: path)
}
