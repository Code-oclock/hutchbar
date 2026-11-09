// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import MachO

/// Status of Claude Code hooks in a settings directory.
public enum HooksStatus: String, Sendable, Equatable {
  case notInstalled
  case installed
  case stale
  case unreadable
}

/// Summary report returned after installing or uninstalling hooks.
public struct InstallReport: Sendable, Equatable {
  public let filePath: String
  public let backupPath: String?
  public let updatedEvents: [String]

  public init(filePath: String, backupPath: String?, updatedEvents: [String]) {
    self.filePath = filePath
    self.backupPath = backupPath
    self.updatedEvents = updatedEvents
  }
}

/// Errors thrown during hooks installation or uninstallation.
/// Holds only the target file path and never exposes settings contents or tokens.
public enum ClaudeHooksError: Error, Sendable, Equatable, CustomStringConvertible {
  case cannotRead(path: String)
  case invalidJSON(path: String)
  case cannotCreateBackup(path: String)
  case cannotWrite(path: String)
  case cannotCreateDirectory(path: String)

  public var description: String {
    switch self {
    case .cannotRead(let path):
      return "Cannot read settings file at \(path)"
    case .invalidJSON(let path):
      return "Settings file at \(path) is not a valid JSON object"
    case .cannotCreateBackup(let path):
      return "Cannot create backup at \(path)"
    case .cannotWrite(let path):
      return "Cannot write settings file at \(path)"
    case .cannotCreateDirectory(let path):
      return "Cannot create directory at \(path)"
    }
  }
}

/// Inspects, installs, and uninstalls Hutchbar hooks in Claude Code configuration.
public struct ClaudeHooksInstaller: Sendable {
  public static let hookSuffix = " --hook"
  public static let notificationMatcher = "permission_prompt|idle_prompt"
  public static let requiredEvents = [
    "Notification",
    "Stop",
    "UserPromptSubmit",
    "SessionEnd",
  ]

  public let fileSystem: any ClaudeHooksFileSystem
  public let defaultBinaryPath: String

  public init(
    fileSystem: any ClaudeHooksFileSystem = DefaultClaudeHooksFileSystem(),
    defaultBinaryPath: String = ClaudeHooksInstaller.currentExecutablePath()
  ) {
    self.fileSystem = fileSystem
    self.defaultBinaryPath = defaultBinaryPath
  }

  // MARK: - Status

  public func status(at directoryPath: String, binaryPath: String? = nil) -> HooksStatus {
    let settingsPath = (directoryPath as NSString).appendingPathComponent("settings.json")
    guard fileSystem.fileExists(atPath: settingsPath) else {
      return .notInstalled
    }
    guard let data = try? fileSystem.readFile(atPath: settingsPath),
      let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    else {
      return .unreadable
    }

    if json["hooks"] != nil, !(json["hooks"] is [String: Any]) {
      return .unreadable
    }
    guard let hooksDict = json["hooks"] as? [String: Any] else {
      return .notInstalled
    }

    let activeBinary = binaryPath ?? defaultBinaryPath
    var hasAnyOurRecord = false
    for (_, eventValue) in hooksDict {
      if let entries = eventValue as? [[String: Any]],
        entries.contains(where: { Self.isOurEntry($0) })
      {
        hasAnyOurRecord = true
        break
      }
    }

    let allRequiredInstalled = checkAllRequiredEvents(
      hooksDict: hooksDict,
      activeBinary: activeBinary
    )
    if allRequiredInstalled {
      return .installed
    }
    return hasAnyOurRecord ? .stale : .notInstalled
  }

  private func checkAllRequiredEvents(
    hooksDict: [String: Any],
    activeBinary: String
  ) -> Bool {
    for eventName in Self.requiredEvents {
      guard let entries = hooksDict[eventName] as? [[String: Any]] else {
        return false
      }
      let matchingEntry = entries.first { entry in
        guard Self.isOurEntry(entry),
          Self.matchesCurrentBinary(entry: entry, currentBinaryPath: activeBinary)
        else {
          return false
        }
        if eventName == "Notification" {
          return (entry["matcher"] as? String) == Self.notificationMatcher
        }
        return true
      }
      if matchingEntry == nil {
        return false
      }
    }
    return true
  }

  // MARK: - Install

  public func install(
    at directoryPath: String,
    binaryPath: String? = nil,
    now: Date = Date()
  ) throws -> InstallReport {
    let activeBinary = binaryPath ?? defaultBinaryPath
    let settingsPath = (directoryPath as NSString).appendingPathComponent("settings.json")

    if !fileSystem.fileExists(atPath: directoryPath) {
      try fileSystem.createDirectory(atPath: directoryPath, mode: 0o700)
    }

    var json: [String: Any] = [:]
    var backupPath: String?
    let targetPermissions: mode_t

    if fileSystem.fileExists(atPath: settingsPath) {
      guard let data = try? fileSystem.readFile(atPath: settingsPath) else {
        throw ClaudeHooksError.cannotRead(path: settingsPath)
      }
      guard
        let parsed = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
      else {
        throw ClaudeHooksError.invalidJSON(path: settingsPath)
      }
      // Refuse a shape we would have to overwrite: other tools' data must survive.
      guard Self.hasEditableHooksShape(parsed) else {
        throw ClaudeHooksError.invalidJSON(path: settingsPath)
      }
      json = parsed
      targetPermissions = fileSystem.permissions(atPath: settingsPath) ?? 0o600
      backupPath = try makeBackup(
        settingsPath: settingsPath, directoryPath: directoryPath, now: now)
    } else {
      targetPermissions = 0o600
    }

    var hooksDict = (json["hooks"] as? [String: Any]) ?? [:]
    let hookCommand = "\(Self.shellQuoted(activeBinary))\(Self.hookSuffix)"

    for eventName in Self.requiredEvents {
      var entries = (hooksDict[eventName] as? [[String: Any]]) ?? []
      entries.removeAll(where: { Self.isOurEntry($0) })
      var newEntry: [String: Any] = [
        "hooks": [
          ["type": "command", "command": hookCommand]
        ]
      ]
      if eventName == "Notification" {
        newEntry["matcher"] = Self.notificationMatcher
      }
      entries.append(newEntry)
      hooksDict[eventName] = entries
    }
    json["hooks"] = hooksDict

    try writeSettingsAtomically(
      json: json,
      settingsPath: settingsPath,
      directoryPath: directoryPath,
      permissions: targetPermissions
    )

    return InstallReport(
      filePath: settingsPath,
      backupPath: backupPath,
      updatedEvents: Self.requiredEvents
    )
  }

  // MARK: - Uninstall

  public func uninstall(
    at directoryPath: String,
    now: Date = Date()
  ) throws -> InstallReport {
    let settingsPath = (directoryPath as NSString).appendingPathComponent("settings.json")
    guard fileSystem.fileExists(atPath: settingsPath) else {
      return InstallReport(filePath: settingsPath, backupPath: nil, updatedEvents: [])
    }

    guard let data = try? fileSystem.readFile(atPath: settingsPath) else {
      throw ClaudeHooksError.cannotRead(path: settingsPath)
    }
    guard var json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    else {
      throw ClaudeHooksError.invalidJSON(path: settingsPath)
    }
    guard var hooksDict = json["hooks"] as? [String: Any] else {
      return InstallReport(filePath: settingsPath, backupPath: nil, updatedEvents: [])
    }

    var hasOurRecords = false
    for (_, eventValue) in hooksDict {
      if let entries = eventValue as? [[String: Any]],
        entries.contains(where: { Self.isOurEntry($0) })
      {
        hasOurRecords = true
        break
      }
    }
    guard hasOurRecords else {
      return InstallReport(filePath: settingsPath, backupPath: nil, updatedEvents: [])
    }

    let originalPermissions = fileSystem.permissions(atPath: settingsPath) ?? 0o600
    let backupPath = try makeBackup(
      settingsPath: settingsPath,
      directoryPath: directoryPath,
      now: now
    )

    var updatedEvents: [String] = []
    for (eventName, eventValue) in hooksDict {
      guard var entries = eventValue as? [[String: Any]] else { continue }
      let initialCount = entries.count
      entries.removeAll(where: { Self.isOurEntry($0) })
      if entries.count != initialCount {
        updatedEvents.append(eventName)
      }
      if entries.isEmpty {
        hooksDict.removeValue(forKey: eventName)
      } else {
        hooksDict[eventName] = entries
      }
    }

    if hooksDict.isEmpty {
      json.removeValue(forKey: "hooks")
    } else {
      json["hooks"] = hooksDict
    }

    try writeSettingsAtomically(
      json: json,
      settingsPath: settingsPath,
      directoryPath: directoryPath,
      permissions: originalPermissions
    )

    return InstallReport(
      filePath: settingsPath,
      backupPath: backupPath,
      updatedEvents: updatedEvents.sorted()
    )
  }

  // MARK: - Internal Storage Operations

  private func makeBackup(
    settingsPath: String,
    directoryPath: String,
    now: Date
  ) throws -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    let timestamp = formatter.string(from: now)

    var backupName = "settings.json.hutchbar-backup-\(timestamp)"
    var destination = (directoryPath as NSString).appendingPathComponent(backupName)
    if fileSystem.fileExists(atPath: destination) {
      var counter = 1
      while fileSystem.fileExists(atPath: destination) {
        backupName = "settings.json.hutchbar-backup-\(timestamp)-\(counter)"
        destination = (directoryPath as NSString).appendingPathComponent(backupName)
        counter += 1
      }
    }

    do {
      try fileSystem.copyFile(fromPath: settingsPath, toPath: destination)
      if let permissions = fileSystem.permissions(atPath: settingsPath) {
        try? fileSystem.setPermissions(atPath: destination, mode: permissions)
      }
      return destination
    } catch {
      throw ClaudeHooksError.cannotCreateBackup(path: destination)
    }
  }

  private func writeSettingsAtomically(
    json: [String: Any],
    settingsPath: String,
    directoryPath: String,
    permissions: mode_t
  ) throws {
    let serialized: Data
    do {
      serialized = try JSONSerialization.data(
        withJSONObject: json,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw ClaudeHooksError.cannotWrite(path: settingsPath)
    }

    var payload = serialized
    if payload.last != 0x0A {
      payload.append(0x0A)
    }

    let tempName = "settings.json.tmp.\(UUID().uuidString)"
    let tempPath = (directoryPath as NSString).appendingPathComponent(tempName)

    do {
      try fileSystem.writeFile(atPath: tempPath, data: payload, mode: permissions)
      try fileSystem.rename(fromPath: tempPath, toPath: settingsPath)
      try? fileSystem.setPermissions(atPath: settingsPath, mode: permissions)
    } catch {
      try? fileSystem.removeItem(atPath: tempPath)
      throw ClaudeHooksError.cannotWrite(path: settingsPath)
    }
  }
}
