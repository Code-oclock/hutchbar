// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Metadata for a discovered file or directory entry.
public struct FileMetadata: Equatable, Sendable {
  public let path: String
  public let modificationDate: Date
  public let isDirectory: Bool

  public init(path: String, modificationDate: Date, isDirectory: Bool = false) {
    self.path = path
    self.modificationDate = modificationDate
    self.isDirectory = isDirectory
  }
}

/// Discovers files and directories for transcript and session log tracking.
public protocol DirectoryLister: Sendable {
  func contentsOfDirectory(atPath path: String) throws -> [FileMetadata]
}

/// Default implementation of `DirectoryLister` using the local filesystem.
public struct LocalDirectoryLister: DirectoryLister {
  public init() {}

  public func contentsOfDirectory(atPath path: String) throws -> [FileMetadata] {
    let resolved = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: resolved, isDirectory: true)
    let fileManager = FileManager.default
    let resourceKeys: [URLResourceKey] = [
      .contentModificationDateKey,
      .isDirectoryKey,
      .isSymbolicLinkKey,
    ]
    let urls = try fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: resourceKeys,
      options: [.skipsHiddenFiles]
    )
    var results: [FileMetadata] = []
    results.reserveCapacity(urls.count)
    let keySet = Set(resourceKeys)
    for entryURL in urls {
      guard let values = try? entryURL.resourceValues(forKeys: keySet) else {
        continue
      }
      if values.isSymbolicLink == true {
        continue
      }
      let isDir = values.isDirectory ?? false
      let mtime = values.contentModificationDate ?? Date.distantPast
      results.append(
        FileMetadata(path: entryURL.path, modificationDate: mtime, isDirectory: isDir)
      )
    }
    return results
  }
}

/// Tracks and coordinates all active agent log sources.
public actor SourceCoordinator {
  public struct Configuration: Sendable {
    public var claudeProjectsRoot: String
    public var codexSessionsRoot: String
    public var eventsPath: String
    public var ccrDatabasePath: String
    public var enabledSources: Set<SourceKind>
    public var pollInterval: TimeInterval
    public var freshnessWindow: TimeInterval
    public var maxTrackedFiles: Int

    public init(
      claudeProjectsRoot: String = Configuration.defaultClaudeProjectsRoot,
      codexSessionsRoot: String = Configuration.defaultCodexSessionsRoot,
      eventsPath: String = Configuration.defaultEventsPath,
      ccrDatabasePath: String = CcrQuotaReader.defaultDatabasePath,
      enabledSources: Set<SourceKind> = Set(SourceKind.allCases),
      pollInterval: TimeInterval = 2.0,
      freshnessWindow: TimeInterval = 24 * 3600,
      maxTrackedFiles: Int = 200
    ) {
      self.claudeProjectsRoot = claudeProjectsRoot
      self.codexSessionsRoot = codexSessionsRoot
      self.eventsPath = eventsPath
      self.ccrDatabasePath = ccrDatabasePath
      self.enabledSources = enabledSources
      self.pollInterval = pollInterval
      self.freshnessWindow = freshnessWindow
      self.maxTrackedFiles = maxTrackedFiles
    }

    public static var defaultClaudeProjectsRoot: String {
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects").path
    }

    public static var defaultCodexSessionsRoot: String {
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions").path
    }

    public static var defaultEventsPath: String {
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/hutchbar/events.jsonl").path
    }
  }

  private final class TrackedSession {
    let reader: JSONLTailReader
    let agent: AgentKind
    var snapshot: SessionSnapshot?
    var lastQuota: AccountQuota?

    init(reader: JSONLTailReader, agent: AgentKind) {
      self.reader = reader
      self.agent = agent
    }
  }

  public let configuration: Configuration
  private let fileSystem: any TailFileSystem
  let directoryLister: any DirectoryLister
  let clock: any TailClock
  private let claudeParser = ClaudeTranscriptParser()
  private let ccrReader: CcrQuotaReader

  public nonisolated let updates: AsyncStream<SourceUpdate>
  private let continuation: AsyncStream<SourceUpdate>.Continuation

  private var trackedSessions: [String: TrackedSession] = [:]
  private var eventsReader: JSONLTailReader?
  private var lastCcrPollTime: Date = .distantPast
  private var lastEmittedQuotas: [String: AccountQuota] = [:]
  private var pollTask: Task<Void, Never>?
  private var isRunning = false
  private var isStopped = false

  public init(
    configuration: Configuration = Configuration(),
    fileSystem: any TailFileSystem = LocalTailFileSystem(),
    directoryLister: any DirectoryLister = LocalDirectoryLister(),
    clock: any TailClock = SystemTailClock()
  ) {
    self.configuration = configuration
    self.fileSystem = fileSystem
    self.directoryLister = directoryLister
    self.clock = clock
    self.ccrReader = CcrQuotaReader(databasePath: configuration.ccrDatabasePath)

    let (stream, continuation) = AsyncStream.makeStream(
      of: SourceUpdate.self,
      bufferingPolicy: .bufferingNewest(256)
    )
    self.updates = stream
    self.continuation = continuation
  }

  deinit {
    pollTask?.cancel()
    continuation.finish()
  }

  public func start() {
    guard !isRunning, !isStopped else { return }
    isRunning = true
    let interval = configuration.pollInterval
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { break }
        await self.pollOnce()
        do {
          try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } catch {
          break
        }
      }
    }
  }

  public func stop() {
    guard !isStopped else { return }
    isStopped = true
    isRunning = false
    pollTask?.cancel()
    pollTask = nil

    for (_, tracked) in trackedSessions {
      tracked.reader.stop()
    }
    trackedSessions.removeAll()

    eventsReader?.stop()
    eventsReader = nil

    continuation.finish()
  }

  public func pollOnce() async {
    guard !isStopped else { return }
    let now = clock.now()
    pollSessions(now: now)
    pollEvents()
    pollCcrQuotas(now: now)
  }

  private func pollSessions(now: Date) {
    let cutoff = now.addingTimeInterval(-configuration.freshnessWindow)
    var discovered: [String: (file: FileMetadata, agent: AgentKind)] = [:]

    if configuration.enabledSources.contains(.claudeTranscripts) {
      enumerateClaudeFiles(into: &discovered)
    }
    if configuration.enabledSources.contains(.codexSessions) {
      enumerateCodexFiles(now: now, into: &discovered)
    }

    let fresh = discovered.values.filter { $0.file.modificationDate >= cutoff }
    let sorted = fresh.sorted { $0.file.modificationDate > $1.file.modificationDate }
    let selected = Array(sorted.prefix(configuration.maxTrackedFiles))
    let selectedPaths = Set(selected.map(\.file.path))

    var toRemove: [String] = []
    for (path, tracked) in trackedSessions {
      if !selectedPaths.contains(path) {
        tracked.reader.stop()
        toRemove.append(path)
      }
    }
    for path in toRemove {
      trackedSessions.removeValue(forKey: path)
    }

    for item in selected {
      pollTrackedSession(item: item, now: now)
    }
  }

  private func pollTrackedSession(
    item: (file: FileMetadata, agent: AgentKind),
    now: Date
  ) {
    let path = item.file.path
    let tracked: TrackedSession
    if let existing = trackedSessions[path] {
      tracked = existing
    } else {
      do {
        let reader = try JSONLTailReader(
          path: path,
          fileSystem: fileSystem,
          clock: clock,
          maximumReadBytes: 1_048_576,
          startFromTail: 262_144
        )
        let newTracked = TrackedSession(reader: reader, agent: item.agent)
        trackedSessions[path] = newTracked
        tracked = newTracked
      } catch {
        return
      }
    }

    do {
      let batch = try tracked.reader.poll()
      if !batch.lines.isEmpty {
        switch tracked.agent {
        case .claudeCode:
          let (newSnapshot, _) = claudeParser.parse(
            batch.lines,
            current: tracked.snapshot,
            now: now
          )
          if let newSnapshot, newSnapshot != tracked.snapshot {
            tracked.snapshot = newSnapshot
            yieldUpdate(.session(newSnapshot))
          }
        case .codex:
          let result = CodexSessionParser.parse(
            batch.lines,
            current: tracked.snapshot,
            now: now
          )
          if let newSnapshot = result.snapshot, newSnapshot != tracked.snapshot {
            tracked.snapshot = newSnapshot
            yieldUpdate(.session(newSnapshot))
          }
          if let quota = result.quota, quota != tracked.lastQuota {
            tracked.lastQuota = quota
            yieldUpdate(.quota(quota))
          }
        }
      } else if let current = tracked.snapshot {
        let updated: SessionSnapshot?
        switch tracked.agent {
        case .claudeCode:
          updated = claudeParser.applyInactivity(to: current, now: now)
        case .codex:
          let codexUpdated: SessionSnapshot = CodexSessionParser.applyInactivityRule(
            to: current,
            now: now
          )
          updated = codexUpdated
        }
        if let updated, updated != current {
          tracked.snapshot = updated
          yieldUpdate(.session(updated))
        }
      }
    } catch {
      // Ignore read errors during polling
    }
  }

  private func pollEvents() {
    guard configuration.enabledSources.contains(.claudeHooks) else { return }
    let path = (configuration.eventsPath as NSString).expandingTildeInPath
    let reader: JSONLTailReader
    if let existing = eventsReader {
      reader = existing
    } else {
      do {
        let newReader = try JSONLTailReader(
          path: path,
          fileSystem: fileSystem,
          clock: clock,
          maximumReadBytes: 1_048_576,
          startFromTail: 262_144
        )
        eventsReader = newReader
        reader = newReader
      } catch {
        return
      }
    }

    do {
      let batch = try reader.poll()
      for line in batch.lines {
        if let event = HookEvent.parse(line: line) {
          yieldUpdate(.hookEvent(event))
        }
      }
    } catch {
      // File may not exist yet
    }
  }

  private func pollCcrQuotas(now: Date) {
    guard configuration.enabledSources.contains(.ccrQuotas) else { return }
    guard lastCcrPollTime == .distantPast || now.timeIntervalSince(lastCcrPollTime) >= 30.0 else {
      return
    }
    lastCcrPollTime = now
    let quotas = ccrReader.read(now: now)
    for quota in quotas {
      if lastEmittedQuotas[quota.id] != quota {
        lastEmittedQuotas[quota.id] = quota
        yieldUpdate(.quota(quota))
      }
    }
  }

  private func yieldUpdate(_ update: SourceUpdate) {
    guard !isStopped else { return }
    continuation.yield(update)
  }
}
