// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

private struct FakeExecutableLocatorFileSystem: ExecutableLocatorFileSystem {
  let home: String
  let executableFiles: Set<String>
  let directoryContents: [String: [String]]

  init(
    home: String = "/Users/testuser",
    executableFiles: Set<String> = [],
    directoryContents: [String: [String]] = [:]
  ) {
    self.home = home
    self.executableFiles = executableFiles
    self.directoryContents = directoryContents
  }

  func isExecutableFile(atPath path: String) -> Bool {
    executableFiles.contains(path)
  }

  func contentsOfDirectory(atPath path: String) -> [String] {
    directoryContents[path] ?? []
  }

  func homeDirectory() -> String {
    home
  }
}

@Suite("ExecutableLocatorTests")
struct ExecutableLocatorTests {
  @Test func executableLocator_findsInLocalBinFirst() {
    let home = "/Users/testuser"
    let fileSystem = FakeExecutableLocatorFileSystem(
      home: home,
      executableFiles: [
        "\(home)/.local/bin/claude",
        "\(home)/.claude/local/claude",
        "/opt/homebrew/bin/claude",
      ]
    )
    let locator = ExecutableLocator(fileSystem: fileSystem)
    let found = locator.locate(.claudeCode)
    #expect(found == "\(home)/.local/bin/claude")
  }

  @Test func executableLocator_findsClaudeInClaudeLocal() {
    let home = "/Users/testuser"
    let fileSystem = FakeExecutableLocatorFileSystem(
      home: home,
      executableFiles: [
        "\(home)/.claude/local/claude",
        "/opt/homebrew/bin/claude",
      ]
    )
    let locator = ExecutableLocator(fileSystem: fileSystem)
    let found = locator.locate(.claudeCode)
    #expect(found == "\(home)/.claude/local/claude")
  }

  @Test func executableLocator_claudeLocalIgnoredForCodex() {
    let home = "/Users/testuser"
    let fileSystem = FakeExecutableLocatorFileSystem(
      home: home,
      executableFiles: [
        "\(home)/.claude/local/codex",
        "/opt/homebrew/bin/codex",
      ]
    )
    let locator = ExecutableLocator(fileSystem: fileSystem)
    let found = locator.locate(.codex)
    #expect(found == "/opt/homebrew/bin/codex")
  }

  @Test func executableLocator_findsInHomebrewBeforeUsrLocal() {
    let home = "/Users/testuser"
    let fileSystem = FakeExecutableLocatorFileSystem(
      home: home,
      executableFiles: [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
      ]
    )
    let locator = ExecutableLocator(fileSystem: fileSystem)
    let found = locator.locate(.codex)
    #expect(found == "/opt/homebrew/bin/codex")
  }

  @Test func executableLocator_versionSortingPrefersNewerNumericVersion() {
    #expect(ExecutableLocator.isVersion("v22.10.0", newerThan: "v22.9.1"))
    #expect(!ExecutableLocator.isVersion("v22.9.1", newerThan: "v22.10.0"))
    #expect(ExecutableLocator.isVersion("v20.0.0", newerThan: "v18.19.0"))
    #expect(ExecutableLocator.isVersion("v22.10.1", newerThan: "v22.10.0"))
  }

  @Test func executableLocator_findsInNvmNewestVersion() {
    let home = "/Users/testuser"
    let nvmNode = "\(home)/.nvm/versions/node"
    let fileSystem = FakeExecutableLocatorFileSystem(
      home: home,
      executableFiles: [
        "\(nvmNode)/v22.9.1/bin/claude",
        "\(nvmNode)/v22.10.0/bin/claude",
      ],
      directoryContents: [
        nvmNode: ["v22.9.1", "v22.10.0"]
      ]
    )
    let locator = ExecutableLocator(fileSystem: fileSystem)
    let found = locator.locate(.claudeCode)
    #expect(found == "\(nvmNode)/v22.10.0/bin/claude")
  }

  @Test func executableLocator_findsInFnmNewestVersion() {
    let home = "/Users/testuser"
    let fnmVersions = "\(home)/.local/share/fnm/node-versions"
    let fileSystem = FakeExecutableLocatorFileSystem(
      home: home,
      executableFiles: [
        "\(fnmVersions)/v20.5.0/installation/bin/claude",
        "\(fnmVersions)/v22.10.0/installation/bin/claude",
      ],
      directoryContents: [
        fnmVersions: ["v20.5.0", "v22.10.0"]
      ]
    )
    let locator = ExecutableLocator(fileSystem: fileSystem)
    let found = locator.locate(.claudeCode)
    #expect(found == "\(fnmVersions)/v22.10.0/installation/bin/claude")
  }

  @Test func executableLocator_findsInAsdfAndMise() {
    let home = "/Users/testuser"
    let asdfNode = "\(home)/.asdf/installs/nodejs"
    let miseNode = "\(home)/.local/share/mise/installs/node"
    let fileSystem = FakeExecutableLocatorFileSystem(
      home: home,
      executableFiles: [
        "\(miseNode)/v22.0.0/bin/codex"
      ],
      directoryContents: [
        asdfNode: [],
        miseNode: ["v22.0.0"],
      ]
    )
    let locator = ExecutableLocator(fileSystem: fileSystem)
    let found = locator.locate(.codex)
    #expect(found == "\(miseNode)/v22.0.0/bin/codex")
  }

  @Test func executableLocator_findsInVoltaBunPnpmAndNpmGlobal() {
    let home = "/Users/testuser"
    let fileSystem = FakeExecutableLocatorFileSystem(
      home: home,
      executableFiles: [
        "\(home)/.npm-global/bin/claude"
      ]
    )
    let locator = ExecutableLocator(fileSystem: fileSystem)
    let found = locator.locate(.claudeCode)
    #expect(found == "\(home)/.npm-global/bin/claude")
  }

  @Test func executableLocator_returnsNilWhenMissing() {
    let fileSystem = FakeExecutableLocatorFileSystem()
    let locator = ExecutableLocator(fileSystem: fileSystem)
    #expect(locator.locate(.claudeCode) == nil)
    #expect(locator.locate(.codex) == nil)
  }
}
