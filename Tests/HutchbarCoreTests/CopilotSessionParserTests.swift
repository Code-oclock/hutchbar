// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func copilotSessionMakeLine(_ json: String) -> JSONLLine {
  JSONLLine(bytes: Data(json.utf8))
}

@Test func copilotSessionFullTurnTransitions() throws {
  let date0 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:00:00Z"))
  let date1 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:01:00Z"))
  let date2 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:02:00Z"))
  let date3 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:03:00Z"))
  let date4 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:04:00Z"))
  let date5 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:05:00Z"))
  let date6 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:06:00Z"))

  let startLine = copilotSessionMakeLine(
    """
    {"type":"session.start","timestamp":"2026-11-09T10:00:00Z",\
    "data":{"sessionId":"copilot-sess-1","context":{"gitRoot":"/work/repos/sample-app"}}}
    """)
  let userLine = copilotSessionMakeLine(
    """
    {"type":"user.message","timestamp":"2026-11-09T10:01:00Z","data":{"content":"Refactor parser"}}
    """)
  let turnStartLine = copilotSessionMakeLine(
    """
    {"type":"assistant.turn_start","timestamp":"2026-11-09T10:02:00Z","data":{"turnId":"turn-1"}}
    """)
  let toolMessageLine = copilotSessionMakeLine(
    """
    {"type":"assistant.message","timestamp":"2026-11-09T10:03:00Z",\
    "data":{"toolRequests":[{"name":"grep"}]}}
    """)
  let turnEndIntermediary = copilotSessionMakeLine(
    """
    {"type":"assistant.turn_end","timestamp":"2026-11-09T10:04:00Z","data":{"turnId":"turn-1"}}
    """)
  let finalMessageLine = copilotSessionMakeLine(
    """
    {"type":"assistant.message","timestamp":"2026-11-09T10:05:00Z",\
    "data":{"content":"All tests passed."}}
    """)
  let turnEndFinal = copilotSessionMakeLine(
    """
    {"type":"assistant.turn_end","timestamp":"2026-11-09T10:06:00Z","data":{"turnId":"turn-1"}}
    """)

  let res0 = CopilotSessionParser.parse([startLine], current: nil, now: date0)
  let snap0 = try #require(res0.snapshot)
  #expect(snap0.id == "copilot-sess-1")
  #expect(snap0.state == .waitingForInput)
  #expect(snap0.projectName == "sample-app")
  #expect(snap0.cwd == "/work/repos/sample-app")
  #expect(snap0.waitingSince == date0)

  let res1 = CopilotSessionParser.parse([userLine], current: snap0, turn: res0.turn, now: date1)
  let snap1 = try #require(res1.snapshot)
  #expect(snap1.state == .running)
  #expect(snap1.waitingSince == nil)

  let res2 = CopilotSessionParser.parse(
    [turnStartLine], current: snap1, turn: res1.turn, now: date2)
  let snap2 = try #require(res2.snapshot)
  #expect(snap2.state == .running)

  let res3 = CopilotSessionParser.parse(
    [toolMessageLine], current: snap2, turn: res2.turn, now: date3)
  let snap3 = try #require(res3.snapshot)
  #expect(snap3.state == .running)

  let res4 = CopilotSessionParser.parse(
    [turnEndIntermediary], current: snap3, turn: res3.turn, now: date4)
  let snap4 = try #require(res4.snapshot)
  #expect(snap4.state == .running)
  #expect(snap4.waitingSince == nil)

  let res5 = CopilotSessionParser.parse(
    [finalMessageLine], current: snap4, turn: res4.turn, now: date5)
  let snap5 = try #require(res5.snapshot)
  #expect(snap5.state == .running)

  let res6 = CopilotSessionParser.parse([turnEndFinal], current: snap5, turn: res5.turn, now: date6)
  let snap6 = try #require(res6.snapshot)
  #expect(snap6.state == .waitingForInput)
  #expect(snap6.waitingSince == date6)
}

@Test func copilotSessionTurnEndWithForeignTurnIdDoesNotComplete() throws {
  let date0 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:00:00Z"))
  let date2 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:02:00Z"))
  let date3 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:03:00Z"))

  let startLine = copilotSessionMakeLine(
    """
    {"type":"session.start","timestamp":"2026-11-09T10:00:00Z","data":{"sessionId":"foreign-turn-sess"}}
    """)
  let turnStart = copilotSessionMakeLine(
    """
    {"type":"assistant.turn_start","timestamp":"2026-11-09T10:01:00Z","data":{"turnId":"expected-turn"}}
    """)
  let finalMsg = copilotSessionMakeLine(
    """
    {"type":"assistant.message","timestamp":"2026-11-09T10:02:00Z","data":{"phase":"final"}}
    """)
  let foreignEnd = copilotSessionMakeLine(
    """
    {"type":"assistant.turn_end","timestamp":"2026-11-09T10:03:00Z","data":{"turnId":"different-turn"}}
    """)

  let res0 = CopilotSessionParser.parse([startLine], current: nil, now: date0)
  let snap0 = try #require(res0.snapshot)

  let res1 = CopilotSessionParser.parse(
    [turnStart, finalMsg], current: snap0, turn: res0.turn, now: date2)
  let snap1 = try #require(res1.snapshot)
  #expect(snap1.state == .running)

  let res2 = CopilotSessionParser.parse([foreignEnd], current: snap1, turn: res1.turn, now: date3)
  let snap2 = try #require(res2.snapshot)
  #expect(snap2.state == .running)
  #expect(snap2.waitingSince == nil)
}

@Test func copilotSessionSubagentEventsDoNotChangeState() throws {
  let date0 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:00:00Z"))
  let date1 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:05:00Z"))

  let startLine = copilotSessionMakeLine(
    """
    {"type":"session.start","timestamp":"2026-11-09T10:00:00Z","data":{"sessionId":"subagent-sess"}}
    """)
  let subagentEvent = copilotSessionMakeLine(
    """
    {"type":"user.message","timestamp":"2026-11-09T10:05:00Z","agentId":"worker-agent",\
    "data":{"content":"internal subagent prompt"}}
    """)

  let res0 = CopilotSessionParser.parse([startLine], current: nil, now: date0)
  let snap0 = try #require(res0.snapshot)
  #expect(snap0.state == .waitingForInput)
  #expect(snap0.lastActivity == date0)

  let res1 = CopilotSessionParser.parse(
    [subagentEvent], current: snap0, turn: res0.turn, now: date1)
  let snap1 = try #require(res1.snapshot)
  #expect(snap1.state == .waitingForInput)
  #expect(snap1.lastActivity == date1)
}

@Test func copilotSessionAbortTransitionsToWaitingForInput() throws {
  let date0 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:00:00Z"))
  let date1 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:02:00Z"))

  let runningSnapshot = SessionSnapshot(
    id: "abort-sess",
    agent: .copilot,
    state: .running,
    projectName: "my-project",
    lastActivity: date0,
    waitingSince: nil
  )

  let abortLine = copilotSessionMakeLine(
    """
    {"type":"abort","timestamp":"2026-11-09T10:02:00Z","data":{}}
    """)
  let res = CopilotSessionParser.parse([abortLine], current: runningSnapshot, now: date1)
  let updated = try #require(res.snapshot)
  #expect(updated.state == .waitingForInput)
  #expect(updated.waitingSince == date1)
  #expect(updated.lastActivity == date1)
}

@Test func copilotSessionShutdownTransitionsToFinished() throws {
  let date0 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:00:00Z"))
  let date1 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:10:00Z"))

  let waitingSnapshot = SessionSnapshot(
    id: "shutdown-sess",
    agent: .copilot,
    state: .waitingForInput,
    projectName: "my-project",
    lastActivity: date0,
    waitingSince: date0
  )

  let shutdownLine = copilotSessionMakeLine(
    """
    {"type":"session.shutdown","timestamp":"2026-11-09T10:10:00Z","data":{}}
    """)
  let res = CopilotSessionParser.parse([shutdownLine], current: waitingSnapshot, now: date1)
  let updated = try #require(res.snapshot)
  #expect(updated.state == .finished)
  #expect(updated.waitingSince == nil)
  #expect(updated.lastActivity == date1)
}

@Test func copilotSessionContextChangedUpdatesProjectAndCwd() throws {
  let date0 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:00:00Z"))
  let date1 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:05:00Z"))

  let initial = SessionSnapshot(
    id: "ctx-sess",
    agent: .copilot,
    state: .running,
    projectName: "initial-project",
    lastActivity: date0,
    waitingSince: nil,
    cwd: "/work/initial-project"
  )

  let ctxLine = copilotSessionMakeLine(
    """
    {"type":"session.context_changed","timestamp":"2026-11-09T10:05:00Z",\
    "data":{"gitRoot":"/work/repos/renamed-project"}}
    """)
  let res = CopilotSessionParser.parse([ctxLine], current: initial, now: date1)
  let updated = try #require(res.snapshot)
  #expect(updated.projectName == "renamed-project")
  #expect(updated.cwd == "/work/repos/renamed-project")
  #expect(updated.lastActivity == date1)
}

@Test func copilotSessionFallbackWithoutStartUsesDirectoryAndDefaultProject() throws {
  let date0 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:00:00Z"))
  let userLine = copilotSessionMakeLine(
    """
    {"type":"user.message","timestamp":"2026-11-09T10:00:00Z","data":{"content":"Hello"}}
    """)

  let res = CopilotSessionParser.parse(
    [userLine],
    current: nil,
    fallbackSessionId: "session-dir-999",
    now: date0
  )
  let snap = try #require(res.snapshot)
  #expect(snap.id == "session-dir-999")
  #expect(snap.projectName == "copilot")
  #expect(snap.state == .running)
  #expect(snap.agent == .copilot)
}

@Test func copilotSessionInactivityRuleApplies() throws {
  let date0 = try #require(CopilotSessionParser.parseDate("2026-11-09T10:00:00Z"))
  let nowInactive = try #require(CopilotSessionParser.parseDate("2026-11-09T10:35:00Z"))

  let snapshot = SessionSnapshot(
    id: "inactive-sess",
    agent: .copilot,
    state: .waitingForInput,
    projectName: "sample",
    lastActivity: date0,
    waitingSince: date0
  )

  let updated = CopilotSessionParser.applyInactivityRule(to: snapshot, now: nowInactive)
  #expect(updated.state == .finished)
  #expect(updated.waitingSince == nil)
}
