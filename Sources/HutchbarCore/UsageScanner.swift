// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Per-file usage record cached to avoid re-parsing unchanged logs.
public struct CachedFileUsage: Codable, Sendable, Equatable {
  public let path: String
  public let size: UInt64
  public let mtime: TimeInterval
  public let events: [UsageEvent]

  public init(path: String, size: UInt64, mtime: TimeInterval, events: [UsageEvent]) {
    self.path = path
    self.size = size
    self.mtime = mtime
    self.events = events
  }
}

/// Disk cache model for storing scanned transcript token usage.
public struct UsageCacheFile: Codable, Sendable, Equatable {
  public var version: Int = 2
  public var entries: [String: CachedFileUsage] = [:]

  public init(version: Int = 2, entries: [String: CachedFileUsage] = [:]) {
    self.version = version
    self.entries = entries
  }
}

/// Scans Claude and Codex transcripts periodically and publishes ledger snapshots.
public actor UsageScanner {
  public static var defaultCacheFilePath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/hutchbar/usage-cache.json").path
  }

  public let cacheFilePath: String
  public let claudeProjectsRoot: String
  public let codexSessionsRoot: String
  public let rescanInterval: TimeInterval
  public let cutoffDays: Int

  private let fileSystem: any TailFileSystem
  private let directoryLister: any DirectoryLister
  private let clock: any TailClock
  private let calendar: Calendar

  public nonisolated let snapshots: AsyncStream<UsageLedger>
  private let continuation: AsyncStream<UsageLedger>.Continuation

  private var cache: UsageCacheFile
  /// True when a cache file of another version was found and must be rewritten.
  private var cacheNeedsRewrite = false
  private var isRunning = false
  private var isStopped = false
  private var scanTask: Task<Void, Never>?

  public init(
    cacheFilePath: String = UsageScanner.defaultCacheFilePath,
    claudeProjectsRoot: String = SourceCoordinator.Configuration.defaultClaudeProjectsRoot,
    codexSessionsRoot: String = SourceCoordinator.Configuration.defaultCodexSessionsRoot,
    fileSystem: any TailFileSystem = LocalTailFileSystem(),
    directoryLister: any DirectoryLister = LocalDirectoryLister(),
    clock: any TailClock = SystemTailClock(),
    calendar: Calendar = Calendar.current,
    rescanInterval: TimeInterval = 60.0,
    cutoffDays: Int = 35
  ) {
    self.cacheFilePath = cacheFilePath
    self.claudeProjectsRoot = claudeProjectsRoot
    self.codexSessionsRoot = codexSessionsRoot
    self.fileSystem = fileSystem
    self.directoryLister = directoryLister
    self.clock = clock
    self.calendar = calendar
    self.rescanInterval = rescanInterval
    self.cutoffDays = cutoffDays

    let loaded = Self.loadCache(from: cacheFilePath)
    self.cache = loaded.cache
    self.cacheNeedsRewrite = loaded.discarded

    let (stream, continuation) = AsyncStream.makeStream(
      of: UsageLedger.self,
      bufferingPolicy: .bufferingNewest(32)
    )
    self.snapshots = stream
    self.continuation = continuation
  }

  deinit {
    scanTask?.cancel()
    continuation.finish()
  }

  /// Starts the periodic background scanner.
  public func start() {
    guard !isRunning, !isStopped else { return }
    isRunning = true
    let interval = rescanInterval
    scanTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { break }
        _ = await self.scanOnce()
        do {
          try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } catch {
          break
        }
      }
    }
  }

  /// Stops background scanning. Idempotent.
  public func stop() {
    guard !isStopped else { return }
    isStopped = true
    isRunning = false
    scanTask?.cancel()
    scanTask = nil
    continuation.finish()
  }

  /// Deterministic one-pass scan used directly in tests and by the periodic loop.
  @discardableResult
  public func scanOnce() async -> UsageLedger {
    let now = clock.now()
    let cutoff = now.addingTimeInterval(-Double(cutoffDays) * 86400)

    let claudeFiles = discoverClaudeFiles(cutoff: cutoff)
    let codexFiles = discoverCodexFiles(cutoff: cutoff, now: now)

    var cacheModified = cacheNeedsRewrite
    cacheNeedsRewrite = false
    var activePaths = Set<String>()

    for file in claudeFiles {
      activePaths.insert(file.path)
      let mtime = file.modificationDate.timeIntervalSince1970
      if let cached = cache.entries[file.path], cached.mtime == mtime {
        continue
      }
      if let (size, events) = readFileAndParse(path: file.path, agent: .claudeCode) {
        cache.entries[file.path] = CachedFileUsage(
          path: file.path,
          size: size,
          mtime: mtime,
          events: events
        )
        cacheModified = true
      }
    }

    for file in codexFiles {
      activePaths.insert(file.path)
      let mtime = file.modificationDate.timeIntervalSince1970
      if let cached = cache.entries[file.path], cached.mtime == mtime {
        continue
      }
      if let (size, events) = readFileAndParse(path: file.path, agent: .codex) {
        cache.entries[file.path] = CachedFileUsage(
          path: file.path,
          size: size,
          mtime: mtime,
          events: events
        )
        cacheModified = true
      }
    }

    let existingPaths = Array(cache.entries.keys)
    for path in existingPaths where !activePaths.contains(path) {
      cache.entries.removeValue(forKey: path)
      cacheModified = true
    }

    if cacheModified {
      saveCache()
    }

    var ledger = UsageLedger()
    for path in activePaths {
      if let entry = cache.entries[path] {
        ledger.record(entry.events)
      }
    }

    if !isStopped {
      continuation.yield(ledger)
    }
    return ledger
  }

  // MARK: - Discovery

  private func discoverClaudeFiles(cutoff: Date) -> [FileMetadata] {
    let resolvedRoot = (claudeProjectsRoot as NSString).expandingTildeInPath
    guard let projectDirs = try? directoryLister.contentsOfDirectory(atPath: resolvedRoot) else {
      return []
    }
    var results: [FileMetadata] = []
    for projectDir in projectDirs where projectDir.isDirectory {
      guard let files = try? directoryLister.contentsOfDirectory(atPath: projectDir.path) else {
        continue
      }
      for file in files where !file.isDirectory && file.path.hasSuffix(".jsonl") {
        if file.modificationDate >= cutoff {
          results.append(file)
        }
      }
    }
    return results
  }

  private func discoverCodexFiles(cutoff: Date, now: Date) -> [FileMetadata] {
    let resolvedRoot = (codexSessionsRoot as NSString).expandingTildeInPath
    var results: [FileMetadata] = []
    var seenPaths: Set<String> = []

    if let topEntries = try? directoryLister.contentsOfDirectory(atPath: resolvedRoot) {
      for entry in topEntries {
        if !entry.isDirectory && entry.path.hasSuffix(".jsonl") {
          if entry.modificationDate >= cutoff && !seenPaths.contains(entry.path) {
            seenPaths.insert(entry.path)
            results.append(entry)
          }
        } else if entry.isDirectory {
          if let monthEntries = try? directoryLister.contentsOfDirectory(atPath: entry.path) {
            for monthDir in monthEntries where monthDir.isDirectory {
              if let dayEntries = try? directoryLister.contentsOfDirectory(atPath: monthDir.path) {
                for dayDir in dayEntries where dayDir.isDirectory {
                  if let files = try? directoryLister.contentsOfDirectory(atPath: dayDir.path) {
                    for file in files where !file.isDirectory && file.path.hasSuffix(".jsonl") {
                      if file.modificationDate >= cutoff && !seenPaths.contains(file.path) {
                        seenPaths.insert(file.path)
                        results.append(file)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    let timeZones = [calendar.timeZone, TimeZone(secondsFromGMT: 0) ?? calendar.timeZone]
    for timeZone in timeZones {
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = timeZone
      for dayOffset in 0...cutoffDays {
        guard let dayDate = cal.date(byAdding: .day, value: -dayOffset, to: now) else {
          continue
        }
        let comps = cal.dateComponents([.year, .month, .day], from: dayDate)
        guard let year = comps.year, let month = comps.month, let day = comps.day else { continue }
        let dayPath = String(format: "%@/%04d/%02d/%02d", resolvedRoot, year, month, day)
        guard let files = try? directoryLister.contentsOfDirectory(atPath: dayPath) else {
          continue
        }
        for file in files where !file.isDirectory && file.path.hasSuffix(".jsonl") {
          if file.modificationDate >= cutoff && !seenPaths.contains(file.path) {
            seenPaths.insert(file.path)
            results.append(file)
          }
        }
      }
    }

    return results
  }

  // MARK: - File Reading & Parsing

  private func readFileAndParse(
    path: String,
    agent: AgentKind
  ) -> (size: UInt64, events: [UsageEvent])? {
    do {
      let file = try fileSystem.openRegularFile(at: path)
      defer { file.close() }
      let snapshot = try file.snapshot()
      let size = snapshot.size
      guard size <= 50_000_000 else { return nil }

      var data = Data()
      data.reserveCapacity(Int(min(size, 10_000_000)))
      var offset: UInt64 = 0
      let chunkSize = 65_536
      while offset < size {
        let count = Int(min(UInt64(chunkSize), size - offset))
        let chunk = try file.read(from: offset, count: count)
        if chunk.isEmpty { break }
        data.append(chunk)
        offset += UInt64(chunk.count)
      }

      guard let text = String(data: data, encoding: .utf8) else { return nil }
      let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

      return (size, Self.parseUsageEvents(agent: agent, lines: lines, calendar: calendar))
    } catch {
      return nil
    }
  }

  // MARK: - Persistence

  /// Loads the cache; `discarded` is true when a file existed but was unreadable or of
  /// another version, so the next scan rewrites it.
  private static func loadCache(from path: String) -> (cache: UsageCacheFile, discarded: Bool) {
    let resolved = (path as NSString).expandingTildeInPath
    var statBuf = stat()
    guard lstat(resolved, &statBuf) == 0 else { return (UsageCacheFile(version: 2), false) }
    // Never rewrite through a symlink or other special file.
    guard (statBuf.st_mode & S_IFMT) == S_IFREG else { return (UsageCacheFile(version: 2), false) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
      let loaded = try? JSONDecoder().decode(UsageCacheFile.self, from: data),
      loaded.version == 2
    else {
      return (UsageCacheFile(version: 2), true)
    }
    return (loaded, false)
  }

  private func saveCache() {
    let resolved = (cacheFilePath as NSString).expandingTildeInPath
    let parent = (resolved as NSString).deletingLastPathComponent

    try? FileManager.default.createDirectory(
      atPath: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    var targetStat = stat()
    if lstat(resolved, &targetStat) == 0 {
      guard (targetStat.st_mode & S_IFMT) == S_IFREG else { return }
    }

    guard let data = try? JSONEncoder().encode(cache) else { return }

    let tempPath = resolved + ".tmp." + UUID().uuidString
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    let mode: mode_t = S_IRUSR | S_IWUSR
    let fd = Darwin.open(tempPath, flags, mode)
    guard fd >= 0 else { return }

    _ = fchmod(fd, mode)

    var written = 0
    let total = data.count
    let success = data.withUnsafeBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else { return false }
      while written < total {
        let result = Darwin.write(fd, baseAddress.advanced(by: written), total - written)
        if result <= 0 { return false }
        written += result
      }
      return true
    }

    Darwin.close(fd)

    guard success else {
      Darwin.unlink(tempPath)
      return
    }

    if Darwin.rename(tempPath, resolved) != 0 {
      Darwin.unlink(tempPath)
    }
  }
}

extension UsageScanner {
  /// Usage events of one transcript file; agents without file transcripts yield none.
  static func parseUsageEvents(agent: AgentKind, lines: [String], calendar: Calendar)
    -> [UsageEvent]
  {
    switch agent {
    case .claudeCode:
      var seenMessageIds = Set<String>()
      return parseClaudeUsage(lines: lines, seenMessageIds: &seenMessageIds, calendar: calendar)
    case .codex:
      var state = CodexUsageState()
      return parseCodexUsage(lines: lines, state: &state, calendar: calendar)
    case .antigravity, .qwen, .opencode, .copilot:
      return []
    }
  }
}
