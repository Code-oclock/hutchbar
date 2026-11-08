// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Abstraction over the filesystem for locating executables and testing resolution.
public protocol ExecutableLocatorFileSystem: Sendable {
  func isExecutableFile(atPath path: String) -> Bool
  func contentsOfDirectory(atPath path: String) -> [String]
  func homeDirectory() -> String
}

public struct DefaultExecutableLocatorFileSystem: ExecutableLocatorFileSystem {
  public init() {}

  public func isExecutableFile(atPath path: String) -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
      return false
    }
    return FileManager.default.isExecutableFile(atPath: path)
  }

  public func contentsOfDirectory(atPath path: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
  }

  public func homeDirectory() -> String {
    FileManager.default.homeDirectoryForCurrentUser.path
  }
}

/// Locates agent executables without requiring a login shell (docs/specs/limits-v3.md, section 2).
public struct ExecutableLocator: Sendable {
  private let fileSystem: any ExecutableLocatorFileSystem

  public init(fileSystem: any ExecutableLocatorFileSystem = DefaultExecutableLocatorFileSystem()) {
    self.fileSystem = fileSystem
  }

  public static func locate(_ agent: AgentKind) -> String? {
    ExecutableLocator().locate(agent)
  }

  public static func locate(executable name: String) -> String? {
    ExecutableLocator().locate(executable: name)
  }

  public func locate(_ agent: AgentKind) -> String? {
    switch agent {
    case .claudeCode:
      return locate(executable: "claude")
    case .codex:
      return locate(executable: "codex")
    }
  }

  public func locate(executable name: String) -> String? {
    for candidate in candidatePaths(for: name) {
      if fileSystem.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  public static func parseVersionComponents(_ string: String) -> [Int] {
    var clean = string
    if clean.hasPrefix("v") || clean.hasPrefix("V") {
      clean.removeFirst()
    }
    return clean.split(separator: ".").compactMap { Int($0) }
  }

  public static func isVersion(_ first: String, newerThan second: String) -> Bool {
    let comp1 = parseVersionComponents(first)
    let comp2 = parseVersionComponents(second)
    if comp1.isEmpty && comp2.isEmpty { return first > second }
    if comp1.isEmpty { return false }
    if comp2.isEmpty { return true }
    for (val1, val2) in zip(comp1, comp2) {
      if val1 != val2 {
        return val1 > val2
      }
    }
    return comp1.count > comp2.count
  }

  private func sortedVersions(in directory: String) -> [String] {
    let entries = fileSystem.contentsOfDirectory(atPath: directory)
    return entries.sorted { Self.isVersion($0, newerThan: $1) }
  }

  private func candidatePaths(for name: String) -> [String] {
    let home = fileSystem.homeDirectory()
    var candidates: [String] = []

    candidates.append("\(home)/.local/bin/\(name)")

    if name == "claude" {
      candidates.append("\(home)/.claude/local/\(name)")
    }

    candidates.append("/opt/homebrew/bin/\(name)")
    candidates.append("/usr/local/bin/\(name)")

    appendFnmCandidates(home: home, name: name, into: &candidates)
    appendNvmCandidates(home: home, name: name, into: &candidates)
    appendAsdfCandidates(home: home, name: name, into: &candidates)
    appendMiseCandidates(home: home, name: name, into: &candidates)
    appendVoltaCandidates(home: home, name: name, into: &candidates)

    candidates.append("\(home)/.bun/bin/\(name)")
    candidates.append("\(home)/Library/pnpm/\(name)")
    candidates.append("\(home)/.local/share/pnpm/\(name)")
    candidates.append("\(home)/.npm-global/bin/\(name)")

    return candidates
  }

  private func appendFnmCandidates(home: String, name: String, into list: inout [String]) {
    for base in ["\(home)/.local/share/fnm/node-versions", "\(home)/.fnm/node-versions"] {
      for version in sortedVersions(in: base) {
        list.append("\(base)/\(version)/installation/bin/\(name)")
        list.append("\(base)/\(version)/bin/\(name)")
      }
    }
  }

  private func appendNvmCandidates(home: String, name: String, into list: inout [String]) {
    let base = "\(home)/.nvm/versions/node"
    for version in sortedVersions(in: base) {
      list.append("\(base)/\(version)/bin/\(name)")
    }
  }

  private func appendAsdfCandidates(home: String, name: String, into list: inout [String]) {
    let base = "\(home)/.asdf/installs/nodejs"
    for version in sortedVersions(in: base) {
      list.append("\(base)/\(version)/bin/\(name)")
    }
  }

  private func appendMiseCandidates(home: String, name: String, into list: inout [String]) {
    for base in [
      "\(home)/.local/share/mise/installs/node",
      "\(home)/.local/share/mise/installs/nodejs",
    ] {
      for version in sortedVersions(in: base) {
        list.append("\(base)/\(version)/bin/\(name)")
      }
    }
  }

  private func appendVoltaCandidates(home: String, name: String, into list: inout [String]) {
    list.append("\(home)/.volta/bin/\(name)")
    let base = "\(home)/.volta/tools/image/node"
    for version in sortedVersions(in: base) {
      list.append("\(base)/\(version)/bin/\(name)")
    }
  }
}
