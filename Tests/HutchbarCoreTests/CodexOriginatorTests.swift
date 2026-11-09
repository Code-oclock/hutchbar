// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func codexOriginatorMeta(_ originator: String?) -> String {
  let field = originator.map { #","originator":"\#($0)""# } ?? ""
  return #"{"timestamp":"2026-11-09T10:00:00Z","type":"session_meta","payload":{"id":"s1""#
    + #","cwd":"/tmp/app"\#(field),"instructions":"…"}}"#
}

@Test func codexOriginator_terminalSessionsEndWithProcess() {
  #expect(CodexOriginator.endsWithProcess(head: codexOriginatorMeta("codex_cli_rs")))
  #expect(CodexOriginator.endsWithProcess(head: codexOriginatorMeta("codex_exec")))
  #expect(CodexOriginator.endsWithProcess(head: codexOriginatorMeta("codex_tui")))
}

@Test func codexOriginator_desktopAndIdeSessionsDoNot() {
  #expect(!CodexOriginator.endsWithProcess(head: codexOriginatorMeta("codex_vscode")))
  #expect(!CodexOriginator.endsWithProcess(head: codexOriginatorMeta("codex_work_desktop")))
  #expect(!CodexOriginator.endsWithProcess(head: codexOriginatorMeta("Codex Desktop")))
}

@Test func codexOriginator_unknownLogsKeepProcessCheck() {
  #expect(CodexOriginator.endsWithProcess(head: codexOriginatorMeta(nil)))
  #expect(CodexOriginator.endsWithProcess(head: ""))
  #expect(CodexOriginator.endsWithProcess(head: #"{"type":"event_msg","payload":{}}"#))
  // Only the first line counts: a later originator is not session metadata.
  let later = #"{"type":"event_msg"}"# + "\n" + codexOriginatorMeta("codex_vscode")
  #expect(CodexOriginator.endsWithProcess(head: later))
  #expect(CodexOriginator.originator(in: codexOriginatorMeta("codex_vscode")) == "codex_vscode")
}

/// A Codex IDE session has no `codex` process in its folder (one shared app-server):
/// the process check must leave it alone.
@Test func codexProcessExit_ideSessionIsNotClosedWithoutProcess() async throws {
  let tempDir = try makeCodexTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let dayDir = tempDir.appendingPathComponent("codex/2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let appDir = tempDir.appendingPathComponent("ide-app")
  try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

  let clock = CodexExitClock(date: Date(timeIntervalSince1970: 1_700_050_000))
  var config = SourceCoordinator.Configuration()
  config.codexSessionsRoot = tempDir.appendingPathComponent("codex").path
  config.enabledSources = [.codexSessions]
  let coordinator = SourceCoordinator(
    configuration: config, clock: clock, processTable: CodexExitProcessTable(processes: []))
  let collector = CodexExitUpdateCollector()
  let listenTask = Task {
    for await update in coordinator.updates {
      await collector.append(update)
    }
  }
  defer { listenTask.cancel() }

  let lines = """
    {"type":"session_meta","timestamp":"2023-11-15T12:00:00Z",\
    "payload":{"id":"codex-ide","cwd":"\(appDir.path)","originator":"codex_vscode"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    """
  try appendCodexLine(lines, to: dayDir.appendingPathComponent("rollout-ide.jsonl"))

  await coordinator.pollOnce()
  #expect(await collector.waitForCount(1))
  for _ in 0..<3 {
    clock.advance(by: 10)
    await coordinator.pollOnce()
  }
  try? await Task.sleep(nanoseconds: 20_000_000)
  let finished = await collector.allItems().contains {
    if case .session(let snapshot) = $0 { return snapshot.state == .finished }
    return false
  }
  #expect(!finished)

  await coordinator.stop()
}
