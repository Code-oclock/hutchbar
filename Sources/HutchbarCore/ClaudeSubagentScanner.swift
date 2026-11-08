// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure scanner for discovering Claude Code subagent session transcripts.
public enum ClaudeSubagentScanner {
  /// Files modified more than 15 minutes ago are ignored.
  public static let mtimeCutoffInterval: TimeInterval = 15 * 60

  /// Files modified within the last 2 minutes are considered running.
  public static let runningMtimeInterval: TimeInterval = 2 * 60

  /// Maximum byte count read from the beginning of a subagent transcript (64 KiB).
  public static let maxReadBytes: Int = 64 * 1024

  /// Parses explicit metadata title fields from raw file data (up to 64 KiB).
  /// Inspects only metadata fields (agentType, description, subagent_type).
  /// Never reads message content, prompts, or tool execution bodies.
  public static func parseMetadataTitle(from data: Data) -> String? {
    guard !data.isEmpty else { return nil }
    let prefixData = data.prefix(maxReadBytes)
    guard let firstNewline = prefixData.firstIndex(of: 0x0A) else {
      return parseFirstRecord(from: prefixData)
    }
    let firstLine = prefixData[..<firstNewline]
    return parseFirstRecord(from: firstLine)
  }

  private static func parseFirstRecord(from lineData: Data) -> String? {
    let trimmed = lineData.drop(while: { byte in
      byte == 0x20 || byte == 0x09 || byte == 0x0D
    })
    guard !trimmed.isEmpty else { return nil }
    guard let record = try? JSONDecoder().decode(SubagentMetadataRecord.self, from: trimmed) else {
      return nil
    }
    return record.resolvedTitle
  }

  /// Scans subagents directory for a single known session.
  public static func scanSessionSubagents(
    sessionId: String,
    subagentsDir: String,
    projectName: String = "",
    directoryLister: any DirectoryLister,
    fileSystem: any TailFileSystem = LocalTailFileSystem(),
    now: Date
  ) -> [SessionSnapshot] {
    guard let entries = try? directoryLister.contentsOfDirectory(atPath: subagentsDir) else {
      return []
    }

    var snapshots: [SessionSnapshot] = []
    let parentKey = SessionKey(agent: .claudeCode, id: sessionId)

    for entry in entries {
      guard !entry.isDirectory, entry.path.hasSuffix(".jsonl") else {
        continue
      }

      let elapsed = now.timeIntervalSince(entry.modificationDate)
      // File must be modified within the last 15 minutes (with 60 s tolerance for future clock skew).
      guard elapsed <= mtimeCutoffInterval, elapsed >= -60 else {
        continue
      }

      let fileName = URL(fileURLWithPath: entry.path).lastPathComponent
      guard fileName.hasSuffix(".jsonl") else { continue }
      let subagentName = String(fileName.dropLast(".jsonl".count))
      guard !subagentName.isEmpty else { continue }

      let subagentId = "\(sessionId)/\(subagentName)"
      // Claude Code writes `<name>.meta.json` next to the transcript (agentType,
      // description, finished); prefer it over the transcript's first record.
      let metaPath = (subagentsDir as NSString).appendingPathComponent("\(subagentName).meta.json")
      let meta = readMetadata(from: metaPath, fileSystem: fileSystem)
      let state: SessionState
      if meta?.finished == true {
        state = .finished
      } else {
        state = (elapsed <= runningMtimeInterval) ? .running : .finished
      }
      let title = meta?.resolvedTitle ?? readTitle(from: entry.path, fileSystem: fileSystem)

      let snapshot = SessionSnapshot(
        id: subagentId,
        agent: .claudeCode,
        state: state,
        projectName: projectName,
        title: title,
        lastActivity: entry.modificationDate,
        waitingSince: nil,
        cwd: nil,
        parentKey: parentKey,
        childKind: .subagent
      )
      snapshots.append(snapshot)
    }

    return snapshots
  }

  /// Scans all known session subagents in a project directory.
  public static func scanProjectDirectory(
    projectDirPath: String,
    knownSessionIds: [String]? = nil,
    directoryLister: any DirectoryLister,
    fileSystem: any TailFileSystem = LocalTailFileSystem(),
    now: Date
  ) -> [SessionSnapshot] {
    let projectName = URL(fileURLWithPath: projectDirPath).lastPathComponent
    let candidateSessionIds: [String]

    if let knownSessionIds {
      candidateSessionIds = knownSessionIds
    } else {
      guard let entries = try? directoryLister.contentsOfDirectory(atPath: projectDirPath) else {
        return []
      }
      var discoveredSessionIds: [String] = []
      for entry in entries {
        if entry.isDirectory {
          discoveredSessionIds.append(entry.path)
        } else if entry.path.hasSuffix(".jsonl") {
          let fileName = URL(fileURLWithPath: entry.path).lastPathComponent
          let sessId = String(fileName.dropLast(".jsonl".count))
          discoveredSessionIds.append(sessId)
        }
      }
      candidateSessionIds = discoveredSessionIds
    }

    var allSnapshots: [SessionSnapshot] = []
    for sessId in candidateSessionIds {
      let subagentsDir = (projectDirPath as NSString)
        .appendingPathComponent(sessId)
        .appending("/subagents")
      let subagents = scanSessionSubagents(
        sessionId: sessId,
        subagentsDir: subagentsDir,
        projectName: projectName,
        directoryLister: directoryLister,
        fileSystem: fileSystem,
        now: now
      )
      allSnapshots.append(contentsOf: subagents)
    }

    return allSnapshots
  }

  /// Discovers all Claude subagents across project directories under projectsRoot.
  public static func scanProjects(
    projectsRoot: String,
    knownSessionIds: [String]? = nil,
    directoryLister: any DirectoryLister,
    fileSystem: any TailFileSystem = LocalTailFileSystem(),
    now: Date
  ) -> [SessionSnapshot] {
    let resolvedRoot = (projectsRoot as NSString).expandingTildeInPath
    guard let projectDirs = try? directoryLister.contentsOfDirectory(atPath: resolvedRoot) else {
      return []
    }

    var result: [SessionSnapshot] = []
    for projectDir in projectDirs where projectDir.isDirectory {
      let subagents = scanProjectDirectory(
        projectDirPath: projectDir.path,
        knownSessionIds: knownSessionIds,
        directoryLister: directoryLister,
        fileSystem: fileSystem,
        now: now
      )
      result.append(contentsOf: subagents)
    }
    return result
  }

  /// Reads a subagent's `.meta.json` (at most `maxReadBytes`); only metadata fields are decoded.
  private static func readMetadata(
    from path: String, fileSystem: any TailFileSystem
  ) -> SubagentMetadataRecord? {
    guard let file = try? fileSystem.openRegularFile(at: path) else { return nil }
    defer { file.close() }
    guard let snapshot = try? file.snapshot(), snapshot.size <= UInt64(maxReadBytes),
      snapshot.size > 0,
      let data = try? file.read(from: 0, count: Int(snapshot.size))
    else {
      return nil
    }
    return try? JSONDecoder().decode(SubagentMetadataRecord.self, from: data)
  }

  private static func readTitle(from path: String, fileSystem: any TailFileSystem) -> String? {
    guard let file = try? fileSystem.openRegularFile(at: path) else {
      return nil
    }
    defer { file.close() }

    guard let snapshot = try? file.snapshot() else {
      return nil
    }
    let readCount = min(Int(snapshot.size), maxReadBytes)
    guard readCount > 0, let data = try? file.read(from: 0, count: readCount) else {
      return nil
    }
    return parseMetadataTitle(from: data)
  }
}

// MARK: - Privacy-Preserving Metadata Schema

private struct SubagentMetadataRecord: Decodable {
  let agentType: String?
  let description: String?
  let subagentType: String?
  let metadata: SubagentNestedMetadata?
  /// Only present in `.meta.json`.
  let finished: Bool?

  enum CodingKeys: String, CodingKey {
    case agentType
    case description
    case subagentType = "subagent_type"
    case metadata
    case finished
  }

  init(
    agentType: String? = nil,
    description: String? = nil,
    subagentType: String? = nil,
    metadata: SubagentNestedMetadata? = nil,
    finished: Bool? = nil
  ) {
    self.agentType = agentType
    self.description = description
    self.subagentType = subagentType
    self.metadata = metadata
    self.finished = finished
  }

  var resolvedTitle: String? {
    if let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
      return String(desc.prefix(80))
    }
    if let type = agentType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
      return String(type.prefix(80))
    }
    if let subType = subagentType?.trimmingCharacters(in: .whitespacesAndNewlines), !subType.isEmpty
    {
      return String(subType.prefix(80))
    }
    if let nested = metadata {
      if let desc = nested.description?.trimmingCharacters(in: .whitespacesAndNewlines),
        !desc.isEmpty
      {
        return String(desc.prefix(80))
      }
      if let type = nested.agentType?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty
      {
        return String(type.prefix(80))
      }
      if let subType = nested.subagentType?.trimmingCharacters(in: .whitespacesAndNewlines),
        !subType.isEmpty
      {
        return String(subType.prefix(80))
      }
    }
    return nil
  }
}

private struct SubagentNestedMetadata: Decodable {
  let agentType: String?
  let description: String?
  let subagentType: String?

  enum CodingKeys: String, CodingKey {
    case agentType
    case description
    case subagentType = "subagent_type"
  }

  init(agentType: String? = nil, description: String? = nil, subagentType: String? = nil) {
    self.agentType = agentType
    self.description = description
    self.subagentType = subagentType
  }
}
