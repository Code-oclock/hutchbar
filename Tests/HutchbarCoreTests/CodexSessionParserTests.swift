// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func makeLine(_ json: String) -> JSONLLine {
  JSONLLine(bytes: Data(json.utf8))
}

@Test func sessionMetaCreatesIdentityAndParsesCwd() throws {
  let expectedDate = try #require(CodexSessionParser.parseDate("2026-11-07T12:00:00Z"))
  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:05:00Z"))
  let lines = [makeLine(CodexSyntheticFixtures.validSessionMeta)]
  let result = CodexSessionParser.parse(lines: lines, current: nil, now: now)

  #expect(result.skippedLines == 0)
  #expect(result.quota == nil)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.id == "session-uuid-001")
  #expect(snapshot.agent == .codex)
  #expect(snapshot.state == .waitingForInput)
  #expect(snapshot.projectName == "sample-app")
  #expect(snapshot.title == nil)
  #expect(snapshot.waitingSince == expectedDate)
  #expect(snapshot.lastActivity == expectedDate)
}

@Test func sessionMetaFallbackIdAndTrailingSlashCwd() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:01:00Z"))
  let json = """
    {"type":"session_meta","timestamp":"2026-11-07T12:00:00Z",\
    "payload":{"id":"","session_id":"session-fallback-999","cwd":"/work/backend/"}}
    """
  let result = CodexSessionParser.parse([makeLine(json)], current: nil, now: now)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.id == "session-fallback-999")
  #expect(snapshot.projectName == "backend")
  #expect(result.skippedLines == 0)
}

@Test func sessionMetaUpdatesExistingSnapshot() throws {
  let initialDate = try #require(CodexSessionParser.parseDate("2026-11-07T11:00:00Z"))
  let existing = SessionSnapshot(
    id: "initial-id",
    agent: .codex,
    state: .running,
    projectName: "old-project",
    title: "Session Title",
    lastActivity: initialDate,
    waitingSince: nil
  )

  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:05:00Z"))
  let expectedDate = try #require(CodexSessionParser.parseDate("2026-11-07T12:00:00Z"))
  let result = CodexSessionParser.parse(
    lines: [makeLine(CodexSyntheticFixtures.validSessionMeta)],
    current: existing,
    now: now
  )

  let updated = try #require(result.snapshot)
  #expect(updated.id == "session-uuid-001")
  #expect(updated.state == .running)
  #expect(updated.projectName == "sample-app")
  #expect(updated.title == "Session Title")
  #expect(updated.waitingSince == nil)
  #expect(updated.lastActivity == expectedDate)
}

@Test func turnContextUpdatesProjectNameAndLastActivity() throws {
  let initialDate = try #require(CodexSessionParser.parseDate("2026-11-07T12:00:00Z"))
  let existing = SessionSnapshot(
    id: "session-001",
    agent: .codex,
    state: .waitingForInput,
    projectName: "sample-app",
    lastActivity: initialDate,
    waitingSince: initialDate
  )

  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:02:00Z"))
  let expectedDate = try #require(CodexSessionParser.parseDate("2026-11-07T12:01:00Z"))
  let result = CodexSessionParser.parse(
    lines: [makeLine(CodexSyntheticFixtures.validTurnContext)],
    current: existing,
    now: now
  )

  let updated = try #require(result.snapshot)
  #expect(updated.projectName == "sample-app-renamed")
  #expect(updated.state == .waitingForInput)
  #expect(updated.lastActivity == expectedDate)
  #expect(updated.waitingSince == initialDate)
  #expect(result.skippedLines == 0)
}

@Test func taskStartedTransitionsToRunning() throws {
  let initialDate = try #require(CodexSessionParser.parseDate("2026-11-07T12:00:00Z"))
  let existing = SessionSnapshot(
    id: "session-001",
    agent: .codex,
    state: .waitingForInput,
    projectName: "sample-app",
    lastActivity: initialDate,
    waitingSince: initialDate
  )

  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:06:00Z"))
  let expectedDate = try #require(CodexSessionParser.parseDate("2026-11-07T12:05:00Z"))
  let result = CodexSessionParser.parse(
    lines: [makeLine(CodexSyntheticFixtures.taskStarted)],
    current: existing,
    now: now
  )

  let updated = try #require(result.snapshot)
  #expect(updated.state == .running)
  #expect(updated.waitingSince == nil)
  #expect(updated.lastActivity == expectedDate)
  #expect(result.skippedLines == 0)
}

@Test func taskCompleteTransitionsToWaitingForInput() throws {
  let initialDate = try #require(CodexSessionParser.parseDate("2026-11-07T12:05:00Z"))
  let existing = SessionSnapshot(
    id: "session-001",
    agent: .codex,
    state: .running,
    projectName: "sample-app",
    lastActivity: initialDate,
    waitingSince: nil
  )

  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:16:00Z"))
  let completionDate = try #require(CodexSessionParser.parseDate("2026-11-07T12:15:00Z"))
  let result = CodexSessionParser.parse(
    lines: [makeLine(CodexSyntheticFixtures.taskComplete)],
    current: existing,
    now: now
  )

  let updated = try #require(result.snapshot)
  #expect(updated.state == .waitingForInput)
  #expect(updated.waitingSince == completionDate)
  #expect(updated.lastActivity == completionDate)
  #expect(result.skippedLines == 0)
}

@Test func tokenCountParsesFullRateLimitsAndPlanType() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:11:00Z"))
  let expectedObservedAt = try #require(CodexSessionParser.parseDate("2026-11-07T12:10:00Z"))
  let result = CodexSessionParser.parse(
    lines: [makeLine(CodexSyntheticFixtures.tokenCountFull)],
    current: nil,
    now: now
  )

  #expect(result.skippedLines == 0)
  let quota = try #require(result.quota)
  #expect(quota.agent == .codex)
  #expect(quota.accountName == "pro")
  #expect(quota.id == "codex:pro")
  #expect(quota.windows.count == 2)

  let primary = quota.windows[0]
  #expect(primary.windowMinutes == 300)
  #expect(primary.usedPercent == 25.5)
  #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_762_512_000))

  let secondary = quota.windows[1]
  #expect(secondary.windowMinutes == 10080)
  #expect(secondary.usedPercent == 80.0)
  #expect(secondary.resetsAt == Date(timeIntervalSince1970: 1_762_800_000))
  #expect(quota.observedAt == expectedObservedAt)
}

@Test func tokenCountReturnsLatestInBatch() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:20:00Z"))
  let line1 = """
    {"type":"event_msg","timestamp":"2026-11-07T12:05:00Z",\
    "payload":{"type":"token_count","rate_limits":{"plan_type":"free",\
    "primary":{"used_percent":10.0,"window_minutes":60,"resets_at":1762512000}}}}
    """
  let line2 = """
    {"type":"event_msg","timestamp":"2026-11-07T12:15:00Z",\
    "payload":{"type":"token_count","rate_limits":{"plan_type":"team",\
    "primary":{"used_percent":45.0,"window_minutes":60,"resets_at":1762512000}}}}
    """

  let result = CodexSessionParser.parse(
    [makeLine(line1), makeLine(line2)],
    current: nil,
    now: now
  )
  let quota = try #require(result.quota)
  #expect(quota.accountName == "team")
  #expect(quota.windows.first?.usedPercent == 45.0)
}

@Test func tokenCountHandlesNullRateLimitFieldsAndClamping() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:11:00Z"))
  let result = CodexSessionParser.parse(
    lines: [makeLine(CodexSyntheticFixtures.tokenCountWithNulls)],
    current: nil,
    now: now
  )

  let quota = try #require(result.quota)
  #expect(quota.accountName == "codex")
  #expect(quota.windows.count == 1)
  let window = try #require(quota.windows.first)
  #expect(window.windowMinutes == 0)
  #expect(window.usedPercent == 0.0)
  #expect(window.resetsAt == nil)

  let clampedJson = """
    {"type":"event_msg","timestamp":"2026-11-07T12:10:00Z",\
    "payload":{"type":"token_count","rate_limits":{"plan_type":"",\
    "primary":{"used_percent":120.0,"window_minutes":60,"resets_at":null},\
    "secondary":{"used_percent":-15.0,"window_minutes":120,"resets_at":null}}}}
    """
  let clampedResult = CodexSessionParser.parse([makeLine(clampedJson)], current: nil, now: now)
  let clampedQuota = try #require(clampedResult.quota)
  #expect(clampedQuota.accountName == "codex")
  #expect(clampedQuota.windows.count == 2)
  #expect(clampedQuota.windows[0].usedPercent == 100.0)
  #expect(clampedQuota.windows[1].usedPercent == 0.0)

  let nullRateLimitsJson = """
    {"type":"event_msg","timestamp":"2026-11-07T12:10:00Z",\
    "payload":{"type":"token_count","rate_limits":null}}
    """
  let nullRateLimitsResult = CodexSessionParser.parse(
    [makeLine(nullRateLimitsJson)],
    current: nil,
    now: now
  )
  #expect(nullRateLimitsResult.quota == nil)
}

@Test func brokenAndMalformedLinesAreSkippedAndCounted() throws {
  let now = Date()
  let malformedLines = [
    makeLine(""),
    makeLine("   "),
    makeLine("{\"type\":\"session_meta\""),
    makeLine("{broken json}"),
    makeLine("42"),
    makeLine("[\"array\", \"not\", \"object\"]"),
  ]

  let result = CodexSessionParser.parse(malformedLines, current: nil, now: now)
  #expect(result.snapshot == nil)
  #expect(result.quota == nil)
  #expect(result.skippedLines == 6)
}

@Test func unknownRecordTypesAndUnknownEventsAreSkipped() throws {
  let now = Date()
  let unknownLines = [
    makeLine("{\"type\":\"future_record_kind\",\"timestamp\":\"2026-11-07T12:00:00Z\"}"),
    makeLine("{\"timestamp\":\"2026-11-07T12:00:00Z\"}"),
    makeLine("{\"type\":\"event_msg\",\"payload\":{\"type\":\"unknown_event_kind\"}}"),
    makeLine("{\"type\":\"event_msg\"}"),
  ]

  let result = CodexSessionParser.parse(unknownLines, current: nil, now: now)
  #expect(result.snapshot == nil)
  #expect(result.quota == nil)
  #expect(result.skippedLines == 4)
}

@Test func codexInactivityRuleTransitionsToFinished() throws {
  let activity = try #require(CodexSessionParser.parseDate("2026-11-07T12:00:00Z"))
  let activeAt29m = try #require(CodexSessionParser.parseDate("2026-11-07T12:29:59Z"))
  let inactiveAt30m = try #require(CodexSessionParser.parseDate("2026-11-07T12:30:00Z"))
  let inactiveAt35m = try #require(CodexSessionParser.parseDate("2026-11-07T12:35:00Z"))

  #expect(!CodexSessionParser.isInactive(lastActivity: activity, now: activeAt29m))
  #expect(CodexSessionParser.isInactive(lastActivity: activity, now: inactiveAt30m))
  #expect(CodexSessionParser.isInactive(lastActivity: activity, now: inactiveAt35m))

  let activeSnapshot = SessionSnapshot(
    id: "session-001",
    agent: .codex,
    state: .running,
    projectName: "app",
    lastActivity: activity,
    waitingSince: nil
  )

  let keptActive = CodexSessionParser.applyInactivityTimeout(to: activeSnapshot, now: activeAt29m)
  #expect(keptActive.state == .running)

  let timedOut = CodexSessionParser.applyInactivityTimeout(to: activeSnapshot, now: inactiveAt30m)
  #expect(timedOut.state == .finished)
  #expect(timedOut.waitingSince == nil)

  let timedOutAlias = CodexSessionParser.applyInactivityRule(to: activeSnapshot, now: inactiveAt35m)
  #expect(timedOutAlias.state == .finished)

  let alreadyFinished = SessionSnapshot(
    id: "session-002",
    agent: .codex,
    state: .finished,
    projectName: "app",
    lastActivity: activity,
    waitingSince: nil
  )
  let finishedResult = CodexSessionParser.applyInactivityTimeout(
    to: alreadyFinished,
    now: inactiveAt35m
  )
  #expect(finishedResult.state == .finished)

  let parseResult = CodexSessionParser.parse(
    lines: [makeLine(CodexSyntheticFixtures.validSessionMeta)],
    current: nil,
    now: inactiveAt35m
  )
  let parseSnapshot = try #require(parseResult.snapshot)
  #expect(parseSnapshot.state == .finished)
  #expect(parseSnapshot.waitingSince == nil)
}

@Test func privacyRulesEnforcedAndNoSecretsLeak() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:01:00Z"))
  let result = CodexSessionParser.parse(
    lines: [makeLine(CodexSyntheticFixtures.privacySensitiveFixture)],
    current: nil,
    now: now
  )

  let snapshot = try #require(result.snapshot)
  #expect(snapshot.projectName == "my-project")
  #expect(!snapshot.projectName.contains("super-secret-vault"))
  #expect(!snapshot.projectName.contains("/Users/alice"))

  let descriptions = [
    String(describing: result),
    String(reflecting: result),
    result.description,
    result.debugDescription,
  ]

  let sensitiveTokens = [
    CodexSyntheticFixtures.secretPrompt,
    CodexSyntheticFixtures.secretCode,
    CodexSyntheticFixtures.secretToken,
    "super-secret-vault",
  ]

  for representation in descriptions {
    for token in sensitiveTokens {
      #expect(!representation.contains(token))
    }
  }

  var dumped = ""
  dump(result, to: &dumped)
  for token in sensitiveTokens {
    #expect(!dumped.contains(token))
  }
}

@Test func fullSessionLifecycleFromBatch() throws {
  let now = try #require(CodexSessionParser.parseDate("2026-11-07T12:20:00Z"))
  let expectedWaitingSince = try #require(CodexSessionParser.parseDate("2026-11-07T12:15:00Z"))
  let lines = [
    makeLine(CodexSyntheticFixtures.validSessionMeta),
    makeLine(CodexSyntheticFixtures.validTurnContext),
    makeLine(CodexSyntheticFixtures.taskStarted),
    makeLine(CodexSyntheticFixtures.tokenCountFull),
    makeLine(CodexSyntheticFixtures.taskComplete),
  ]

  let result = CodexSessionParser.parse(lines: lines, current: nil, now: now)
  #expect(result.skippedLines == 0)
  #expect(result.quota != nil)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.id == "session-uuid-001")
  #expect(snapshot.projectName == "sample-app-renamed")
  #expect(snapshot.state == .waitingForInput)
  #expect(snapshot.waitingSince == expectedWaitingSince)
  #expect(result.elements.snapshot?.id == "session-uuid-001")
}
