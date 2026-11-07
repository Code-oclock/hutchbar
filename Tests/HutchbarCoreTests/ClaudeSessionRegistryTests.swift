// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let baseRegistryDate = Date(timeIntervalSince1970: 1_794_000_000)

private struct MockProcessTable: ProcessTable {
  let processes: [ProcessInfoLite]

  func allProcesses() -> [ProcessInfoLite] {
    processes
  }
}

private final class FakeTestFileSystem: TailFileSystem {
  var bytes = Data()
  var isSymlink = false
  var ioError: (any Error)?

  func openRegularFile(at path: String) throws -> any TailFile {
    if isSymlink {
      throw TailError.unsafeFile
    }
    if let ioError {
      throw ioError
    }
    return FakeTestFile(data: bytes)
  }
}

private final class FakeTestFile: TailFile {
  let data: Data

  init(data: Data) {
    self.data = data
  }

  func snapshot() -> FileSnapshot {
    FileSnapshot(device: 1, inode: 1, size: UInt64(data.count))
  }

  func read(from offset: UInt64, count: Int) throws -> Data {
    let start = min(Int(offset), data.count)
    let end = min(start + count, data.count)
    return data.subdata(in: start..<end)
  }

  func close() {}
}

private func makeTempDir() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent("hb-registry-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test func claudeSessionRegistry_parse_validSessionFile() throws {
  let iso = ISO8601DateFormatter().string(from: baseRegistryDate)
  let json = """
    {
      "pid": 1234,
      "sessionId": "sess-alpha-001",
      "cwd": "/Users/developer/code/my-app",
      "status": "busy",
      "statusUpdatedAt": 1794000000000,
      "procStart": "\(iso)",
      "name": "ignored-worker-name",
      "messagingSocketPath": "/tmp/claude.sock",
      "peerInfo": {"version": "1.0"}
    }
    """
  let data = Data(json.utf8)
  let session = try #require(ClaudeSessionRegistry.parse(data: data))

  #expect(session.pid == 1234)
  #expect(session.sessionId == "sess-alpha-001")
  #expect(session.cwd == "/Users/developer/code/my-app")
  #expect(session.status == .busy)
  #expect(session.statusUpdatedAt == baseRegistryDate)
  #expect(session.procStart == iso)
}

@Test func claudeSessionRegistry_parse_corruptJsonReturnsNil() {
  let malformed = Data("{\"pid\": 1234, \"sessionId\":".utf8)
  #expect(ClaudeSessionRegistry.parse(data: malformed) == nil)

  let missingField = Data("{\"pid\": 1234, \"cwd\": \"/tmp\"}".utf8)
  #expect(ClaudeSessionRegistry.parse(data: missingField) == nil)

  let emptyData = Data()
  #expect(ClaudeSessionRegistry.parse(data: emptyData) == nil)
}

@Test func claudeSessionRegistry_parse_oversizedFileExceeding64KiBReturnsNil() {
  let hugePadding = String(repeating: " ", count: 65_537)
  let hugeJson = """
    {"pid":1234,"sessionId":"s","cwd":"/","status":"idle",\
    "statusUpdatedAt":1000,"procStart":"1","pad":"\(hugePadding)"}
    """
  let data = Data(hugeJson.utf8)
  #expect(data.count > 64 * 1024)
  #expect(ClaudeSessionRegistry.parse(data: data) == nil)
}

@Test func claudeSessionRegistry_parse_unknownStatusMapsToUnknown() throws {
  let json = """
    {
      "pid": 5678,
      "sessionId": "sess-beta",
      "cwd": "/Users/developer/beta",
      "status": "waiting_for_peer_network",
      "statusUpdatedAt": 1794000000000,
      "procStart": "1794000000"
    }
    """
  let session = try #require(ClaudeSessionRegistry.parse(data: Data(json.utf8)))
  #expect(session.status == .unknown)
}

@Test func claudeSessionRegistry_liveness_deadPidReturnsFalse() {
  let table = MockProcessTable(processes: [
    ProcessInfoLite(pid: 999, ppid: 1, executableName: "zsh", startTime: baseRegistryDate)
  ])

  let alive = ClaudeSessionRegistry.isProcessAlive(
    pid: 1234,
    procStart: "2026-11-07T09:20:00Z",
    table: table
  )
  #expect(!alive)
}

@Test func claudeSessionRegistry_liveness_procStartMismatchReturnsFalse() {
  let table = MockProcessTable(processes: [
    ProcessInfoLite(pid: 1234, ppid: 1, executableName: "claude", startTime: baseRegistryDate)
  ])

  // Different start time (reused PID hours later)
  let mismatchedStart = baseRegistryDate.addingTimeInterval(3600)
  let isoMismatched = ISO8601DateFormatter().string(from: mismatchedStart)

  let alive = ClaudeSessionRegistry.isProcessAlive(
    pid: 1234,
    procStart: isoMismatched,
    table: table
  )
  #expect(!alive)
}

@Test func claudeSessionRegistry_liveness_validProcStartIsoAndNumeric() {
  let table = MockProcessTable(processes: [
    ProcessInfoLite(pid: 1234, ppid: 1, executableName: "claude", startTime: baseRegistryDate)
  ])

  // 1. ISO 8601 string
  let iso = ISO8601DateFormatter().string(from: baseRegistryDate)
  #expect(ClaudeSessionRegistry.isProcessAlive(pid: 1234, procStart: iso, table: table))

  // 2. Numeric seconds string
  let numericSec = "1794000000"
  #expect(ClaudeSessionRegistry.isProcessAlive(pid: 1234, procStart: numericSec, table: table))

  // 3. Numeric milliseconds string
  let numericMs = "1794000000000"
  #expect(ClaudeSessionRegistry.isProcessAlive(pid: 1234, procStart: numericMs, table: table))
}

@Test func claudeSessionRegistry_readSession_rejectsSymlinks() {
  let fs = FakeTestFileSystem()
  fs.isSymlink = true
  let session = ClaudeSessionRegistry.readSession(at: "/path/to/symlink.json", fileSystem: fs)
  #expect(session == nil)
}

@MainActor
@Test func claudeSessionRegistry_store_approvalPriorityOverEarlierIdle() throws {
  let store = SessionStore()
  let sessionId = "sess-approval-priority"
  let initial = SessionSnapshot(
    id: sessionId,
    agent: .claudeCode,
    state: .running,
    projectName: "my-tool",
    lastActivity: baseRegistryDate
  )
  store.apply(.session(initial), now: baseRegistryDate)

  // Hook event sets approval at T+10
  let approvalTime = baseRegistryDate.addingTimeInterval(10)
  let approvalEvent = HookEvent(ts: approvalTime, session: sessionId, kind: .approval)
  store.apply(.hookEvent(approvalEvent), now: approvalTime)

  let snapshotAfterApproval = try #require(store.session(agent: .claudeCode, id: sessionId))
  #expect(snapshotAfterApproval.state == .waitingForApproval)

  // Live status reports idle at T+5 (earlier than approval) -> approval MUST NOT be overwritten
  let earlierIdleTime = baseRegistryDate.addingTimeInterval(5)
  store.apply(
    .liveStatus(sessionId: sessionId, pid: 42, status: .idle, at: earlierIdleTime),
    now: approvalTime
  )
  let snapshotAfterEarlierIdle = try #require(store.session(agent: .claudeCode, id: sessionId))
  #expect(snapshotAfterEarlierIdle.state == .waitingForApproval)

  // Live status reports idle at T+15 (later than approval) -> transitions to waitingForInput
  let laterIdleTime = baseRegistryDate.addingTimeInterval(15)
  store.apply(
    .liveStatus(sessionId: sessionId, pid: 42, status: .idle, at: laterIdleTime),
    now: laterIdleTime
  )
  let snapshotAfterLaterIdle = try #require(store.session(agent: .claudeCode, id: sessionId))
  #expect(snapshotAfterLaterIdle.state == .waitingForInput)
  #expect(snapshotAfterLaterIdle.waitingSince == laterIdleTime)
}

@MainActor
@Test func claudeSessionRegistry_store_pidSavedByKeyNotSnapshot() throws {
  let store = SessionStore()
  let sessionId = "sess-pid-test"
  let statusTime = baseRegistryDate.addingTimeInterval(10)

  store.apply(
    .liveStatus(sessionId: sessionId, pid: 9999, status: .busy, at: statusTime),
    now: statusTime
  )

  #expect(store.pid(agent: .claudeCode, id: sessionId) == 9999)
  #expect(store.pid(for: SessionKey(agent: .claudeCode, id: sessionId)) == 9999)

  let snapshot = try #require(store.session(agent: .claudeCode, id: sessionId))
  #expect(snapshot.state == .running)
}

private func makeCoordinatorForLiveTest(
  root: String,
  table: ProcessTable
) -> SourceCoordinator {
  var config = SourceCoordinator.Configuration()
  config.claudeSessionsRoot = root
  config.enabledSources = [.claudeLive]
  return SourceCoordinator(configuration: config, processTable: table)
}

@Test func claudeSessionRegistry_coordinator_fileDisappearanceMarksFinished() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let sessionFile = tempDir.appendingPathComponent("1234.json")
  let sessionJson = """
    {"pid":1234,"sessionId":"sess-disappearing","cwd":"/",\
    "status":"busy","statusUpdatedAt":1794000000000,"procStart":"1794000000"}
    """
  try sessionJson.write(to: sessionFile, atomically: true, encoding: .utf8)

  let table = MockProcessTable(processes: [
    ProcessInfoLite(pid: 1234, ppid: 1, executableName: "claude", startTime: baseRegistryDate)
  ])
  let coordinator = makeCoordinatorForLiveTest(root: tempDir.path, table: table)
  let store = await MainActor.run { SessionStore() }

  // 1. First poll: discovers file and live process -> emits liveStatus (.busy)
  await coordinator.pollOnce()
  for await update in coordinator.updates {
    await MainActor.run { store.apply(update) }
    break
  }
  let running = await MainActor.run { store.session(agent: .claudeCode, id: "sess-disappearing") }
  #expect(running?.state == .running)

  // 2. Delete the session file
  try FileManager.default.removeItem(at: sessionFile)

  // 3. Second poll: file disappeared -> emits liveStatus (.finished)
  await coordinator.pollOnce()
  for await update in coordinator.updates {
    await MainActor.run { store.apply(update) }
    break
  }
  let finished = await MainActor.run { store.session(agent: .claudeCode, id: "sess-disappearing") }
  #expect(finished?.state == .finished)
  #expect(await MainActor.run { store.pid(agent: .claudeCode, id: "sess-disappearing") } == nil)
}

@Test func claudeSessionRegistry_agentLocator_usesKnownPidFromRegistryDirectly() throws {
  let originalCwd = "/Users/developer/original-repo"
  let changedCwd = "/Users/developer/changed-working-dir"

  let table = MockProcessTable(processes: [
    ProcessInfoLite(
      pid: 10,
      ppid: 1,
      executableName: "Warp",
      cwd: nil,
      startTime: baseRegistryDate
    ),
    ProcessInfoLite(
      pid: 500,
      ppid: 10,
      executableName: "claude",
      cwd: changedCwd,
      tty: "/dev/ttys008",
      startTime: baseRegistryDate.addingTimeInterval(5)
    ),
  ])

  let session = SessionSnapshot(
    id: "sess-with-cd",
    agent: .claudeCode,
    state: .running,
    projectName: "original-repo",
    lastActivity: baseRegistryDate,
    cwd: originalCwd
  )

  let resolveHost: (pid_t) -> HostApp? = { pid in
    if pid == 10 {
      return HostApp(bundleId: "dev.warp.Warp-Stable", name: "Warp")
    }
    return nil
  }

  // 1. Without knownPid: cwd does not match (session did 'cd'), locator fails
  let withoutPid = AgentLocator.locate(session: session, table: table, resolveApp: resolveHost)
  #expect(withoutPid == nil)

  // 2. With knownPid from registry: finds process 500 directly and walks up to Warp
  let withPid = AgentLocator.locate(
    session: session,
    knownPid: 500,
    table: table,
    resolveApp: resolveHost
  )
  let found = try #require(withPid)
  #expect(found.pid == 500)
  #expect(found.tty == "/dev/ttys008")
  #expect(found.hostName == "Warp")
  #expect(found.hostBundleId == "dev.warp.Warp-Stable")
}

@Test func registryParsesObservedCtimeProcStart() throws {
  // Exact shape written by Claude Code on the user's machine (double space before a 1-digit day).
  let date = try #require(ClaudeSessionRegistry.parseProcStart("Sat Nov  7 13:17:01 2026"))
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
  let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
  #expect(parts.year == 2026 && parts.month == 11 && parts.day == 7)
  #expect(parts.hour == 13 && parts.minute == 17 && parts.second == 1)
}
