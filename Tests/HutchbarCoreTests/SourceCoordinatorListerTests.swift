// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func makeListerTempDir() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test func sourceCoordinator_defaultPollIntervalIsTwoSeconds() {
  let config = SourceCoordinator.Configuration()
  #expect(config.pollInterval == 2.0)
}

@Test func localDirectoryLister_discoversFilesAndDirectoriesAndSkipsSymlinksAndHiddenFiles()
  throws
{
  let tempDir = try makeListerTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let fm = FileManager.default
  let subDir = tempDir.appendingPathComponent("subdir")
  try fm.createDirectory(at: subDir, withIntermediateDirectories: true)

  let regularFile = tempDir.appendingPathComponent("file.jsonl")
  try Data("hello\n".utf8).write(to: regularFile)

  let hiddenFile = tempDir.appendingPathComponent(".hidden.jsonl")
  try Data("hidden\n".utf8).write(to: hiddenFile)

  let symlink = tempDir.appendingPathComponent("symlink.jsonl")
  try fm.createSymbolicLink(at: symlink, withDestinationURL: regularFile)

  let lister = LocalDirectoryLister()
  let results = try lister.contentsOfDirectory(atPath: tempDir.path)

  let names = Set(results.map { URL(fileURLWithPath: $0.path).lastPathComponent })
  #expect(names.contains("file.jsonl"))
  #expect(names.contains("subdir"))
  #expect(!names.contains(".hidden.jsonl"))
  #expect(!names.contains("symlink.jsonl"))

  let fileMeta = try #require(results.first { $0.path == regularFile.path })
  #expect(!fileMeta.isDirectory)
  #expect(fileMeta.modificationDate > Date.distantPast)

  let dirMeta = try #require(results.first { $0.path == subDir.path })
  #expect(dirMeta.isDirectory)
}
