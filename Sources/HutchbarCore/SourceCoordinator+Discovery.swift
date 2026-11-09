// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

final class ClaudeSubagentThrottler: @unchecked Sendable {
  private let lock = NSLock()
  private var lastScanTime: Date = .distantPast

  func shouldScan(now: Date, interval: TimeInterval = 5.0) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard now.timeIntervalSince(lastScanTime) >= interval else { return false }
    lastScanTime = now
    return true
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    lastScanTime = .distantPast
  }
}

let subagentThrottler = ClaudeSubagentThrottler()

// File discovery for SourceCoordinator, kept separate to keep the actor body small.
extension SourceCoordinator {
  func enumerateClaudeFiles(
    into discovered: inout [String: (file: FileMetadata, agent: AgentKind)]
  ) {
    let root = (configuration.claudeProjectsRoot as NSString).expandingTildeInPath
    guard let projectDirs = try? directoryLister.contentsOfDirectory(atPath: root) else {
      return
    }
    for projectDir in projectDirs where projectDir.isDirectory {
      guard let files = try? directoryLister.contentsOfDirectory(atPath: projectDir.path) else {
        continue
      }
      for file in files where !file.isDirectory && file.path.hasSuffix(".jsonl") {
        discovered[file.path] = (file, .claudeCode)
      }
    }
    pollClaudeSubagents(now: clock.now())
  }

  func enumerateCodexFiles(
    now: Date,
    into discovered: inout [String: (file: FileMetadata, agent: AgentKind)]
  ) {
    let dayPaths = codexDayPaths(root: configuration.codexSessionsRoot, now: now)
    for dayPath in dayPaths {
      guard let files = try? directoryLister.contentsOfDirectory(atPath: dayPath) else {
        continue
      }
      for file in files where !file.isDirectory && file.path.hasSuffix(".jsonl") {
        discovered[file.path] = (file, .codex)
      }
    }
  }

  func codexDayPaths(root: String, now: Date) -> [String] {
    let resolvedRoot = (root as NSString).expandingTildeInPath
    var paths: [String] = []
    var seen: Set<String> = []

    let timeZones = [
      TimeZone.current,
      TimeZone(secondsFromGMT: 0) ?? TimeZone.current,
    ]
    for timeZone in timeZones {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      for dayOffset in [0, -1] {
        guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
          continue
        }
        let comps = calendar.dateComponents([.year, .month, .day], from: dayDate)
        guard let year = comps.year, let month = comps.month, let day = comps.day else {
          continue
        }
        let path = String(
          format: "%@/%04d/%02d/%02d",
          resolvedRoot, year, month, day
        )
        if !seen.contains(path) {
          seen.insert(path)
          paths.append(path)
        }
      }
    }
    return paths
  }

  func pollClaudeLive(now: Date) {
    guard configuration.enabledSources.contains(.claudeLive) else { return }

    let discovered = ClaudeSessionRegistry.discoverSessions(
      in: configuration.claudeSessionsRoot,
      directoryLister: directoryLister,
      fileSystem: fileSystem
    )

    var currentLiveSessionIds: Set<String> = []

    for session in discovered {
      guard
        ClaudeSessionRegistry.isProcessAlive(
          pid: session.pid,
          procStart: session.procStart,
          table: processTable
        )
      else {
        continue
      }

      currentLiveSessionIds.insert(session.sessionId)
      trackedLiveSessions[session.sessionId] = session.pid
      yieldUpdate(
        .liveStatus(
          sessionId: session.sessionId,
          pid: session.pid,
          status: session.status,
          at: session.statusUpdatedAt,
          cwd: session.cwd
        )
      )
    }

    var disappeared: [String] = []
    for (sessionId, pid) in trackedLiveSessions {
      if !currentLiveSessionIds.contains(sessionId) {
        disappeared.append(sessionId)
        yieldUpdate(
          .liveStatus(
            sessionId: sessionId,
            pid: pid,
            status: .finished,
            at: now
          )
        )
      }
    }
    for sessionId in disappeared {
      trackedLiveSessions.removeValue(forKey: sessionId)
    }
  }

  func pollClaudeSubagents(now: Date) {
    guard configuration.enabledSources.contains(.claudeTranscripts) else { return }
    guard subagentThrottler.shouldScan(now: now, interval: 5.0) else { return }

    let root = (configuration.claudeProjectsRoot as NSString).expandingTildeInPath
    let subagents = ClaudeSubagentScanner.scanProjects(
      projectsRoot: root,
      directoryLister: directoryLister,
      fileSystem: fileSystem,
      now: now
    )
    for subagent in subagents {
      yieldUpdate(.session(subagent))
    }
  }

  func resolveCwd(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    var resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    while resolved.count > 1 && resolved.hasSuffix("/") {
      resolved.removeLast()
    }
    return resolved
  }

  func pollCodexProcesses(now: Date) {
    guard configuration.enabledSources.contains(.codexSessions) else { return }
    guard
      lastCodexProcessCheckTime == .distantPast
        || now.timeIntervalSince(lastCodexProcessCheckTime) >= 10.0
    else {
      return
    }
    lastCodexProcessCheckTime = now

    let activeCodexSessions = trackedSessions.values.filter { tracked in
      guard tracked.agent == .codex, tracked.endsWithProcess,
        let snapshot = tracked.snapshot
      else { return false }
      guard snapshot.state != .finished else { return false }
      guard let cwd = snapshot.cwd, !cwd.isEmpty else { return false }
      return true
    }

    guard !activeCodexSessions.isEmpty else { return }

    let processes = processTable.allProcesses()

    for tracked in activeCodexSessions {
      guard let snapshot = tracked.snapshot, let cwd = snapshot.cwd else { continue }
      let targetPath = resolveCwd(cwd)

      let hasProcess = processes.contains { proc in
        let baseName = URL(fileURLWithPath: proc.executableName).lastPathComponent
        guard baseName == "codex" else { return false }
        guard let procCwd = proc.cwd, !procCwd.isEmpty else { return false }
        return resolveCwd(procCwd) == targetPath
      }

      let sessionId = snapshot.id
      if hasProcess {
        codexMissingProcessCounts[sessionId] = 0
      } else {
        let count = (codexMissingProcessCounts[sessionId] ?? 0) + 1
        codexMissingProcessCounts[sessionId] = count
        if count >= 2 {
          var finishedSnapshot = snapshot
          finishedSnapshot.state = .finished
          finishedSnapshot.waitingSince = nil
          tracked.snapshot = finishedSnapshot
          yieldUpdate(.session(finishedSnapshot))
          codexMissingProcessCounts.removeValue(forKey: sessionId)
        }
      }
    }
  }
}
