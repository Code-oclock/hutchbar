// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

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
}
