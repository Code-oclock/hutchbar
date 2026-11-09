// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Fingerprint of an OpenCode SQLite database (db and db-wal files).
public struct OpenCodeDatabaseFingerprint: Equatable, Sendable {
  public let size: UInt64
  public let mtime: TimeInterval

  public init(size: UInt64, mtime: TimeInterval) {
    self.size = size
    self.mtime = mtime
  }
}

/// Tracks OpenCode polling state outside of SourceCoordinator to keep actor body small.
public final class OpenCodeSessionTracker: @unchecked Sendable {
  public private(set) var lastScanTime: Date = .distantPast
  public private(set) var lastReadTime: Date = .distantPast
  public private(set) var lastFingerprint: OpenCodeDatabaseFingerprint?
  public var knownSnapshots: [String: SessionSnapshot] = [:]

  public init() {}

  /// Enforces scan rate throttling (e.g. at most once every 5 seconds).
  public func shouldScan(now: Date, interval: TimeInterval = 5.0) -> Bool {
    guard lastScanTime == .distantPast || now.timeIntervalSince(lastScanTime) >= interval else {
      return false
    }
    lastScanTime = now
    return true
  }

  /// Determines whether the database should be queried.
  public func shouldRead(fingerprint: OpenCodeDatabaseFingerprint, now: Date) -> Bool {
    if lastFingerprint != fingerprint {
      return true
    }
    if lastReadTime == .distantPast || now.timeIntervalSince(lastReadTime) >= 60.0 {
      return true
    }
    return false
  }

  /// Records a successful database read.
  public func recordRead(fingerprint: OpenCodeDatabaseFingerprint, now: Date) {
    self.lastFingerprint = fingerprint
    self.lastReadTime = now
  }

  /// Clears tracker state.
  public func reset() {
    lastScanTime = .distantPast
    lastReadTime = .distantPast
    lastFingerprint = nil
    knownSnapshots.removeAll()
  }

  /// Computes the combined size and newest mtime of the database file and its WAL file.
  public static func computeFingerprint(databasePath: String) -> OpenCodeDatabaseFingerprint? {
    let resolvedDbPath = (databasePath as NSString).expandingTildeInPath
    var dbStat = stat()
    guard stat(resolvedDbPath, &dbStat) == 0,
      (dbStat.st_mode & S_IFMT) == S_IFREG
    else {
      return nil
    }

    var totalSize = UInt64(max(0, dbStat.st_size))
    var maxMtime =
      TimeInterval(dbStat.st_mtimespec.tv_sec)
      + TimeInterval(dbStat.st_mtimespec.tv_nsec) / 1_000_000_000.0

    let walPath = resolvedDbPath + "-wal"
    var walStat = stat()
    if stat(walPath, &walStat) == 0, (walStat.st_mode & S_IFMT) == S_IFREG {
      totalSize += UInt64(max(0, walStat.st_size))
      let walMtime =
        TimeInterval(walStat.st_mtimespec.tv_sec)
        + TimeInterval(walStat.st_mtimespec.tv_nsec) / 1_000_000_000.0
      if walMtime > maxMtime {
        maxMtime = walMtime
      }
    }

    return OpenCodeDatabaseFingerprint(size: totalSize, mtime: maxMtime)
  }
}
