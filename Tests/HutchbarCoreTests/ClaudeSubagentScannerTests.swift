// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private struct MockSubagentDirectoryLister: DirectoryLister {
  let entriesByPath: [String: [FileMetadata]]

  init(entriesByPath: [String: [FileMetadata]] = [:]) {
    self.entriesByPath = entriesByPath
  }

  func contentsOfDirectory(atPath path: String) throws -> [FileMetadata] {
    entriesByPath[path] ?? []
  }
}

private final class MockSubagentTailFile: TailFile {
  let data: Data

  init(data: Data) {
    self.data = data
  }

  func snapshot() throws -> FileSnapshot {
    FileSnapshot(device: 1, inode: 1, size: UInt64(data.count))
  }

  func read(from offset: UInt64, count: Int) throws -> Data {
    let start = Int(offset)
    guard start < data.count else { return Data() }
    let end = min(start + count, data.count)
    return data.subdata(in: start..<end)
  }

  func close() {}
}

private struct MockSubagentFileSystem: TailFileSystem {
  let files: [String: Data]

  init(files: [String: Data] = [:]) {
    self.files = files
  }

  func openRegularFile(at path: String) throws -> any TailFile {
    guard let data = files[path] else {
      throw TailError.unavailable
    }
    return MockSubagentTailFile(data: data)
  }
}

@Test func claudeSubagentScanner_mtimeWithin2Min_marksRunning() throws {
  let baseDate = Date(timeIntervalSince1970: 1_794_000_000)
  let subagentsDir = "/home/.claude/projects/my-proj/sess-1/subagents"
  let subagentPath = "\(subagentsDir)/agent-a1.jsonl"
  let fileData = Data("{\"description\":\"Fast worker\"}\n".utf8)

  let lister = MockSubagentDirectoryLister(
    entriesByPath: [
      subagentsDir: [
        FileMetadata(path: subagentPath, modificationDate: baseDate.addingTimeInterval(-60))
      ]
    ]
  )
  let fileSystem = MockSubagentFileSystem(files: [subagentPath: fileData])

  let results = ClaudeSubagentScanner.scanSessionSubagents(
    sessionId: "sess-1",
    subagentsDir: subagentsDir,
    projectName: "my-proj",
    directoryLister: lister,
    fileSystem: fileSystem,
    now: baseDate
  )

  #expect(results.count == 1)
  let first = try #require(results.first)
  #expect(first.id == "sess-1/agent-a1")
  #expect(first.agent == .claudeCode)
  #expect(first.parentKey == SessionKey(agent: .claudeCode, id: "sess-1"))
  #expect(first.childKind == .subagent)
  #expect(first.state == .running)
  #expect(first.title == "Fast worker")
  #expect(first.projectName == "my-proj")
}

@Test func claudeSubagentScanner_mtimeBetween2And15Min_marksFinished() throws {
  let baseDate = Date(timeIntervalSince1970: 1_794_000_000)
  let subagentsDir = "/home/.claude/projects/my-proj/sess-1/subagents"
  let subagentPath = "\(subagentsDir)/agent-a2.jsonl"
  let fileData = Data("{\"agentType\":\"Deep Thinker\"}\n".utf8)

  let lister = MockSubagentDirectoryLister(
    entriesByPath: [
      subagentsDir: [
        FileMetadata(path: subagentPath, modificationDate: baseDate.addingTimeInterval(-300))
      ]
    ]
  )
  let fileSystem = MockSubagentFileSystem(files: [subagentPath: fileData])

  let results = ClaudeSubagentScanner.scanSessionSubagents(
    sessionId: "sess-1",
    subagentsDir: subagentsDir,
    projectName: "my-proj",
    directoryLister: lister,
    fileSystem: fileSystem,
    now: baseDate
  )

  #expect(results.count == 1)
  let first = try #require(results.first)
  #expect(first.id == "sess-1/agent-a2")
  #expect(first.state == .finished)
  #expect(first.title == "Deep Thinker")
}

@Test func claudeSubagentScanner_mtimeOlderThan15Min_isIgnored() throws {
  let baseDate = Date(timeIntervalSince1970: 1_794_000_000)
  let subagentsDir = "/home/.claude/projects/my-proj/sess-1/subagents"
  let subagentPath = "\(subagentsDir)/agent-old.jsonl"
  let fileData = Data("{\"description\":\"Old worker\"}\n".utf8)

  let lister = MockSubagentDirectoryLister(
    entriesByPath: [
      subagentsDir: [
        FileMetadata(path: subagentPath, modificationDate: baseDate.addingTimeInterval(-16 * 60))
      ]
    ]
  )
  let fileSystem = MockSubagentFileSystem(files: [subagentPath: fileData])

  let results = ClaudeSubagentScanner.scanSessionSubagents(
    sessionId: "sess-1",
    subagentsDir: subagentsDir,
    projectName: "my-proj",
    directoryLister: lister,
    fileSystem: fileSystem,
    now: baseDate
  )

  #expect(results.isEmpty)
}

@Test func claudeSubagentScanner_subagentTypeFallbackAndContentIgnored() throws {
  let jsonWithContent = """
    {"subagent_type":"analyzer","message":{"content":"SECRET_PASSWORD_123"},"prompt":"do work"}
    """
  let title = ClaudeSubagentScanner.parseMetadataTitle(from: Data(jsonWithContent.utf8))
  #expect(title == "analyzer")

  let titleEmpty = ClaudeSubagentScanner.parseMetadataTitle(
    from: Data("{\"message\":{\"content\":\"hello world\"}}\n".utf8)
  )
  #expect(titleEmpty == nil)
}

@Test func claudeSubagentScanner_nestedMetadataParsedProperly() throws {
  let json = "{\"metadata\":{\"description\":\"Nested Helper\"}}\n"
  let title = ClaudeSubagentScanner.parseMetadataTitle(from: Data(json.utf8))
  #expect(title == "Nested Helper")
}

@Test func claudeSubagentScanner_scanProjectsFullDiscovery() throws {
  let baseDate = Date(timeIntervalSince1970: 1_794_000_000)
  let root = "/home/.claude/projects"
  let projDir = "\(root)/demo-app"
  let sessDir = "\(projDir)/sess-root"
  let subDir = "\(sessDir)/subagents"
  let subPath = "\(subDir)/worker.jsonl"

  let lister = MockSubagentDirectoryLister(
    entriesByPath: [
      root: [FileMetadata(path: projDir, modificationDate: baseDate, isDirectory: true)],
      projDir: [
        FileMetadata(path: "\(projDir)/sess-root.jsonl", modificationDate: baseDate),
        FileMetadata(path: sessDir, modificationDate: baseDate, isDirectory: true),
      ],
      subDir: [FileMetadata(path: subPath, modificationDate: baseDate.addingTimeInterval(-30))],
    ]
  )
  let fileSystem = MockSubagentFileSystem(
    files: [subPath: Data("{\"agentType\":\"Worker Agent\"}\n".utf8)]
  )

  let results = ClaudeSubagentScanner.scanProjects(
    projectsRoot: root,
    knownSessionIds: ["sess-root"],
    directoryLister: lister,
    fileSystem: fileSystem,
    now: baseDate
  )

  #expect(results.count == 1)
  let subagent = try #require(results.first)
  #expect(subagent.id == "sess-root/worker")
  #expect(subagent.parentKey == SessionKey(agent: .claudeCode, id: "sess-root"))
  #expect(subagent.childKind == .subagent)
  #expect(subagent.state == .running)
  #expect(subagent.title == "Worker Agent")
}

@Test func claudeSubagentScanner_metaJsonGivesTitleAndFinished() throws {
  let baseDate = Date(timeIntervalSince1970: 1_794_000_000)
  let subagentsDir = "/home/.claude/projects/my-proj/sess-2/subagents"
  let transcript = "\(subagentsDir)/agent-b2.jsonl"
  let meta = "\(subagentsDir)/agent-b2.meta.json"
  let lister = MockSubagentDirectoryLister(
    entriesByPath: [
      subagentsDir: [
        FileMetadata(path: transcript, modificationDate: baseDate.addingTimeInterval(-30)),
        FileMetadata(path: meta, modificationDate: baseDate.addingTimeInterval(-30)),
      ]
    ]
  )
  let fileSystem = MockSubagentFileSystem(files: [
    transcript: Data("{\"type\":\"user\",\"message\":{\"content\":\"secret prompt\"}}\n".utf8),
    meta: Data(
      "{\"agentType\":\"web-fetch\",\"description\":\"Fetch pricing\",\"finished\":true}".utf8),
  ])

  let results = ClaudeSubagentScanner.scanSessionSubagents(
    sessionId: "sess-2", subagentsDir: subagentsDir, directoryLister: lister,
    fileSystem: fileSystem, now: baseDate)

  #expect(results.count == 1)
  let child = try #require(results.first)
  #expect(child.id == "sess-2/agent-b2")
  #expect(child.title == "Fetch pricing")
  // Recently modified, but the meta file says it finished.
  #expect(child.state == .finished)
}
