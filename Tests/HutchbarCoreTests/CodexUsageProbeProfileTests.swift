// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

@Test func codexUsageProbe_profilesDiscoveryAndPermissions() {
  let fs = CodexProbeFakeFileSystem(home: "/Users/testuser", uid: 501)
  fs.registerDirectory(path: "/Users/testuser/.codex", ownerUID: 501, posixMode: 0o700)
  fs.registerDirectory(path: "/Users/testuser/.codex-valid1", ownerUID: 501, posixMode: 0o755)
  fs.registerDirectory(path: "/Users/testuser/.codex-valid2", ownerUID: 501, posixMode: 0o700)
  fs.registerDirectory(
    path: "/Users/testuser/.codex-group-writable",
    ownerUID: 501,
    posixMode: 0o775
  )
  fs.registerDirectory(
    path: "/Users/testuser/.codex-world-writable",
    ownerUID: 501,
    posixMode: 0o757
  )
  fs.registerDirectory(path: "/Users/testuser/.codex-wrong-uid", ownerUID: 999, posixMode: 0o700)
  fs.registerDirectory(
    path: "/Users/testuser/.codex-no-auth",
    ownerUID: 501,
    posixMode: 0o700,
    hasAuthJson: false
  )

  var extraEntries: [String] = []
  for index in 1...10 {
    let name = String(format: ".codex-batch%02d", index)
    let path = "/Users/testuser/\(name)"
    fs.registerDirectory(path: path, ownerUID: 501, posixMode: 0o700)
    extraEntries.append(name)
  }

  var allEntries = [
    ".codex",
    ".codex-valid1",
    ".codex-valid2",
    ".codex-group-writable",
    ".codex-world-writable",
    ".codex-wrong-uid",
    ".codex-no-auth",
    "other-file",
  ]
  allEntries.append(contentsOf: extraEntries)
  fs.setContentsOfDirectory(path: "/Users/testuser", entries: allEntries)

  let probe = CodexUsageProbe(
    executable: "codex",
    runner: FakeAgentProcessRunner(replies: []),
    fileSystem: fs
  )
  let profiles = probe.profiles()

  let defaultProfiles = profiles.filter { $0.isDefault }
  #expect(defaultProfiles.count == 1)
  #expect(defaultProfiles.first?.path == "/Users/testuser/.codex")

  let customProfiles = profiles.filter { !$0.isDefault }
  #expect(customProfiles.count == 8)
  for profile in customProfiles {
    #expect(!profile.path.contains("group-writable"))
    #expect(!profile.path.contains("world-writable"))
    #expect(!profile.path.contains("wrong-uid"))
    #expect(!profile.path.contains("no-auth"))
  }
}

@Test func codexUsageProbe_accountNameFallbackAndPrivacy() async throws {
  let repliesNoAt: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [
        "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\",\"email\":\"noatsign\"}}}"
      ]
    ),
    .init(
      whenSentContains: "account/rateLimits/read",
      lines: [CodexUsageProbeSyntheticFixtures.rateLimitsPrimaryOnlyResponse]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: repliesNoAt)
  let probe = CodexUsageProbe(executable: "codex", runner: runner)
  let profile = CodexProfile(path: "/Users/testuser/.codex-work", isDefault: false)

  let result = await probe.read(profile, now: Date())
  let quota = try #require(try? result.get())
  #expect(quota.accountName == ".codex-work")
  #expect(!String(describing: quota).contains("noatsign"))
}
