// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

func makeCodexTempDir() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

final class CodexExitProcessTable: ProcessTable, @unchecked Sendable {
  let lock = NSLock()
  private var processes: [ProcessInfoLite]

  init(processes: [ProcessInfoLite] = []) {
    self.processes = processes
  }

  func setProcesses(_ processes: [ProcessInfoLite]) {
    lock.lock()
    defer { lock.unlock() }
    self.processes = processes
  }

  func allProcesses() -> [ProcessInfoLite] {
    lock.lock()
    defer { lock.unlock() }
    return processes
  }
}

final class CodexExitClock: TailClock, @unchecked Sendable {
  let lock = NSLock()
  private var current: Date

  init(date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    self.current = date
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    current = current.addingTimeInterval(seconds)
  }
}

actor CodexExitUpdateCollector {
  private var items: [SourceUpdate] = []

  func append(_ item: SourceUpdate) {
    items.append(item)
  }

  func count() -> Int {
    items.count
  }

  func allItems() -> [SourceUpdate] {
    items
  }

  func waitForCount(_ target: Int, timeoutNanoseconds: UInt64 = 500_000_000) async -> Bool {
    let start = DispatchTime.now().uptimeNanoseconds
    while items.count < target {
      if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
        return false
      }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
  }
}

func appendCodexLine(_ text: String, to url: URL) throws {
  let data = Data((text + "\n").utf8)
  if let handle = try? FileHandle(forWritingTo: url) {
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
  } else {
    try data.write(to: url)
  }
}

@Test func codexProcessExit_processRunning_sessionRemainsRunning() async throws {
  let tempDir = try makeCodexTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let codexRoot = tempDir.appendingPathComponent("codex")
  let dayDir = codexRoot.appendingPathComponent("2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let sessionFile = dayDir.appendingPathComponent("rollout-alive.jsonl")

  let appDir = tempDir.appendingPathComponent("my-app")
  try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

  let clock = CodexExitClock(date: Date(timeIntervalSince1970: 1_700_050_000))
  let processTable = CodexExitProcessTable(processes: [
    ProcessInfoLite(pid: 1234, ppid: 1, executableName: "codex", cwd: appDir.path)
  ])

  var config = SourceCoordinator.Configuration()
  config.codexSessionsRoot = codexRoot.path
  config.enabledSources = [.codexSessions]
  config.processTable = processTable

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
    "payload":{"id":"codex-alive","cwd":"\(appDir.path)"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    """
  try appendCodexLine(lines, to: sessionFile)

  await coordinator.pollOnce()
  let arrived = await collector.waitForCount(1)
  #expect(arrived)
  let items1 = await collector.allItems()
  guard case .session(let s1) = items1.first else {
    Issue.record("Expected initial session update")
    return
  }
  #expect(s1.id == "codex-alive")
  #expect(s1.state == .running)

  clock.advance(by: 10)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(await collector.count() == 1)

  clock.advance(by: 10)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(await collector.count() == 1)

  await coordinator.stop()
}

@Test func codexProcessExit_processMissingOneCheck_sessionRemainsRunning() async throws {
  let tempDir = try makeCodexTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let codexRoot = tempDir.appendingPathComponent("codex")
  let dayDir = codexRoot.appendingPathComponent("2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let sessionFile = dayDir.appendingPathComponent("rollout-miss1.jsonl")

  let appDir = tempDir.appendingPathComponent("my-app")
  try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

  let clock = CodexExitClock(date: Date(timeIntervalSince1970: 1_700_050_000))
  let processTable = CodexExitProcessTable(processes: [
    ProcessInfoLite(pid: 2222, ppid: 1, executableName: "codex", cwd: appDir.path)
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
    "payload":{"id":"codex-miss1","cwd":"\(appDir.path)"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    """
  try appendCodexLine(lines, to: sessionFile)

  await coordinator.pollOnce()
  #expect(await collector.waitForCount(1))

  // Process exits.
  processTable.setProcesses([])

  // Advance 10s: first check without process. Session still lives.
  clock.advance(by: 10)
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(await collector.count() == 1)

  await coordinator.stop()
}

@Test func codexProcessExit_processMissingTwoConsecutiveChecks_transitionsToFinished() async throws
{
  let tempDir = try makeCodexTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let codexRoot = tempDir.appendingPathComponent("codex")
  let dayDir = codexRoot.appendingPathComponent("2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let sessionFile = dayDir.appendingPathComponent("rollout-finish.jsonl")

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
    "payload":{"id":"codex-finish","cwd":"\(appDir.path)"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    """
  try appendCodexLine(lines, to: sessionFile)

  // Poll 1: session discovered; check 1 with missing process.
  await coordinator.pollOnce()
  #expect(await collector.waitForCount(1))
  let items1 = await collector.allItems()
  guard case .session(let s1) = items1.first else {
    Issue.record("Expected initial session update")
    return
  }
  #expect(s1.state == .running)

  // Advance 10s: check 2 with missing process -> triggers .finished!
  clock.advance(by: 10)
  await coordinator.pollOnce()

  #expect(await collector.waitForCount(2))
  let items2 = await collector.allItems()
  guard case .session(let s2) = items2.last else {
    Issue.record("Expected finished session update")
    return
  }
  #expect(s2.id == "codex-finish")
  #expect(s2.state == .finished)

  await coordinator.stop()
}

@Test func codexProcessExit_processMissingThenReappears_resetsCounter() async throws {
  let tempDir = try makeCodexTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let codexRoot = tempDir.appendingPathComponent("codex")
  let dayDir = codexRoot.appendingPathComponent("2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let sessionFile = dayDir.appendingPathComponent("rollout-reappear.jsonl")

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
    "payload":{"id":"codex-reappear","cwd":"\(appDir.path)"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    """
  try appendCodexLine(lines, to: sessionFile)

  // Poll 1 at t=0: missing check 1.
  await coordinator.pollOnce()
  #expect(await collector.waitForCount(1))

  // Process appears at t=10: counter resets to 0.
  clock.advance(by: 10)
  processTable.setProcesses([
    ProcessInfoLite(pid: 3333, ppid: 1, executableName: "codex", cwd: appDir.path)
  ])
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(await collector.count() == 1)

  // Process disappears at t=20: missing check 1 again (not 2).
  clock.advance(by: 10)
  processTable.setProcesses([])
  await coordinator.pollOnce()
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(await collector.count() == 1)

  // Process still missing at t=30: missing check 2 -> now finished!
  clock.advance(by: 10)
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

@Test func codexProcessExit_processInDifferentCwd_doesNotCount() async throws {
  let tempDir = try makeCodexTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let codexRoot = tempDir.appendingPathComponent("codex")
  let dayDir = codexRoot.appendingPathComponent("2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let sessionFile = dayDir.appendingPathComponent("rollout-other-cwd.jsonl")

  let appDirA = tempDir.appendingPathComponent("app-a")
  let appDirB = tempDir.appendingPathComponent("app-b")
  try FileManager.default.createDirectory(at: appDirA, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: appDirB, withIntermediateDirectories: true)

  let clock = CodexExitClock(date: Date(timeIntervalSince1970: 1_700_050_000))
  // Process is running in app-b, not app-a.
  let processTable = CodexExitProcessTable(processes: [
    ProcessInfoLite(pid: 4444, ppid: 1, executableName: "codex", cwd: appDirB.path)
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
    "payload":{"id":"codex-other-cwd","cwd":"\(appDirA.path)"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    """
  try appendCodexLine(lines, to: sessionFile)

  await coordinator.pollOnce()
  #expect(await collector.waitForCount(1))

  // Advance 10s: second check without matching process -> finished!
  clock.advance(by: 10)
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
