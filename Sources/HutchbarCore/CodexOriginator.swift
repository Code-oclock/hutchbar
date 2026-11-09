// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which Codex front end wrote a session log, from `session_meta.payload.originator`.
///
/// Only the terminal CLI runs one `codex` process per session in the session's folder.
/// Codex Desktop (`codex_work_desktop`) and the IDE extensions (`codex_vscode`) serve every
/// thread from one shared `codex app-server`, so "no `codex` process in this folder" says
/// nothing about such a session: it must end by inactivity instead.
enum CodexOriginator {
  /// Bytes read from the start of a log: `session_meta` is the first line and names the
  /// originator near its start, before the (long) instructions.
  static let headBytes = 8192

  /// True when the session should be closed once its `codex` process is gone.
  /// Unknown logs (no readable originator) keep the process check, as before.
  static func endsWithProcess(head: String) -> Bool {
    guard let originator = originator(in: head) else { return true }
    return originator == "codex_cli_rs" || originator == "codex_exec"
      || originator.hasPrefix("codex_cli") || originator.hasPrefix("codex_tui")
  }

  static func originator(in head: String) -> String? {
    guard let firstLine = head.split(separator: "\n", maxSplits: 1).first,
      firstLine.contains("\"session_meta\""),
      let keyRange = firstLine.range(of: "\"originator\"")
    else { return nil }
    let rest = firstLine[keyRange.upperBound...].drop { $0 == " " || $0 == ":" }
    guard rest.first == "\"" else { return nil }
    let value = rest.dropFirst().prefix { $0 != "\"" }
    return value.isEmpty ? nil : String(value)
  }

  /// Reads the head of a log and decides; a file that cannot be read keeps the process check.
  static func endsWithProcess(path: String, fileSystem: any TailFileSystem) -> Bool {
    guard let file = try? fileSystem.openRegularFile(at: path) else { return true }
    defer { file.close() }
    guard let data = try? file.read(from: 0, count: headBytes) else { return true }
    return endsWithProcess(head: String(decoding: data, as: UTF8.self))
  }
}
