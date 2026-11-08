// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

extension UsageScanner {
  public static var defaultOpenCodeDatabasePath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/opencode/opencode.db").path
  }

  func recordOpenCode(
    cutoff: Date,
    activePaths: inout Set<String>,
    cacheModified: inout Bool
  ) {
    let resolvedDbPath = (openCodeDatabasePath as NSString).expandingTildeInPath
    var dbStat = stat()
    guard stat(resolvedDbPath, &dbStat) == 0,
      (dbStat.st_mode & S_IFMT) == S_IFREG
    else {
      return
    }

    activePaths.insert(resolvedDbPath)

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

    if let cached = cache.entries[resolvedDbPath],
      cached.size == totalSize,
      cached.mtime == maxMtime
    {
      return
    }

    let reader = OpenCodeUsageReader(databasePath: resolvedDbPath)
    // A locked or broken database keeps the previous entry (or none) until it changes again.
    guard let events = reader.readEvents(cutoff: cutoff, calendar: calendar) else { return }
    cache.entries[resolvedDbPath] = CachedFileUsage(
      path: resolvedDbPath,
      size: totalSize,
      mtime: maxMtime,
      events: events
    )
    cacheModified = true
  }
}
