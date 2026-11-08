// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

@Test func codexProcessExit_checkInterval_notMoreThanOncePerTenSeconds() async throws {
  let tempDir = try makeCodexTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let codexRoot = tempDir.appendingPathComponent("codex")
  let dayDir = codexRoot.appendingPathComponent("2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let sessionFile = dayDir.appendingPathComponent("rollout-interval.jsonl")

  let appDir = tempDir.appendingPathComponent("my-app")
  try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

  let clock = CodexExitClock(date: Date(timeIntervalSince1970: 1_700_050_000))
  let processTable = CodexExitProcessTable(processes: [])

  var config = SourceCoordinator.Configuration()
  config.codexSessionsRoot = codexRoot.path
  config.enabledSources = [.codexSessions]

  let coordinator = SourceCoordinator(
    configuration: config, clock: clock, processTable: processTable)
  let collector = CodexExitUpdateCollector()
  let listenTask = Task {
    for await update in coordinator.updates {
      await collector.append(update)
    }
  }
  defer { listenTask.cancel() }

  let lines = """
    {"type":"session_meta","timestamp":"2023-11-15T12:00:00Z",\
    "payload":{"id":"codex-interval","cwd":"\(appDir.path)"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    """
  try appendCodexLine(lines, to: sessionFile)

  // Poll 1 at t=0: check 1 runs (missing count = 1).
  await coordinator.pollOnce()
  #expect(await collector.waitForCount(1))

  // Advance 5s (t=5): poll does not trigger a check (< 10s).
  clock.advance(by: 5)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(await collector.count() == 1)

  // Advance 4s (t=9): poll still does not trigger a check (< 10s).
  clock.advance(by: 4)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(await collector.count() == 1)

  // Advance 1s (total 10s since t=0): check 2 runs -> missing count = 2 -> finished!
  clock.advance(by: 1)
  await coordinator.pollOnce()

  #expect(await collector.waitForCount(2))
  let items = await collector.allItems()
  guard case .session(let snapshot) = items.last else {
    Issue.record("Expected finished session update")
    return
  }
  #expect(snapshot.state == .finished)

  await coordinator.stop()
}

@Test func codexProcessExit_symlinkResolvedCwd_matchesSessionCwd() async throws {
  let tempDir = try makeCodexTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let codexRoot = tempDir.appendingPathComponent("codex")
  let dayDir = codexRoot.appendingPathComponent("2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let sessionFile = dayDir.appendingPathComponent("rollout-symlink.jsonl")

  let realDir = tempDir.appendingPathComponent("real-app")
  try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

  let symlinkDir = tempDir.appendingPathComponent("symlink-app")
  try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)

  let clock = CodexExitClock(date: Date(timeIntervalSince1970: 1_700_050_000))
  // Process has symlink path, session has real path.
  let processTable = CodexExitProcessTable(processes: [
    ProcessInfoLite(pid: 5555, ppid: 1, executableName: "codex", cwd: symlinkDir.path)
  ])

  var config = SourceCoordinator.Configuration()
  config.codexSessionsRoot = codexRoot.path
  config.enabledSources = [.codexSessions]

  let coordinator = SourceCoordinator(
    configuration: config, clock: clock, processTable: processTable)
  let collector = CodexExitUpdateCollector()
  let listenTask = Task {
    for await update in coordinator.updates {
      await collector.append(update)
    }
  }
  defer { listenTask.cancel() }

  let lines = """
    {"type":"session_meta","timestamp":"2023-11-15T12:00:00Z",\
    "payload":{"id":"codex-symlink","cwd":"\(realDir.path)"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    """
  try appendCodexLine(lines, to: sessionFile)

  await coordinator.pollOnce()
  #expect(await collector.waitForCount(1))

  // Advance 10s: symlink matches real path, process is found.
  clock.advance(by: 10)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(await collector.count() == 1)

  await coordinator.stop()
}
