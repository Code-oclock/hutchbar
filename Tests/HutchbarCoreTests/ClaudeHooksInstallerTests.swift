// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import HutchbarCore
import Testing

private let hooksInstallerFixedDate = Date(timeIntervalSince1970: 1_794_081_600)

private func hooksInstallerMakeTempDirectory() throws -> URL {
  let fileManager = FileManager.default
  let uniqueName = "hutchbar-test-\(UUID().uuidString)"
  let tempDir = fileManager.temporaryDirectory.appendingPathComponent(uniqueName)
  try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
  return tempDir
}

private func hooksInstallerRemoveDirectory(_ directory: URL) {
  try? FileManager.default.removeItem(at: directory)
}

private func hooksInstallerWriteFile(
  at fileURL: URL,
  content: String,
  mode: mode_t? = nil
) throws {
  let data = Data(content.utf8)
  try data.write(to: fileURL)
  if let mode {
    _ = Darwin.chmod(fileURL.path, mode)
  }
}

private func hooksInstallerReadJSON(at fileURL: URL) throws -> [String: Any] {
  let data = try Data(contentsOf: fileURL)
  guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
  else {
    throw ClaudeHooksError.invalidJSON(path: fileURL.path)
  }
  return json
}

private func hooksInstallerFileMode(at path: String) -> mode_t? {
  var fileStat = stat()
  guard stat(path, &fileStat) == 0 else { return nil }
  return mode_t(fileStat.st_mode & 0o777)
}

@Test func hooksInstallerEmptyDirectoryInstall() throws {
  let tempDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(tempDir) }

  let binaryPath = "/Applications/Hutchbar.app/Contents/MacOS/hutchbar"
  let initialStatus = ClaudeHooksInstaller.status(at: tempDir.path, binaryPath: binaryPath)
  #expect(initialStatus == .notInstalled)

  let report = try ClaudeHooksInstaller.install(
    at: tempDir.path,
    binaryPath: binaryPath,
    now: hooksInstallerFixedDate
  )
  #expect(report.backupPath == nil)
  #expect(report.updatedEvents == ClaudeHooksInstaller.requiredEvents)

  let finalStatus = ClaudeHooksInstaller.status(at: tempDir.path, binaryPath: binaryPath)
  #expect(finalStatus == .installed)

  let settingsURL = tempDir.appendingPathComponent("settings.json")
  let json = try hooksInstallerReadJSON(at: settingsURL)
  let hooks = try #require(json["hooks"] as? [String: Any])

  let notifEntries = try #require(hooks["Notification"] as? [[String: Any]])
  #expect(notifEntries.count == 1)
  #expect(notifEntries[0]["matcher"] as? String == "permission_prompt|idle_prompt")
  let notifHooks = try #require(notifEntries[0]["hooks"] as? [[String: Any]])
  #expect(notifHooks[0]["command"] as? String == "'\(binaryPath)' --hook")

  for eventName in ["Stop", "UserPromptSubmit", "SessionEnd"] {
    let entries = try #require(hooks[eventName] as? [[String: Any]])
    #expect(entries.count == 1)
    let commandList = try #require(entries[0]["hooks"] as? [[String: Any]])
    #expect(commandList[0]["command"] as? String == "'\(binaryPath)' --hook")
  }
}

@Test func hooksInstallerPreservesForeignKeysAndHooks() throws {
  let tempDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(tempDir) }

  let initialJSON = """
    {
      "env": { "CUSTOM_KEY": "custom_val" },
      "hooks": {
        "Notification": [
          {
            "matcher": "other_matcher",
            "hooks": [{ "type": "command", "command": "other_tool --hook" }]
          }
        ],
        "PreToolUse": [
          {
            "hooks": [{ "type": "command", "command": "my_linter" }]
          }
        ]
      }
    }
    """
  let settingsURL = tempDir.appendingPathComponent("settings.json")
  try hooksInstallerWriteFile(at: settingsURL, content: initialJSON)

  let binaryPath = "/usr/local/bin/hutchbar"
  let initialStatus = ClaudeHooksInstaller.status(at: tempDir.path, binaryPath: binaryPath)
  #expect(initialStatus == .notInstalled)

  _ = try ClaudeHooksInstaller.install(
    at: tempDir.path,
    binaryPath: binaryPath,
    now: hooksInstallerFixedDate
  )

  let updatedJSON = try hooksInstallerReadJSON(at: settingsURL)
  let envDict = try #require(updatedJSON["env"] as? [String: String])
  #expect(envDict["CUSTOM_KEY"] == "custom_val")

  let hooks = try #require(updatedJSON["hooks"] as? [String: Any])
  let preToolEntries = try #require(hooks["PreToolUse"] as? [[String: Any]])
  #expect(preToolEntries.count == 1)

  let notifEntries = try #require(hooks["Notification"] as? [[String: Any]])
  #expect(notifEntries.count == 2)
  #expect(notifEntries.contains { ($0["matcher"] as? String) == "other_matcher" })
  #expect(
    notifEntries.contains {
      ($0["matcher"] as? String) == "permission_prompt|idle_prompt"
    }
  )

  let status = ClaudeHooksInstaller.status(at: tempDir.path, binaryPath: binaryPath)
  #expect(status == .installed)
}

@Test func hooksInstallerRepeatInstallDoesNotDuplicate() throws {
  let tempDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(tempDir) }

  let binaryPath = "/usr/local/bin/hutchbar"
  _ = try ClaudeHooksInstaller.install(
    at: tempDir.path,
    binaryPath: binaryPath,
    now: hooksInstallerFixedDate
  )
  _ = try ClaudeHooksInstaller.install(
    at: tempDir.path,
    binaryPath: binaryPath,
    now: hooksInstallerFixedDate.addingTimeInterval(10)
  )

  let settingsURL = tempDir.appendingPathComponent("settings.json")
  let json = try hooksInstallerReadJSON(at: settingsURL)
  let hooks = try #require(json["hooks"] as? [String: Any])

  for eventName in ClaudeHooksInstaller.requiredEvents {
    let entries = try #require(hooks[eventName] as? [[String: Any]])
    #expect(entries.count == 1)
  }
  let status = ClaudeHooksInstaller.status(at: tempDir.path, binaryPath: binaryPath)
  #expect(status == .installed)
}

@Test func hooksInstallerBinaryRelocationReplacesPath() throws {
  let tempDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(tempDir) }

  let oldBinary = "/opt/old/hutchbar"
  let newBinary = "/opt/new/hutchbar"

  _ = try ClaudeHooksInstaller.install(
    at: tempDir.path,
    binaryPath: oldBinary,
    now: hooksInstallerFixedDate
  )

  let staleStatus = ClaudeHooksInstaller.status(at: tempDir.path, binaryPath: newBinary)
  #expect(staleStatus == .stale)

  _ = try ClaudeHooksInstaller.install(
    at: tempDir.path,
    binaryPath: newBinary,
    now: hooksInstallerFixedDate.addingTimeInterval(5)
  )

  let refreshedStatus = ClaudeHooksInstaller.status(at: tempDir.path, binaryPath: newBinary)
  #expect(refreshedStatus == .installed)

  let settingsURL = tempDir.appendingPathComponent("settings.json")
  let content = try String(contentsOf: settingsURL, encoding: .utf8)
  #expect(content.contains(newBinary))
  #expect(!content.contains(oldBinary))
}

@Test func hooksInstallerUninstallLeavesForeignAndCleansEmpty() throws {
  let tempDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(tempDir) }

  let initialJSON = """
    {
      "env": { "PORT": "8080" },
      "hooks": {
        "PreToolUse": [
          { "hooks": [{ "type": "command", "command": "foreign-tool" }] }
        ],
        "Stop": [
          { "hooks": [{ "type": "command", "command": "'/bin/hutchbar' --hook" }] }
        ]
      }
    }
    """
  let settingsURL = tempDir.appendingPathComponent("settings.json")
  try hooksInstallerWriteFile(at: settingsURL, content: initialJSON)

  let report = try ClaudeHooksInstaller.uninstall(
    at: tempDir.path,
    now: hooksInstallerFixedDate
  )
  #expect(report.backupPath != nil)
  #expect(report.updatedEvents == ["Stop"])

  let afterUninstall = try hooksInstallerReadJSON(at: settingsURL)
  let envDict = try #require(afterUninstall["env"] as? [String: String])
  #expect(envDict["PORT"] == "8080")

  let hooks = try #require(afterUninstall["hooks"] as? [String: Any])
  #expect(hooks["PreToolUse"] != nil)
  #expect(hooks["Stop"] == nil)

  let secondReport = try ClaudeHooksInstaller.uninstall(
    at: tempDir.path,
    now: hooksInstallerFixedDate.addingTimeInterval(10)
  )
  #expect(secondReport.backupPath == nil)
  #expect(secondReport.updatedEvents.isEmpty)

  let onlyHutchbarDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(onlyHutchbarDir) }
  _ = try ClaudeHooksInstaller.install(
    at: onlyHutchbarDir.path,
    binaryPath: "/bin/hutchbar",
    now: hooksInstallerFixedDate
  )
  _ = try ClaudeHooksInstaller.uninstall(
    at: onlyHutchbarDir.path,
    now: hooksInstallerFixedDate.addingTimeInterval(5)
  )

  let cleanedURL = onlyHutchbarDir.appendingPathComponent("settings.json")
  let cleanedJSON = try hooksInstallerReadJSON(at: cleanedURL)
  #expect(cleanedJSON["hooks"] == nil)
}

@Test func hooksInstallerCorruptJSONFailsWithoutModifyingFile() throws {
  let tempDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(tempDir) }

  let corruptText = "{ this is not valid JSON }"
  let settingsURL = tempDir.appendingPathComponent("settings.json")
  try hooksInstallerWriteFile(at: settingsURL, content: corruptText)

  let status = ClaudeHooksInstaller.status(at: tempDir.path, binaryPath: "/bin/hutchbar")
  #expect(status == .unreadable)

  #expect(throws: ClaudeHooksError.self) {
    try ClaudeHooksInstaller.install(
      at: tempDir.path,
      binaryPath: "/bin/hutchbar",
      now: hooksInstallerFixedDate
    )
  }

  let fileContentAfter = try String(contentsOf: settingsURL, encoding: .utf8)
  #expect(fileContentAfter == corruptText)

  let nonObjectJSON = "[1, 2, 3]"
  try hooksInstallerWriteFile(at: settingsURL, content: nonObjectJSON)
  #expect(throws: ClaudeHooksError.self) {
    try ClaudeHooksInstaller.install(
      at: tempDir.path,
      binaryPath: "/bin/hutchbar",
      now: hooksInstallerFixedDate
    )
  }
}

@Test func hooksInstallerBackupCreatedAndMatchesOriginal() throws {
  let tempDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(tempDir) }

  let originalContent = "{\n  \"existingKey\": true\n}\n"
  let settingsURL = tempDir.appendingPathComponent("settings.json")
  try hooksInstallerWriteFile(at: settingsURL, content: originalContent, mode: 0o644)

  let report = try ClaudeHooksInstaller.install(
    at: tempDir.path,
    binaryPath: "/bin/hutchbar",
    now: hooksInstallerFixedDate
  )

  let backupPath = try #require(report.backupPath)
  let backupData = try Data(contentsOf: URL(fileURLWithPath: backupPath))
  #expect(backupData == Data(originalContent.utf8))

  let backupMode = hooksInstallerFileMode(at: backupPath)
  #expect(backupMode == 0o644)
}

@Test func hooksInstallerNewFileHasMode0600AndDir0700() throws {
  let tempDir = try hooksInstallerMakeTempDirectory()
  defer { hooksInstallerRemoveDirectory(tempDir) }

  let targetDir = tempDir.appendingPathComponent("brand_new_claude")
  #expect(!FileManager.default.fileExists(atPath: targetDir.path))

  _ = try ClaudeHooksInstaller.install(
    at: targetDir.path,
    binaryPath: "/bin/hutchbar",
    now: hooksInstallerFixedDate
  )

  let dirMode = hooksInstallerFileMode(at: targetDir.path)
  #expect(dirMode == 0o700)

  let settingsPath = targetDir.appendingPathComponent("settings.json").path
  let fileMode = hooksInstallerFileMode(at: settingsPath)
  #expect(fileMode == 0o600)
}
