// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private struct MockProcessTable: ProcessTable {
  let processes: [ProcessInfoLite]

  func allProcesses() -> [ProcessInfoLite] {
    processes
  }
}

private final class MockClock: @unchecked Sendable {
  private let lock = NSLock()
  private var _now: Date

  init(initial: Date) {
    self._now = initial
  }

  var now: Date {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _now
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _now = newValue
    }
  }
}

private let baseDate = Date(timeIntervalSince1970: 1_794_000_000)

@Test func agentLocator_privacy_cwdAndTitleExcludedFromDescriptionsAndDump() throws {
  let secretCwd = "/Volumes/Encrypted/Users/developer/secret-vault-path"
  let secretTitle = "SUPER_SECRET_TITLE_12345"
  let snapshot = SessionSnapshot(
    id: "session-abc-12345678",
    agent: .claudeCode,
    state: .running,
    projectName: "safe-project",
    title: secretTitle,
    lastActivity: baseDate,
    waitingSince: nil,
    cwd: secretCwd
  )

  let description = String(describing: snapshot)
  let debugDesc = snapshot.debugDescription
  let reflecting = String(reflecting: snapshot)
  var dumped = ""
  dump(snapshot, to: &dumped)

  for representation in [description, debugDesc, reflecting, dumped] {
    #expect(!representation.contains(secretCwd))
    #expect(!representation.contains("secret-vault-path"))
    #expect(!representation.contains(secretTitle))
  }

  #expect(description.contains("safe-project"))
  #expect(description.contains("session-"))
  #expect(description.contains("claudeCode"))
  #expect(description.contains("running"))
}

@Test func agentLocator_claudeParser_fillsCwd() throws {
  let parser = ClaudeTranscriptParser()
  let line = JSONLLine(
    bytes: Data(
      """
      {"type":"user","sessionId":"sess-c1","cwd":"/Users/alice/projects/hutchbar",\
      "timestamp":"2026-11-07T12:00:00.000Z","message":{"role":"user","content":"start"}}
      """.utf8
    )
  )
  let result = parser.parse([line], current: nil, now: baseDate)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.cwd == "/Users/alice/projects/hutchbar")
  #expect(snapshot.projectName == "hutchbar")
}

@Test func agentLocator_codexParser_fillsCwd() throws {
  let json = """
    {"type":"session_meta","timestamp":"2026-11-07T12:00:00Z",\
    "payload":{"id":"codex-sess-1","cwd":"/Users/bob/work/service-alpha"}}
    """
  let line = JSONLLine(bytes: Data(json.utf8))
  let result = CodexSessionParser.parse([line], current: nil, now: baseDate)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.cwd == "/Users/bob/work/service-alpha")
  #expect(snapshot.projectName == "service-alpha")
}

@MainActor
@Test func agentLocator_sessionStore_preservesNonEmptyCwdOnMerge() throws {
  let store = SessionStore()
  let initial = SessionSnapshot(
    id: "merge-test-1",
    agent: .claudeCode,
    state: .running,
    projectName: "my-tool",
    lastActivity: baseDate,
    cwd: "/Users/dev/repos/my-tool"
  )
  store.apply(.session(initial), now: baseDate)

  let updateWithoutCwd = SessionSnapshot(
    id: "merge-test-1",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "my-tool",
    lastActivity: baseDate.addingTimeInterval(30),
    waitingSince: baseDate.addingTimeInterval(30),
    cwd: nil
  )
  store.apply(.session(updateWithoutCwd), now: baseDate.addingTimeInterval(30))

  let stored = try #require(store.session(agent: .claudeCode, id: "merge-test-1"))
  #expect(stored.cwd == "/Users/dev/repos/my-tool")
  #expect(stored.state == .waitingForInput)
}

@Test func agentLocator_locate_warpZshClaudeMatches() throws {
  let repoPath = "/Users/dev/workspace/alpha"
  let table = MockProcessTable(
    processes: [
      ProcessInfoLite(
        pid: 100,
        ppid: 1,
        executableName: "Warp",
        cwd: nil,
        tty: nil,
        startTime: baseDate
      ),
      ProcessInfoLite(
        pid: 200,
        ppid: 100,
        executableName: "zsh",
        cwd: repoPath,
        tty: "/dev/ttys003",
        startTime: baseDate.addingTimeInterval(1)
      ),
      ProcessInfoLite(
        pid: 300,
        ppid: 200,
        executableName: "claude",
        cwd: repoPath,
        tty: "/dev/ttys003",
        startTime: baseDate.addingTimeInterval(2)
      ),
    ]
  )

  let session = SessionSnapshot(
    id: "session-1",
    agent: .claudeCode,
    state: .running,
    projectName: "alpha",
    lastActivity: baseDate,
    cwd: repoPath
  )

  let location = AgentLocator.locate(session: session, table: table) { pid in
    if pid == 100 {
      return HostApp(bundleId: "dev.warp.Warp-Stable", name: "Warp")
    }
    return nil
  }

  let found = try #require(location)
  #expect(found.pid == 300)
  #expect(found.tty == "/dev/ttys003")
  #expect(found.hostBundleId == "dev.warp.Warp-Stable")
  #expect(found.hostName == "Warp")
}

@Test func agentLocator_locate_selectsMostRecentOfTwoMatches() throws {
  let repoPath = "/Users/dev/workspace/beta"
  let olderTime = baseDate.addingTimeInterval(10)
  let newerTime = baseDate.addingTimeInterval(50)

  let table = MockProcessTable(
    processes: [
      ProcessInfoLite(
        pid: 10,
        ppid: 1,
        executableName: "Terminal",
        cwd: nil,
        startTime: baseDate
      ),
      ProcessInfoLite(
        pid: 301,
        ppid: 10,
        executableName: "claude",
        cwd: repoPath,
        tty: "/dev/ttys001",
        startTime: olderTime
      ),
      ProcessInfoLite(
        pid: 302,
        ppid: 10,
        executableName: "claude",
        cwd: repoPath,
        tty: "/dev/ttys002",
        startTime: newerTime
      ),
    ]
  )

  let session = SessionSnapshot(
    id: "session-2",
    agent: .claudeCode,
    state: .running,
    projectName: "beta",
    lastActivity: baseDate,
    cwd: repoPath
  )

  let location = AgentLocator.locate(session: session, table: table) { pid in
    if pid == 10 {
      return HostApp(bundleId: "com.apple.Terminal", name: "Terminal")
    }
    return nil
  }

  let found = try #require(location)
  #expect(found.pid == 302)
  #expect(found.tty == "/dev/ttys002")
  #expect(found.hostName == "Terminal")
}

@Test func agentLocator_locate_noMatchReturnsNil() {
  let table = MockProcessTable(
    processes: [
      ProcessInfoLite(
        pid: 10,
        ppid: 1,
        executableName: "claude",
        cwd: "/Users/dev/project-one",
        startTime: baseDate
      ),
      ProcessInfoLite(
        pid: 20,
        ppid: 1,
        executableName: "other-tool",
        cwd: "/Users/dev/project-two",
        startTime: baseDate
      ),
    ]
  )

  let sessionDiffCwd = SessionSnapshot(
    id: "s-1",
    agent: .claudeCode,
    state: .running,
    projectName: "other",
    lastActivity: baseDate,
    cwd: "/Users/dev/different-path"
  )
  #expect(AgentLocator.locate(session: sessionDiffCwd, table: table) == nil)

  let sessionNilCwd = SessionSnapshot(
    id: "s-2",
    agent: .claudeCode,
    state: .running,
    projectName: "project-one",
    lastActivity: baseDate,
    cwd: nil
  )
  #expect(AgentLocator.locate(session: sessionNilCwd, table: table) == nil)

  let sessionToolMismatch = SessionSnapshot(
    id: "s-3",
    agent: .claudeCode,
    state: .running,
    projectName: "project-two",
    lastActivity: baseDate,
    cwd: "/Users/dev/project-two"
  )
  #expect(AgentLocator.locate(session: sessionToolMismatch, table: table) == nil)

  let sessionAgentMismatch = SessionSnapshot(
    id: "s-4",
    agent: .codex,
    state: .running,
    projectName: "project-one",
    lastActivity: baseDate,
    cwd: "/Users/dev/project-one"
  )
  #expect(AgentLocator.locate(session: sessionAgentMismatch, table: table) == nil)
}

@Test func agentLocator_locate_walksParentsToHostApp() throws {
  let targetPath = "/Users/dev/workspace/gamma"
  let table = MockProcessTable(
    processes: [
      ProcessInfoLite(
        pid: 50, ppid: 1, executableName: "Ghostty", cwd: nil, startTime: baseDate
      ),
      ProcessInfoLite(
        pid: 60, ppid: 50, executableName: "login", cwd: nil, startTime: baseDate
      ),
      ProcessInfoLite(
        pid: 70, ppid: 60, executableName: "zsh", cwd: targetPath, startTime: baseDate
      ),
      ProcessInfoLite(
        pid: 80, ppid: 70, executableName: "codex", cwd: targetPath, startTime: baseDate
      ),
    ]
  )

  let session = SessionSnapshot(
    id: "sess-gamma",
    agent: .codex,
    state: .running,
    projectName: "gamma",
    lastActivity: baseDate,
    cwd: targetPath
  )

  let location = AgentLocator.locate(session: session, table: table) { pid in
    if pid == 50 {
      return HostApp(bundleId: "com.mitchellh.ghostty", name: "Ghostty")
    }
    return nil
  }

  let found = try #require(location)
  #expect(found.pid == 80)
  #expect(found.hostBundleId == "com.mitchellh.ghostty")
  #expect(found.hostName == "Ghostty")
}

@Test func agentLocator_cache_expiresAfter10Seconds() {
  let clock = MockClock(initial: baseDate)
  let cache = AgentLocationCache(ttl: 10.0) { clock.now }

  let location = AgentLocation(
    pid: 1234,
    tty: "/dev/ttys005",
    hostBundleId: "com.googlecode.iterm2",
    hostName: "iTerm2"
  )

  cache.setLocation(location, for: "session-cache-1")

  #expect(cache.location(for: "session-cache-1") == location)

  clock.now = baseDate.addingTimeInterval(9.9)
  #expect(cache.location(for: "session-cache-1") == location)

  clock.now = baseDate.addingTimeInterval(10.0)
  #expect(cache.location(for: "session-cache-1") == nil)

  clock.now = baseDate.addingTimeInterval(15.0)
  #expect(cache.location(for: "session-cache-1") == nil)
}

@Test func agentLocator_ttyValidation_rejectsInjectionAttempts() {
  #expect(AgentLocator.isValidTTY("/dev/ttys000"))
  #expect(AgentLocator.isValidTTY("/dev/ttys001"))
  #expect(AgentLocator.isValidTTY("/dev/ttys999"))
  #expect(AgentLocator.isValidTTY("/dev/ttys1000"))
  #expect(AgentLocator.isValidTTY("/dev/ttys9999"))

  let invalidTtys = [
    "/dev/ttys001\"; do shell script",
    "/dev/ttys001; rm -rf /",
    "/dev/ttys001' id",
    "/dev/ttys001\n",
    "/dev/ttys01",
    "/dev/ttys1",
    "/dev/ttys00001",
    "/dev/ttysABC",
    "ttys001",
    "/dev/tty001",
    "/dev/pts/0",
    "",
    "   ",
    "/dev/ttys001 ",
    " /dev/ttys001",
  ]

  for invalid in invalidTtys {
    #expect(!AgentLocator.isValidTTY(invalid), "Expected invalid: \(invalid)")
  }
}
