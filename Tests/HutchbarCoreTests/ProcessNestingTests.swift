// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing

@testable import HutchbarCore

private let testBaseDate = Date(timeIntervalSince1970: 1_794_000_000)

@Test func processNesting_claudeToCodexBothTracked() throws {
  let claudeSession = SessionSnapshot(
    id: "claude-sess-1",
    agent: .claudeCode,
    state: .running,
    projectName: "app",
    lastActivity: testBaseDate
  )
  let codexSession = SessionSnapshot(
    id: "codex-sess-1",
    agent: .codex,
    state: .running,
    projectName: "app",
    lastActivity: testBaseDate
  )

  let claudeKey = claudeSession.sessionKey
  let codexKey = codexSession.sessionKey

  let processes = [
    ProcessInfoLite(
      pid: 100, ppid: 1, executableName: "claude", startTime: testBaseDate
    ),
    ProcessInfoLite(
      pid: 200, ppid: 100, executableName: "codex", startTime: testBaseDate.addingTimeInterval(5)
    ),
  ]

  let sessionPids: [SessionKey: Int32] = [
    claudeKey: 100,
    codexKey: 200,
  ]

  let result = ProcessNesting.children(
    sessions: [claudeSession, codexSession],
    sessionPids: sessionPids,
    processes: processes,
    now: testBaseDate
  )

  #expect(result.parentByChild[codexKey] == claudeKey)
  #expect(result.ephemeral.isEmpty)
}

@Test func processNesting_claudeToAgyEphemeral() throws {
  let claudeSession = SessionSnapshot(
    id: "claude-sess-2",
    agent: .claudeCode,
    state: .running,
    projectName: "app",
    lastActivity: testBaseDate
  )
  let claudeKey = claudeSession.sessionKey

  let processes = [
    ProcessInfoLite(
      pid: 100, ppid: 1, executableName: "claude", startTime: testBaseDate
    ),
    ProcessInfoLite(
      pid: 300, ppid: 100, executableName: "agy", startTime: testBaseDate.addingTimeInterval(10)
    ),
  ]

  let sessionPids: [SessionKey: Int32] = [
    claudeKey: 100
  ]

  let result = ProcessNesting.children(
    sessions: [claudeSession],
    sessionPids: sessionPids,
    processes: processes,
    now: testBaseDate
  )

  #expect(result.parentByChild.isEmpty)
  #expect(result.ephemeral.count == 1)
  let ephemeral = try #require(result.ephemeral.first)
  #expect(ephemeral.id == "proc:300")
  #expect(ephemeral.parentKey == claudeKey)
  #expect(ephemeral.executableName == "agy")
  #expect(ephemeral.displayName == "Flash (agy)")
  #expect(ephemeral.startedAt == testBaseDate.addingTimeInterval(10))
}

@Test func processNesting_nestingThroughIntermediateZsh() throws {
  let claudeSession = SessionSnapshot(
    id: "claude-sess-3",
    agent: .claudeCode,
    state: .running,
    projectName: "app",
    lastActivity: testBaseDate
  )
  let codexSession = SessionSnapshot(
    id: "codex-sess-3",
    agent: .codex,
    state: .running,
    projectName: "app",
    lastActivity: testBaseDate
  )

  let claudeKey = claudeSession.sessionKey
  let codexKey = codexSession.sessionKey

  let processes = [
    ProcessInfoLite(
      pid: 100, ppid: 1, executableName: "claude", startTime: testBaseDate
    ),
    ProcessInfoLite(
      pid: 150, ppid: 100, executableName: "zsh", startTime: testBaseDate.addingTimeInterval(2)
    ),
    ProcessInfoLite(
      pid: 200, ppid: 150, executableName: "codex", startTime: testBaseDate.addingTimeInterval(4)
    ),
    ProcessInfoLite(
      pid: 350, ppid: 150, executableName: "gemini", startTime: testBaseDate.addingTimeInterval(6)
    ),
  ]

  let sessionPids: [SessionKey: Int32] = [
    claudeKey: 100,
    codexKey: 200,
  ]

  let result = ProcessNesting.children(
    sessions: [claudeSession, codexSession],
    sessionPids: sessionPids,
    processes: processes,
    now: testBaseDate
  )

  #expect(result.parentByChild[codexKey] == claudeKey)
  #expect(result.ephemeral.count == 1)
  let ephemeral = try #require(result.ephemeral.first)
  #expect(ephemeral.id == "proc:350")
  #expect(ephemeral.parentKey == claudeKey)
  #expect(ephemeral.executableName == "gemini")
  #expect(ephemeral.displayName == "gemini")
}

@Test func processNesting_ppidCycleTerminatesSafely() throws {
  let claudeSession = SessionSnapshot(
    id: "claude-sess-4",
    agent: .claudeCode,
    state: .running,
    projectName: "app",
    lastActivity: testBaseDate
  )
  let claudeKey = claudeSession.sessionKey

  let processes = [
    ProcessInfoLite(
      pid: 500, ppid: 501, executableName: "claude", startTime: testBaseDate
    ),
    ProcessInfoLite(
      pid: 501, ppid: 500, executableName: "zsh", startTime: testBaseDate
    ),
  ]

  let sessionPids: [SessionKey: Int32] = [
    claudeKey: 100
  ]

  let result = ProcessNesting.children(
    sessions: [claudeSession],
    sessionPids: sessionPids,
    processes: processes,
    now: testBaseDate
  )

  #expect(result.parentByChild.isEmpty)
  #expect(result.ephemeral.isEmpty)
}

@Test func processNesting_processWithoutSessionAncestorsIsIgnored() throws {
  let claudeSession = SessionSnapshot(
    id: "claude-sess-5",
    agent: .claudeCode,
    state: .running,
    projectName: "app",
    lastActivity: testBaseDate
  )
  let claudeKey = claudeSession.sessionKey

  let processes = [
    ProcessInfoLite(
      pid: 100, ppid: 1, executableName: "claude", startTime: testBaseDate
    ),
    ProcessInfoLite(
      pid: 400, ppid: 1, executableName: "agy", startTime: testBaseDate.addingTimeInterval(5)
    ),
    ProcessInfoLite(
      pid: 401, ppid: 400, executableName: "qwen", startTime: testBaseDate.addingTimeInterval(6)
    ),
  ]

  let sessionPids: [SessionKey: Int32] = [
    claudeKey: 100
  ]

  let result = ProcessNesting.children(
    sessions: [claudeSession],
    sessionPids: sessionPids,
    processes: processes,
    now: testBaseDate
  )

  #expect(result.parentByChild.isEmpty)
  #expect(result.ephemeral.isEmpty)
}

@Test func processNesting_codexSessionMatchedByCwdWithoutPid() throws {
  let repoPath = "/Users/developer/my-service"
  let claudeSession = SessionSnapshot(
    id: "claude-parent",
    agent: .claudeCode,
    state: .running,
    projectName: "my-service",
    lastActivity: testBaseDate
  )
  let codexSession = SessionSnapshot(
    id: "codex-no-pid",
    agent: .codex,
    state: .running,
    projectName: "my-service",
    lastActivity: testBaseDate,
    cwd: repoPath
  )

  let claudeKey = claudeSession.sessionKey
  let codexKey = codexSession.sessionKey

  let processes = [
    ProcessInfoLite(
      pid: 100, ppid: 1, executableName: "claude", startTime: testBaseDate
    ),
    ProcessInfoLite(
      pid: 250, ppid: 100, executableName: "codex", cwd: repoPath,
      startTime: testBaseDate.addingTimeInterval(5)
    ),
  ]

  // Note: codexKey has NO PID in sessionPids!
  let sessionPids: [SessionKey: Int32] = [
    claudeKey: 100
  ]

  let result = ProcessNesting.children(
    sessions: [claudeSession, codexSession],
    sessionPids: sessionPids,
    processes: processes,
    now: testBaseDate
  )

  #expect(result.parentByChild[codexKey] == claudeKey)
  #expect(result.ephemeral.isEmpty)
}

@Test func processNesting_agentWrapperShownOnce() {
  let claude = SessionSnapshot(
    id: "c-wrap", agent: .claudeCode, state: .running, projectName: "app",
    lastActivity: testBaseDate)
  let processes = [
    ProcessInfoLite(pid: 100, ppid: 1, executableName: "claude", startTime: testBaseDate),
    ProcessInfoLite(pid: 110, ppid: 100, executableName: "bash", startTime: testBaseDate),
    ProcessInfoLite(pid: 120, ppid: 110, executableName: "agy", startTime: testBaseDate),
    ProcessInfoLite(pid: 130, ppid: 120, executableName: "agy", startTime: testBaseDate),
  ]
  let result = ProcessNesting.children(
    sessions: [claude], sessionPids: [claude.sessionKey: 100], processes: processes,
    now: testBaseDate)
  #expect(result.ephemeral.map(\.id) == ["proc:120"])
}

@Test func processNesting_wrapperOfTrackedCodexIsNotEphemeral() {
  let claude = SessionSnapshot(
    id: "c-cx", agent: .claudeCode, state: .running, projectName: "app",
    lastActivity: testBaseDate)
  let codex = SessionSnapshot(
    id: "x-cx", agent: .codex, state: .running, projectName: "app", lastActivity: testBaseDate)
  let processes = [
    ProcessInfoLite(pid: 100, ppid: 1, executableName: "claude", startTime: testBaseDate),
    ProcessInfoLite(pid: 200, ppid: 100, executableName: "codex", startTime: testBaseDate),
    ProcessInfoLite(pid: 210, ppid: 200, executableName: "codex", startTime: testBaseDate),
  ]
  let result = ProcessNesting.children(
    sessions: [claude, codex],
    sessionPids: [claude.sessionKey: 100, codex.sessionKey: 210],
    processes: processes, now: testBaseDate)
  #expect(result.ephemeral.isEmpty)
  #expect(result.parentByChild[codex.sessionKey] == claude.sessionKey)
}
