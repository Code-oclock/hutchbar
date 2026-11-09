// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Filesystem access interface for Claude Code hooks inspection and installation.
public protocol ClaudeHooksFileSystem: Sendable {
  func fileExists(atPath path: String) -> Bool
  func isDirectory(atPath path: String) -> Bool
  func createDirectory(atPath path: String, mode: mode_t) throws
  func readFile(atPath path: String) throws -> Data
  func writeFile(atPath path: String, data: Data, mode: mode_t) throws
  func rename(fromPath: String, toPath: String) throws
  func copyFile(fromPath: String, toPath: String) throws
  func permissions(atPath path: String) -> mode_t?
  func setPermissions(atPath path: String, mode: mode_t) throws
  func removeItem(atPath path: String) throws
}

/// Default filesystem implementation backed by Foundation FileManager and Darwin POSIX APIs.
public struct DefaultClaudeHooksFileSystem: ClaudeHooksFileSystem {
  public init() {}

  public func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func isDirectory(atPath path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  public func createDirectory(atPath path: String, mode: mode_t) throws {
    do {
      try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: nil
      )
    } catch {
      throw ClaudeHooksError.cannotCreateDirectory(path: path)
    }
    guard Darwin.chmod(path, mode) == 0 else {
      throw ClaudeHooksError.cannotCreateDirectory(path: path)
    }
  }

  public func readFile(atPath path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
  }

  public func writeFile(atPath path: String, data: Data, mode: mode_t) throws {
    try data.write(to: URL(fileURLWithPath: path))
    guard Darwin.chmod(path, mode) == 0 else {
      throw ClaudeHooksError.cannotWrite(path: path)
    }
  }

  public func rename(fromPath: String, toPath: String) throws {
    guard Darwin.rename(fromPath, toPath) == 0 else {
      throw ClaudeHooksError.cannotWrite(path: toPath)
    }
  }

  public func copyFile(fromPath: String, toPath: String) throws {
    try FileManager.default.copyItem(atPath: fromPath, toPath: toPath)
  }

  public func permissions(atPath path: String) -> mode_t? {
    var status = stat()
    guard stat(path, &status) == 0 else { return nil }
    return mode_t(status.st_mode & 0o777)
  }

  public func setPermissions(atPath path: String, mode: mode_t) throws {
    guard Darwin.chmod(path, mode) == 0 else {
      throw ClaudeHooksError.cannotWrite(path: path)
    }
  }

  public func removeItem(atPath path: String) throws {
    try FileManager.default.removeItem(atPath: path)
  }
}
