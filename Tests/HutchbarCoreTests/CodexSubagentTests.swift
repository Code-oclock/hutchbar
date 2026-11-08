// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func makeLine(_ json: String) -> JSONLLine {
  JSONLLine(bytes: Data(json.utf8))
}

@Test func codexSubagent_subagentSourceCreatesChildWithParentThreadId() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-08T12:00:00Z"))
  let json = """
    {"type":"session_meta","timestamp":"2026-11-08T11:55:00Z",\
    "payload":{"id":"child-uuid-1","session_id":"child-uuid-1",\
    "parent_thread_id":"parent-uuid-999","source":{"subagent":{"agent_type":"test"}},\
    "cwd":"/work/my-project"}}
    """
  let result = CodexSessionParser.parse([makeLine(json)], current: nil, now: now)
  let snapshot = try #require(result.snapshot)

  #expect(snapshot.id == "child-uuid-1")
  #expect(snapshot.agent == .codex)
  #expect(snapshot.parentKey == SessionKey(agent: .codex, id: "parent-uuid-999"))
  #expect(snapshot.childKind == .subagent)
}

@Test func codexSubagent_internalSourceCreatesChildWithSessionIdFallback() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-08T12:00:00Z"))
  let json = """
    {"type":"session_meta","timestamp":"2026-11-08T11:55:00Z",\
    "payload":{"id":"child-uuid-2","session_id":"parent-session-888",\
    "source":{"internal":true},"cwd":"/work/my-project"}}
    """
  let result = CodexSessionParser.parse([makeLine(json)], current: nil, now: now)
  let snapshot = try #require(result.snapshot)

  #expect(snapshot.id == "child-uuid-2")
  #expect(snapshot.parentKey == SessionKey(agent: .codex, id: "parent-session-888"))
  #expect(snapshot.childKind == .subagent)
}

@Test func codexSubagent_sameSessionIdAndIdMeansNoParent() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-08T12:00:00Z"))
  let json = """
    {"type":"session_meta","timestamp":"2026-11-08T11:55:00Z",\
    "payload":{"id":"root-session-123","session_id":"root-session-123",\
    "source":{"subagent":{}},"cwd":"/work/my-project"}}
    """
  let result = CodexSessionParser.parse([makeLine(json)], current: nil, now: now)
  let snapshot = try #require(result.snapshot)

  #expect(snapshot.id == "root-session-123")
  #expect(snapshot.parentKey == nil)
  #expect(snapshot.childKind == nil)
}

@Test func codexSubagent_missingSourceProducesRegularSession() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-08T12:00:00Z"))
  let json = """
    {"type":"session_meta","timestamp":"2026-11-08T11:55:00Z",\
    "payload":{"id":"standard-session-456","session_id":"standard-session-456",\
    "cwd":"/work/my-project"}}
    """
  let result = CodexSessionParser.parse([makeLine(json)], current: nil, now: now)
  let snapshot = try #require(result.snapshot)

  #expect(snapshot.id == "standard-session-456")
  #expect(snapshot.parentKey == nil)
  #expect(snapshot.childKind == nil)
}

@Test func codexSubagent_parentThreadIdPreferredOverSessionId() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-08T12:00:00Z"))
  let json = """
    {"type":"session_meta","timestamp":"2026-11-08T11:55:00Z",\
    "payload":{"id":"child-session-789","session_id":"fallback-parent",\
    "parent_thread_id":"preferred-parent","source":{"subagent":{"name":"worker"}},\
    "cwd":"/work/my-project"}}
    """
  let result = CodexSessionParser.parse([makeLine(json)], current: nil, now: now)
  let snapshot = try #require(result.snapshot)

  #expect(snapshot.parentKey == SessionKey(agent: .codex, id: "preferred-parent"))
  #expect(snapshot.childKind == .subagent)
}
