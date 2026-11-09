// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func geminiSessionCoordinatorTempDir() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private final class GeminiSessionCoordinatorClock: TailClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date) {
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

private actor GeminiSessionCoordinatorCollector {
  private var items: [SourceUpdate] = []
  func append(_ item: SourceUpdate) { items.append(item) }
  func drain() -> [SourceUpdate] {
    let current = items
    items.removeAll()
    return current
  }
}

/// Starts a coordinator that polls only Gemini sessions under `root` and collects its updates.
private func geminiSessionCoordinatorStart(
  root: String, clock: GeminiSessionCoordinatorClock
) -> (SourceCoordinator, GeminiSessionCoordinatorCollector, Task<Void, Never>) {
  var config = SourceCoordinator.Configuration()
  config.geminiTmpRoot = root
  config.enabledSources = [.geminiSessions]
  config.freshnessWindow = 3600
  let coordinator = SourceCoordinator(configuration: config, clock: clock)
  let collector = GeminiSessionCoordinatorCollector()
  let listenTask = Task {
    for await update in coordinator.updates {
      await collector.append(update)
    }
  }
  return (coordinator, collector, listenTask)
}

@Suite("GeminiSessionCoordinatorTests")
struct GeminiSessionCoordinatorTests {
  @Test func geminiSessionCoordinatorLifecycle() async throws {
    let tempDir = try geminiSessionCoordinatorTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let geminiRoot = tempDir.appendingPathComponent("gemini-tmp")
    let projectDir = geminiRoot.appendingPathComponent("my-app")
    let chatsDir = projectDir.appendingPathComponent("chats")
    try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

    let baseDate = Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date1Str = formatter.string(from: baseDate)

    let sessionFileURL = chatsDir.appendingPathComponent("session-alpha.json")
    let turn1Content = """
      {
        "sessionId": "gem-sess-1",
        "lastUpdated": "\(date1Str)",
        "messages": [
          {"id": "m1", "timestamp": "\(date1Str)", "type": "user"}
        ]
      }
      """
    try Data(turn1Content.utf8).write(to: sessionFileURL)

    let testClock = GeminiSessionCoordinatorClock(date: baseDate)
    let (coordinator, collector, listenTask) = geminiSessionCoordinatorStart(
      root: geminiRoot.path, clock: testClock)
    defer { listenTask.cancel() }

    // 1. Initial poll yields the session in running state
    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let updates1 = await collector.drain()
    #expect(updates1.count == 1)
    guard case .session(let snap1) = updates1.first else {
      Issue.record("Expected session update")
      return
    }
    #expect(snap1.id == "gem-sess-1")
    #expect(snap1.state == .running)
    #expect(snap1.projectName == "my-app")

    // 2. Poll without changes yields nothing
    testClock.advance(by: 10.0)
    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let updates2 = await collector.drain()
    #expect(updates2.isEmpty)

    // 3. File rewritten with new turn (awaiting approval)
    let date2Str = formatter.string(from: baseDate.addingTimeInterval(10.0))
    let turn2Content = """
      {"sessionId": "gem-sess-1", "lastUpdated": "\(date2Str)", "messages": [
        {"id": "m1", "timestamp": "\(date1Str)", "type": "user"},
        {"id": "m2", "timestamp": "\(date2Str)", "type": "gemini",
         "toolCalls": [{"status": "awaiting_approval"}]}]}
      """
    try Data(turn2Content.utf8).write(to: sessionFileURL)

    testClock.advance(by: 10.0)
    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let updates3 = await collector.drain()
    #expect(updates3.count == 1)
    guard case .session(let snap3) = updates3.first else {
      Issue.record("Expected session update on new turn")
      return
    }
    #expect(snap3.id == "gem-sess-1")
    #expect(snap3.state == .waitingForApproval)

    // 4. File older than freshnessWindow drops out of query selection -> emits .finished once
    testClock.advance(by: 4000.0)
    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let updates4 = await collector.drain()
    #expect(updates4.count == 1)
    guard case .session(let snapFinished) = updates4.first else {
      Issue.record("Expected finished session update")
      return
    }
    #expect(snapFinished.id == "gem-sess-1")
    #expect(snapFinished.state == .finished)
    #expect(snapFinished.waitingSince == nil)

    // 5. Repeated poll after disappearance emits nothing
    testClock.advance(by: 70.0)
    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let updates5 = await collector.drain()
    #expect(updates5.isEmpty)
  }

  @Test func geminiSessionCoordinatorIgnoredFilesAndDirectories() async throws {
    let tempDir = try geminiSessionCoordinatorTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let geminiRoot = tempDir.appendingPathComponent("gemini-tmp")

    // Hidden project directory
    let hiddenChats = geminiRoot.appendingPathComponent(".hidden-proj/chats")
    try FileManager.default.createDirectory(at: hiddenChats, withIntermediateDirectories: true)
    let validContent = "{\"messages\": [{\"id\": \"m1\", \"type\": \"user\"}]}"
    try Data(validContent.utf8).write(to: hiddenChats.appendingPathComponent("session-h.json"))

    // Regular project with non-matching files
    let regularChats = geminiRoot.appendingPathComponent("proj-regular/chats")
    try FileManager.default.createDirectory(at: regularChats, withIntermediateDirectories: true)
    try Data(validContent.utf8).write(to: regularChats.appendingPathComponent("other-file.json"))
    try Data(validContent.utf8).write(to: regularChats.appendingPathComponent("session-abc.txt"))
    try Data(validContent.utf8).write(
      to: geminiRoot.appendingPathComponent("proj-regular/notes.json"))

    let testClock = GeminiSessionCoordinatorClock(date: Date())
    var config = SourceCoordinator.Configuration()
    config.geminiTmpRoot = geminiRoot.path
    config.enabledSources = [.geminiSessions]

    let coordinator = SourceCoordinator(configuration: config, clock: testClock)
    let collector = GeminiSessionCoordinatorCollector()
    let listenTask = Task {
      for await update in coordinator.updates {
        await collector.append(update)
      }
    }
    defer { listenTask.cancel() }

    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let updates = await collector.drain()
    #expect(updates.isEmpty)
  }

  @Test func geminiSessionCoordinatorProjectRootProvidesCwdAndProjectName() async throws {
    let tempDir = try geminiSessionCoordinatorTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let geminiRoot = tempDir.appendingPathComponent("gemini-tmp")
    let hex64Dir = geminiRoot.appendingPathComponent(
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    let chatsDir = hex64Dir.appendingPathComponent("chats")
    try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

    let rootFile = hex64Dir.appendingPathComponent(".project_root")
    try Data("/Users/someone/work/my-great-service\n".utf8).write(to: rootFile)

    let sessionContent = """
      {
        "sessionId": "gem-proj-sess",
        "messages": [
          {"id": "m1", "type": "gemini"}
        ]
      }
      """
    try Data(sessionContent.utf8).write(to: chatsDir.appendingPathComponent("session-proj.json"))

    let testClock = GeminiSessionCoordinatorClock(date: Date())
    var config = SourceCoordinator.Configuration()
    config.geminiTmpRoot = geminiRoot.path
    config.enabledSources = [.geminiSessions]

    let coordinator = SourceCoordinator(configuration: config, clock: testClock)
    let collector = GeminiSessionCoordinatorCollector()
    let listenTask = Task {
      for await update in coordinator.updates {
        await collector.append(update)
      }
    }
    defer { listenTask.cancel() }

    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    let updates = await collector.drain()
    #expect(updates.count == 1)
    guard case .session(let snap) = updates.first else {
      Issue.record("Expected session update")
      return
    }
    #expect(snap.id == "gem-proj-sess")
    #expect(snap.projectName == "my-great-service")
    #expect(snap.cwd == "/Users/someone/work/my-great-service")
  }

  /// Gemini CLI rewrites the file every turn; a half-written file must not finish the session.
  @Test func geminiSessionCoordinatorHalfWrittenFileKeepsSession() async throws {
    let tempDir = try geminiSessionCoordinatorTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let chatsDir = tempDir.appendingPathComponent("gemini-tmp/half-app/chats")
    try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
    let sessionFile = chatsDir.appendingPathComponent("session-half.json")

    let baseDate = Date()
    let stamp = ISO8601DateFormatter().string(from: baseDate)
    let fullContent = """
      {"sessionId": "gem-half", "lastUpdated": "\(stamp)",
       "messages": [{"id": "m1", "timestamp": "\(stamp)", "type": "user"}]}
      """
    try Data(fullContent.utf8).write(to: sessionFile)

    let clock = GeminiSessionCoordinatorClock(date: baseDate)
    let (coordinator, collector, listenTask) = geminiSessionCoordinatorStart(
      root: tempDir.appendingPathComponent("gemini-tmp").path, clock: clock)
    defer { listenTask.cancel() }

    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(await collector.drain().count == 1)

    // Caught mid-rewrite: truncated JSON, different size.
    try Data(fullContent.prefix(30).utf8).write(to: sessionFile)
    clock.advance(by: 10.0)
    await coordinator.pollOnce()
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(await collector.drain().isEmpty)

    await coordinator.stop()
  }
}
