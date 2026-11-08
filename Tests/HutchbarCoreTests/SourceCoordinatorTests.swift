// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func makeTempDir() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private final class MockClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.current = date }

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

private final class MockDirectoryLister: DirectoryLister, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: [FileMetadata]] = [:]

  init(storage: [String: [FileMetadata]] = [:]) { self.storage = storage }

  func set(items: [FileMetadata], forPath path: String) {
    lock.lock()
    defer { lock.unlock() }
    storage[path] = items
  }

  func contentsOfDirectory(atPath path: String) throws -> [FileMetadata] {
    lock.lock()
    defer { lock.unlock() }
    guard let items = storage[path] else { throw CocoaError(.fileReadNoSuchFile) }
    return items
  }
}

private actor UpdateCollector {
  var items: [SourceUpdate] = []
  func append(_ item: SourceUpdate) { items.append(item) }
  func drain() -> [SourceUpdate] { items }
}

private func drain(
  from stream: AsyncStream<SourceUpdate>,
  maxItems: Int,
  timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> [SourceUpdate] {
  guard maxItems > 0 else { return [] }
  let collector = UpdateCollector()
  await withTaskGroup(of: Void.self) { group in
    group.addTask {
      for await update in stream {
        await collector.append(update)
        if await collector.drain().count >= maxItems { break }
      }
    }
    group.addTask {
      try? await Task.sleep(nanoseconds: timeoutNanoseconds)
    }
    _ = await group.next()
    group.cancelAll()
  }
  return await collector.drain()
}

private func appendLine(_ text: String, to url: URL) throws {
  let data = Data((text + "\n").utf8)
  if let handle = try? FileHandle(forWritingTo: url) {
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
  } else {
    try data.write(to: url)
  }
}

@Test func sourceCoordinator_claudeTranscriptsDiscoveredAndAppended() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let claudeRoot = tempDir.appendingPathComponent("claude")
  let projectDir = claudeRoot.appendingPathComponent("my-project")
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let sessionFile = projectDir.appendingPathComponent("session-1.jsonl")

  let clock = MockClock()
  var config = SourceCoordinator.Configuration()
  config.claudeProjectsRoot = claudeRoot.path
  config.enabledSources = [.claudeTranscripts]

  let coordinator = SourceCoordinator(configuration: config, clock: clock)

  let line1 =
    "{\"type\":\"user\",\"sessionId\":\"sess-1\",\"cwd\":\"/work/my-project\","
    + "\"timestamp\":\"2026-11-07T12:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"build\"}}"
  try appendLine(line1, to: sessionFile)

  await coordinator.pollOnce()
  let updates1 = await drain(from: coordinator.updates, maxItems: 1)
  #expect(updates1.count == 1)
  guard case .session(let s1) = updates1.first else {
    Issue.record("Expected session update")
    return
  }
  #expect(s1.id == "sess-1")
  #expect(s1.state == .running)
  #expect(s1.projectName == "my-project")

  let line2 =
    "{\"type\":\"assistant\",\"sessionId\":\"sess-1\",\"cwd\":\"/work/my-project\","
    + "\"timestamp\":\"2026-11-07T12:00:05Z\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\"}}"
  try appendLine(line2, to: sessionFile)

  await coordinator.pollOnce()
  let updates2 = await drain(from: coordinator.updates, maxItems: 1)
  #expect(updates2.count == 1)
  guard case .session(let s2) = updates2.first else {
    Issue.record("Expected session update")
    return
  }
  #expect(s2.id == "sess-1")
  #expect(s2.state == .waitingForInput)

  await coordinator.stop()
}

@Test func sourceCoordinator_codexSessionsAndQuotasDiscovered() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let codexRoot = tempDir.appendingPathComponent("codex")
  let dayDir = codexRoot.appendingPathComponent("2023/11/15")
  try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
  let sessionFile = dayDir.appendingPathComponent("rollout-1.jsonl")

  let clock = MockClock(date: Date(timeIntervalSince1970: 1_700_050_000))
  var config = SourceCoordinator.Configuration()
  config.codexSessionsRoot = codexRoot.path
  config.enabledSources = [.codexSessions]

  let coordinator = SourceCoordinator(configuration: config, clock: clock)

  let lines = """
    {"type":"session_meta","timestamp":"2023-11-15T12:00:00Z",\
    "payload":{"id":"codex-1","cwd":"/work/codex-app"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:01Z","payload":{"type":"task_started"}}
    {"type":"event_msg","timestamp":"2023-11-15T12:00:02Z",\
    "payload":{"type":"token_count","rate_limits":{"plan_type":"pro",\
    "primary":{"used_percent":25.0,"window_minutes":300,"resets_at":1700100000}}}}
    """
  try appendLine(lines, to: sessionFile)

  await coordinator.pollOnce()
  let updates = await drain(from: coordinator.updates, maxItems: 2)
  #expect(updates.count == 2)

  let sessionUpdate = updates.first {
    if case .session = $0 { return true }
    return false
  }
  let quotaUpdate = updates.first {
    if case .quota = $0 { return true }
    return false
  }

  guard case .session(let snapshot) = sessionUpdate,
    case .quota(let quota) = quotaUpdate
  else {
    Issue.record("Expected session and quota updates")
    return
  }
  #expect(snapshot.id == "codex-1")
  #expect(snapshot.agent == .codex)
  #expect(snapshot.state == .running)
  #expect(quota.accountName == "pro")
  #expect(quota.windows.first?.usedPercent == 25.0)

  await coordinator.stop()
}

@Test func sourceCoordinator_hookEventsDiscoveredAndStreamed() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let eventsFile = tempDir.appendingPathComponent("events.jsonl")
  let clock = MockClock()
  var config = SourceCoordinator.Configuration()
  config.eventsPath = eventsFile.path
  config.enabledSources = [.claudeHooks]

  let coordinator = SourceCoordinator(configuration: config, clock: clock)

  let event = HookEvent(
    ts: Date(timeIntervalSince1970: 1_700_000_000),
    session: "s-hook-1",
    kind: .approval
  )
  _ = HookEventWriter.write(event: event, to: eventsFile.path)

  await coordinator.pollOnce()
  let updates = await drain(from: coordinator.updates, maxItems: 1)
  #expect(updates.count == 1)
  guard case .hookEvent(let received) = updates.first else {
    Issue.record("Expected hook event update")
    return
  }
  #expect(received.session == "s-hook-1")
  #expect(received.kind == .approval)

  await coordinator.stop()
}

@Test func sourceCoordinator_fileOlderThanWindowIsIgnored() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let claudeRoot = tempDir.appendingPathComponent("claude")
  let projectDir = claudeRoot.appendingPathComponent("proj")
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

  let oldFile = projectDir.appendingPathComponent("old.jsonl")
  let freshFile = projectDir.appendingPathComponent("fresh.jsonl")

  let lineOld =
    "{\"type\":\"user\",\"sessionId\":\"sess-old\",\"cwd\":\"/work/proj\","
    + "\"timestamp\":\"2026-11-06T10:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"old\"}}"
  let lineFresh =
    "{\"type\":\"user\",\"sessionId\":\"sess-fresh\",\"cwd\":\"/work/proj\","
    + "\"timestamp\":\"2026-11-07T12:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"fresh\"}}"
  try appendLine(lineOld, to: oldFile)
  try appendLine(lineFresh, to: freshFile)

  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = MockClock(date: now)

  let lister = MockDirectoryLister()
  lister.set(
    items: [FileMetadata(path: projectDir.path, modificationDate: now, isDirectory: true)],
    forPath: claudeRoot.path
  )
  lister.set(
    items: [
      FileMetadata(path: oldFile.path, modificationDate: now.addingTimeInterval(-25 * 3600)),
      FileMetadata(path: freshFile.path, modificationDate: now.addingTimeInterval(-1 * 3600)),
    ],
    forPath: projectDir.path
  )

  var config = SourceCoordinator.Configuration()
  config.claudeProjectsRoot = claudeRoot.path
  config.enabledSources = [.claudeTranscripts]
  config.freshnessWindow = 24 * 3600

  let coordinator = SourceCoordinator(
    configuration: config,
    directoryLister: lister,
    clock: clock
  )

  await coordinator.pollOnce()
  let updates = await drain(from: coordinator.updates, maxItems: 1)
  #expect(updates.count == 1)
  guard case .session(let snapshot) = updates.first else {
    Issue.record("Expected session update")
    return
  }
  #expect(snapshot.id == "sess-fresh")

  await coordinator.stop()
}

@Test func sourceCoordinator_maxTrackedFilesLimitSelectsFreshest() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let claudeRoot = tempDir.appendingPathComponent("claude")
  let projectDir = claudeRoot.appendingPathComponent("proj")
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

  let file1 = projectDir.appendingPathComponent("s1.jsonl")
  let file2 = projectDir.appendingPathComponent("s2.jsonl")
  let file3 = projectDir.appendingPathComponent("s3.jsonl")

  let lineTemplate = { (id: String) in
    "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/w\","
      + "\"timestamp\":\"2026-11-07T12:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"q\"}}"
  }
  try appendLine(lineTemplate("s1"), to: file1)
  try appendLine(lineTemplate("s2"), to: file2)
  try appendLine(lineTemplate("s3"), to: file3)

  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = MockClock(date: now)

  let lister = MockDirectoryLister()
  lister.set(
    items: [FileMetadata(path: projectDir.path, modificationDate: now, isDirectory: true)],
    forPath: claudeRoot.path
  )
  lister.set(
    items: [
      FileMetadata(path: file1.path, modificationDate: now.addingTimeInterval(-300)),
      FileMetadata(path: file2.path, modificationDate: now.addingTimeInterval(-200)),
      FileMetadata(path: file3.path, modificationDate: now.addingTimeInterval(-100)),
    ],
    forPath: projectDir.path
  )

  var config = SourceCoordinator.Configuration()
  config.claudeProjectsRoot = claudeRoot.path
  config.enabledSources = [.claudeTranscripts]
  config.maxTrackedFiles = 2

  let coordinator = SourceCoordinator(
    configuration: config,
    directoryLister: lister,
    clock: clock
  )

  await coordinator.pollOnce()
  let updates = await drain(from: coordinator.updates, maxItems: 2)
  #expect(updates.count == 2)

  let sessionIds = updates.compactMap { update -> String? in
    if case .session(let snapshot) = update { return snapshot.id }
    return nil
  }
  #expect(Set(sessionIds) == Set(["s2", "s3"]))

  await coordinator.stop()
}

@Test func sourceCoordinator_inactivityTransitionsToFinished() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let claudeRoot = tempDir.appendingPathComponent("claude")
  let projectDir = claudeRoot.appendingPathComponent("proj")
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let sessionFile = projectDir.appendingPathComponent("sess-inact.jsonl")

  let startTime = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = MockClock(date: startTime)

  var config = SourceCoordinator.Configuration()
  config.claudeProjectsRoot = claudeRoot.path
  config.enabledSources = [.claudeTranscripts]

  let coordinator = SourceCoordinator(configuration: config, clock: clock)

  let line =
    "{\"type\":\"assistant\",\"sessionId\":\"sess-inact\",\"cwd\":\"/work/proj\","
    + "\"timestamp\":\"2023-11-14T22:13:20Z\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\"}}"
  try appendLine(line, to: sessionFile)

  await coordinator.pollOnce()
  let updates1 = await drain(from: coordinator.updates, maxItems: 1)
  #expect(updates1.count == 1)
  guard case .session(let snapshot1) = updates1.first else {
    Issue.record("Expected session update")
    return
  }
  #expect(snapshot1.state == .waitingForInput)

  clock.advance(by: 31 * 60)
  await coordinator.pollOnce()
  let updates2 = await drain(from: coordinator.updates, maxItems: 1)
  #expect(updates2.count == 1)
  guard case .session(let snapshot2) = updates2.first else {
    Issue.record("Expected session update")
    return
  }
  #expect(snapshot2.state == .finished)

  await coordinator.stop()
}

@Test func sourceCoordinator_fileEvictedWhenOlderThanWindow() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let claudeRoot = tempDir.appendingPathComponent("claude")
  let projectDir = claudeRoot.appendingPathComponent("proj")
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let sessionFile = projectDir.appendingPathComponent("sess-evict.jsonl")

  let startTime = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = MockClock(date: startTime)

  let lister = MockDirectoryLister()
  lister.set(
    items: [FileMetadata(path: projectDir.path, modificationDate: startTime, isDirectory: true)],
    forPath: claudeRoot.path
  )
  lister.set(
    items: [FileMetadata(path: sessionFile.path, modificationDate: startTime)],
    forPath: projectDir.path
  )

  var config = SourceCoordinator.Configuration()
  config.claudeProjectsRoot = claudeRoot.path
  config.enabledSources = [.claudeTranscripts]
  config.freshnessWindow = 24 * 3600

  let coordinator = SourceCoordinator(
    configuration: config,
    directoryLister: lister,
    clock: clock
  )

  try appendLine(
    "{\"type\":\"user\",\"sessionId\":\"s-evict\",\"cwd\":\"/w/p\","
      + "\"timestamp\":\"2023-11-14T22:13:20Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}",
    to: sessionFile
  )

  await coordinator.pollOnce()
  let updates1 = await drain(from: coordinator.updates, maxItems: 1)
  #expect(updates1.count == 1)

  clock.advance(by: 25 * 3600)
  await coordinator.pollOnce()

  let updates2 = await drain(from: coordinator.updates, maxItems: 1, timeoutNanoseconds: 50_000_000)
  #expect(updates2.isEmpty)

  await coordinator.stop()
}

@Test func sourceCoordinator_stopIsIdempotentAndFinishesStream() async throws {
  let coordinator = SourceCoordinator()
  var iterator = coordinator.updates.makeAsyncIterator()
  await coordinator.stop()
  await coordinator.stop()
  let nextItem = await iterator.next()
  #expect(nextItem == nil)
}

@Test func sourceCoordinator_startAndStopBackgroundPolling() async throws {
  let tempDir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let claudeRoot = tempDir.appendingPathComponent("claude")
  let projectDir = claudeRoot.appendingPathComponent("proj")
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let sessionFile = projectDir.appendingPathComponent("sess-bg.jsonl")

  var config = SourceCoordinator.Configuration()
  config.claudeProjectsRoot = claudeRoot.path
  config.enabledSources = [.claudeTranscripts]
  config.pollInterval = 0.05

  let coordinator = SourceCoordinator(configuration: config)

  await coordinator.start()
  await coordinator.start()

  try appendLine(
    "{\"type\":\"user\",\"sessionId\":\"s-bg\",\"cwd\":\"/w/p\","
      + "\"timestamp\":\"2026-11-07T12:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"run\"}}",
    to: sessionFile
  )

  let updates = await drain(from: coordinator.updates, maxItems: 1)
  #expect(updates.count == 1)
  await coordinator.stop()
}

@Test func sourceCoordinator_weakReferenceBecomesNilAfterStop() async throws {
  weak var weakCoord: SourceCoordinator?
  do {
    let coordinator = SourceCoordinator()
    weakCoord = coordinator
    await coordinator.start()
    await coordinator.stop()
  }
  #expect(weakCoord == nil)
}
