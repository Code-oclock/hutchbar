// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let hooksShapeBinary = "/Applications/Hutchbar.app/Contents/MacOS/hutchbar"

/// Writes `content` as settings.json in a fresh temp folder, tries to install,
/// and reports whether it was refused and whether the file stayed byte-for-byte the same.
private func hooksShapeInstall(content: String) throws -> (refused: Bool, untouched: Bool) {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("hutchbar-shape-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let settings = dir.appendingPathComponent("settings.json")
  try Data(content.utf8).write(to: settings)

  var refused = false
  do {
    _ = try ClaudeHooksInstaller.install(
      at: dir.path, binaryPath: hooksShapeBinary, now: Date(timeIntervalSince1970: 1_731_150_000))
  } catch ClaudeHooksError.invalidJSON {
    refused = true
  }
  let after = try String(contentsOf: settings, encoding: .utf8)
  let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    .filter { $0.contains("hutchbar-backup") }
  return (refused, after == content && backups.isEmpty)
}

/// `hooks` that is not an object would be replaced on write: refuse and leave the file alone.
@Test func hooksInstallerRefusesNonObjectHooks() throws {
  let result = try hooksShapeInstall(content: #"{"hooks": ["someone", "else"], "model": "x"}"#)
  #expect(result.refused)
  #expect(result.untouched)
}

/// An event that is not an array (another tool's format) must not be overwritten either.
@Test func hooksInstallerRefusesNonArrayEvent() throws {
  let result = try hooksShapeInstall(content: #"{"hooks": {"Stop": {"command": "theirs"}}}"#)
  #expect(result.refused)
  #expect(result.untouched)
}

@Test func hooksInstallerShapeCheck() {
  #expect(ClaudeHooksInstaller.hasEditableHooksShape([:]))
  #expect(ClaudeHooksInstaller.hasEditableHooksShape(["hooks": ["Other": "anything"]]))
  #expect(ClaudeHooksInstaller.hasEditableHooksShape(["hooks": ["Stop": [Any]()]]))
  #expect(!ClaudeHooksInstaller.hasEditableHooksShape(["hooks": "text"]))
  #expect(!ClaudeHooksInstaller.hasEditableHooksShape(["hooks": ["Stop": 1]]))
}
