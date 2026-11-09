// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private final class CopilotSessionTestClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
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

private actor CopilotSessionUpdateCollector {
  var items: [SourceUpdate] = []
  func append(_ item: SourceUpdate) { items.append(item) }
  func drain() -> [SourceUpdate] { items }
}

private func copilotSessionDrain(
  from stream: AsyncStream<SourceUpdate>,
  maxItems: Int,
  timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> [SourceUpdate] {
  guard maxItems > 0 else { return [] }
  let collector = CopilotSessionUpdateCollector()
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

private func copilotSessionMakeTempDir() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func copilotSessionAppend(text: String, to fileUrl: URL) throws {
  let data = Data((text + "\n").utf8)
  if let handle = try? FileHandle(forWritingTo: fileUrl) {
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
  } else {
    try data.write(to: fileUrl)
  }
}

@Test func copilotSessionCoordinatorDiscoversAndPolls() async throws {
  let tempDir = try copilotSessionMakeTempDir()
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let copilotRoot = tempDir.appendingPathComponent("copilot-root")
  let sessionDir = copilotRoot.appendingPathComponent("sess-abc")
  let hiddenDir = copilotRoot.appendingPathComponent(".hidden-session")
  try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)

  let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
  let otherFile = sessionDir.appendingPathComponent("other.txt")
  let hiddenEvents = hiddenDir.appendingPathComponent("events.jsonl")

  try copilotSessionAppend(text: "some other data", to: otherFile)
  try copilotSessionAppend(text: "{\"type\":\"session.start\"}", to: hiddenEvents)

  let line1 = """
    {"type":"session.start","timestamp":"2026-11-09T10:00:00Z",\
    "data":{"sessionId":"copilot-abc-123","context":{"cwd":"/work/my-app"}}}
    """
  try copilotSessionAppend(text: line1, to: eventsFile)

  let testClock = CopilotSessionTestClock()
  var config = SourceCoordinator.Configuration()
  config.copilotSessionRoot = copilotRoot.path
  config.enabledSources = [.copilotSessions]

  let coordinator = SourceCoordinator(configuration: config, clock: testClock)

  await coordinator.pollOnce()
  let updates = await copilotSessionDrain(from: coordinator.updates, maxItems: 1)
  #expect(updates.count == 1)

  guard case .session(let snapshot) = updates.first else {
    Issue.record("Expected session snapshot update")
    return
  }
  #expect(snapshot.id == "copilot-abc-123")
  #expect(snapshot.agent == .copilot)
  #expect(snapshot.projectName == "my-app")
  #expect(snapshot.cwd == "/work/my-app")
  #expect(snapshot.state == .waitingForInput)
}
