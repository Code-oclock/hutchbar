// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Gemini Polling

extension SourceCoordinator {
  func pollGeminiSessions(now: Date) {
    guard configuration.enabledSources.contains(.geminiSessions) else { return }
    guard geminiTracker.shouldScan(now: now, interval: 5.0) else { return }

    let cutoff = now.addingTimeInterval(-configuration.freshnessWindow)
    let discovered = discoverGeminiSessionFiles(cutoff: cutoff)
    let sorted = discovered.sorted { $0.file.modificationDate > $1.file.modificationDate }
    let selected = Array(sorted.prefix(configuration.maxTrackedFiles))

    var currentSessionIds: Set<String> = []

    for item in selected {
      pollSingleGeminiFile(item: item, now: now, currentSessionIds: &currentSessionIds)
    }

    handleDisappearedGeminiSessions(currentSessionIds: currentSessionIds)
  }

  private struct DiscoveredGeminiFile {
    let file: FileMetadata
    let projectInfo: GeminiProjectInfo

    init(file: FileMetadata, projectInfo: GeminiProjectInfo) {
      self.file = file
      self.projectInfo = projectInfo
    }
  }

  private func discoverGeminiSessionFiles(cutoff: Date) -> [DiscoveredGeminiFile] {
    let root = (configuration.geminiTmpRoot as NSString).expandingTildeInPath
    guard let projectEntries = try? directoryLister.contentsOfDirectory(atPath: root) else {
      return []
    }
    var results: [DiscoveredGeminiFile] = []
    for projectDir in projectEntries where projectDir.isDirectory {
      let dirName = URL(fileURLWithPath: projectDir.path).lastPathComponent
      guard !dirName.hasPrefix(".") else { continue }

      let projectInfo = resolveProjectInfo(for: projectDir.path, dirName: dirName)
      let chatsDirPath = (projectDir.path as NSString).appendingPathComponent("chats")
      guard let chatFiles = try? directoryLister.contentsOfDirectory(atPath: chatsDirPath) else {
        continue
      }
      for chatFile in chatFiles where !chatFile.isDirectory {
        let fileName = URL(fileURLWithPath: chatFile.path).lastPathComponent
        guard fileName.hasPrefix("session-") && fileName.hasSuffix(".json") else { continue }
        if chatFile.modificationDate >= cutoff {
          results.append(DiscoveredGeminiFile(file: chatFile, projectInfo: projectInfo))
        }
      }
    }
    return results
  }

  private func resolveProjectInfo(for projectDirPath: String, dirName: String) -> GeminiProjectInfo
  {
    let projectRootPath = (projectDirPath as NSString).appendingPathComponent(".project_root")
    var rootContent: String?
    if let rootFile = try? fileSystem.openRegularFile(at: projectRootPath) {
      defer { rootFile.close() }
      if let snapshot = try? rootFile.snapshot(),
        snapshot.size > 0 && snapshot.size <= 4096,
        let data = try? rootFile.read(from: 0, count: Int(snapshot.size))
      {
        rootContent = String(data: data, encoding: .utf8)
      }
    }
    return GeminiSessionParser.resolveProject(
      projectDirName: dirName,
      projectRootContent: rootContent
    )
  }

  private func pollSingleGeminiFile(
    item: DiscoveredGeminiFile,
    now: Date,
    currentSessionIds: inout Set<String>
  ) {
    let path = item.file.path
    let mtime = item.file.modificationDate

    guard let file = try? fileSystem.openRegularFile(at: path) else { return }
    defer { file.close() }
    guard let snapshot = try? file.snapshot() else { return }
    let size = snapshot.size
    guard size <= 20 * 1024 * 1024 else { return }

    if geminiTracker.hasFileChanged(path: path, size: size, mtime: mtime) {
      readAndProcessGeminiFile(
        file: file,
        path: path,
        size: size,
        mtime: mtime,
        projectInfo: item.projectInfo,
        now: now,
        currentSessionIds: &currentSessionIds
      )
    } else {
      checkUnchangedGeminiFile(path: path, now: now, currentSessionIds: &currentSessionIds)
    }
  }

  private func readAndProcessGeminiFile(
    file: any TailFile,
    path: String,
    size: UInt64,
    mtime: Date,
    projectInfo: GeminiProjectInfo,
    now: Date,
    currentSessionIds: inout Set<String>
  ) {
    // Gemini CLI rewrites the whole file every turn: a read can catch it half-written.
    // Keep the previous snapshot then instead of reporting the session as gone.
    guard let data = try? file.read(from: 0, count: Int(size)),
      let session = GeminiSessionParser.parse(
        data: data,
        filePath: path,
        projectInfo: projectInfo,
        fileMtime: mtime,
        now: now
      )
    else {
      if let previousId = geminiTracker.sessionId(for: path) {
        currentSessionIds.insert(previousId)
      }
      return
    }

    geminiTracker.recordRead(
      path: path,
      size: size,
      mtime: mtime,
      sessionId: session.id,
      now: now
    )
    currentSessionIds.insert(session.id)
    if geminiTracker.knownSnapshots[session.id] != session {
      geminiTracker.knownSnapshots[session.id] = session
      yieldUpdate(.session(session))
    }
  }

  private func checkUnchangedGeminiFile(
    path: String,
    now: Date,
    currentSessionIds: inout Set<String>
  ) {
    guard let existingId = geminiTracker.sessionId(for: path),
      let existingSession = geminiTracker.knownSnapshots[existingId]
    else {
      return
    }
    currentSessionIds.insert(existingId)
    if geminiTracker.shouldCheckInactivity(path: path, now: now) {
      let updated = GeminiSessionParser.applyInactivityRule(to: existingSession, now: now)
      if updated != existingSession {
        geminiTracker.knownSnapshots[existingId] = updated
        yieldUpdate(.session(updated))
      }
    }
  }

  private func handleDisappearedGeminiSessions(currentSessionIds: Set<String>) {
    var disappearedIds: [String] = []
    for (id, oldSnapshot) in geminiTracker.knownSnapshots {
      if !currentSessionIds.contains(id) {
        disappearedIds.append(id)
        if oldSnapshot.state != .finished {
          var finished = oldSnapshot
          finished.state = .finished
          finished.waitingSince = nil
          yieldUpdate(.session(finished))
        }
      }
    }

    for id in disappearedIds {
      geminiTracker.removeTrackedSession(id: id)
    }
  }
}
