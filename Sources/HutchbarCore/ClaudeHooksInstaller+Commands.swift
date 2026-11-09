// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Recognising hutchbar's own hook commands and locating the binary and profiles.
extension ClaudeHooksInstaller {
  // MARK: - Path and Environment Helpers

  public static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  public static func currentExecutablePath() -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    var size = UInt32(buffer.count)
    if _NSGetExecutablePath(&buffer, &size) == 0 {
      var realBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      if Darwin.realpath(buffer, &realBuffer) != nil {
        let resolved = realBuffer.withUnsafeBufferPointer { pointer in
          pointer.baseAddress.map(String.init(cString:)) ?? ""
        }
        if !resolved.isEmpty { return resolved }
      }
      let fallback = buffer.withUnsafeBufferPointer { pointer in
        pointer.baseAddress.map(String.init(cString:)) ?? ""
      }
      if !fallback.isEmpty { return fallback }
    }
    if let bundlePath = Bundle.main.executablePath, !bundlePath.isEmpty {
      return bundlePath
    }
    let arg0 = CommandLine.arguments.first ?? "hutchbar"
    return URL(fileURLWithPath: arg0).standardized.path
  }

  public static func defaultSettingsDirectory(
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
  ) -> String {
    (homeDirectory as NSString).appendingPathComponent(".claude")
  }

  public static func discoveredProfileDirectories(
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    probe: ClaudeUsageProbe = ClaudeUsageProbe()
  ) -> [String] {
    let defaultDir = defaultSettingsDirectory(homeDirectory: homeDirectory)
    var results: [String] = [defaultDir]
    for profile in probe.profiles() {
      if !results.contains(profile.directoryPath) {
        results.append(profile.directoryPath)
      }
    }
    return results
  }

  // MARK: - Hook Parsing Helpers

  public static func extractHookBinaryPath(from command: String) -> String? {
    guard command.hasSuffix(hookSuffix) else { return nil }
    let rawPath = String(command.dropLast(hookSuffix.count))
      .trimmingCharacters(in: .whitespaces)
    guard !rawPath.isEmpty else { return nil }

    let unquoted: String
    if rawPath.hasPrefix("'") && rawPath.hasSuffix("'") && rawPath.count >= 2 {
      let inner = String(rawPath.dropFirst().dropLast())
      unquoted = inner.replacingOccurrences(of: "'\\''", with: "'")
    } else if rawPath.hasPrefix("\"") && rawPath.hasSuffix("\"") && rawPath.count >= 2 {
      let inner = String(rawPath.dropFirst().dropLast())
      unquoted = inner.replacingOccurrences(of: "\\\"", with: "\"")
    } else {
      unquoted = rawPath
    }

    let binaryName = URL(fileURLWithPath: unquoted).lastPathComponent
    guard binaryName == "hutchbar" else { return nil }
    return unquoted
  }

  public static func isOurHookCommand(_ command: String) -> Bool {
    extractHookBinaryPath(from: command) != nil
  }

  public static func matchesCurrentBinary(
    _ command: String,
    currentBinaryPath: String
  ) -> Bool {
    guard let extracted = extractHookBinaryPath(from: command) else { return false }
    if extracted == currentBinaryPath { return true }
    let standardExtracted = URL(fileURLWithPath: extracted).standardized.path
    let standardCurrent = URL(fileURLWithPath: currentBinaryPath).standardized.path
    return standardExtracted == standardCurrent
  }

  public static func isOurEntry(_ entry: [String: Any]) -> Bool {
    if let hooks = entry["hooks"] as? [[String: Any]] {
      return hooks.contains { hookDict in
        guard let command = hookDict["command"] as? String else { return false }
        return isOurHookCommand(command)
      }
    }
    if let command = entry["command"] as? String {
      return isOurHookCommand(command)
    }
    return false
  }

  public static func matchesCurrentBinary(
    entry: [String: Any],
    currentBinaryPath: String
  ) -> Bool {
    if let hooks = entry["hooks"] as? [[String: Any]] {
      return hooks.contains { hookDict in
        guard let command = hookDict["command"] as? String else { return false }
        return matchesCurrentBinary(command, currentBinaryPath: currentBinaryPath)
      }
    }
    if let command = entry["command"] as? String {
      return matchesCurrentBinary(command, currentBinaryPath: currentBinaryPath)
    }
    return false
  }

  // MARK: - Static Convenience Methods

  public static func status(at dir: String, binaryPath: String? = nil) -> HooksStatus {
    ClaudeHooksInstaller().status(at: dir, binaryPath: binaryPath)
  }

  public static func status(_ dir: String, binaryPath: String? = nil) -> HooksStatus {
    status(at: dir, binaryPath: binaryPath)
  }

  public static func install(
    at dir: String,
    binaryPath: String? = nil,
    now: Date = Date()
  ) throws -> InstallReport {
    try ClaudeHooksInstaller().install(at: dir, binaryPath: binaryPath, now: now)
  }

  public static func install(
    _ dir: String,
    binaryPath: String? = nil,
    now: Date = Date()
  ) throws -> InstallReport {
    try install(at: dir, binaryPath: binaryPath, now: now)
  }

  public static func uninstall(
    at dir: String,
    now: Date = Date()
  ) throws -> InstallReport {
    try ClaudeHooksInstaller().uninstall(at: dir, now: now)
  }

  public static func uninstall(
    _ dir: String,
    now: Date = Date()
  ) throws -> InstallReport {
    try uninstall(at: dir, now: now)
  }

  /// True when `hooks` is absent or an object whose hutchbar events are absent or arrays:
  /// anything else would be replaced on write, losing data that is not ours.
  public static func hasEditableHooksShape(_ json: [String: Any]) -> Bool {
    guard let hooks = json["hooks"] else { return true }
    guard let hooksDict = hooks as? [String: Any] else { return false }
    return requiredEvents.allSatisfy { event in
      hooksDict[event] == nil || hooksDict[event] is [Any]
    }
  }
}
