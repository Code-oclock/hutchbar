// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func makeLine(_ string: String) -> JSONLLine {
  JSONLLine(bytes: Data(string.utf8))
}

private let referenceDate: Date = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.date(from: "2026-11-07T12:00:00.000Z")
    ?? Date(timeIntervalSince1970: 1_794_052_800)
}()

@Test func specRow1UserPromptStringContent() throws {
  let parser = ClaudeTranscriptParser()
  let line = makeLine(
    "{\"type\":\"user\",\"sessionId\":\"sess-1\","
      + "\"cwd\":\"/Users/dev/workspace/alpha\","
      + "\"timestamp\":\"2026-11-07T12:00:00.000Z\","
      + "\"message\":{\"role\":\"user\",\"content\":\"Run unit tests\"}}"
  )
  let result = parser.parse([line], current: nil, now: referenceDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.id == "sess-1")
  #expect(snapshot.agent == .claudeCode)
  #expect(snapshot.state == .running)
  #expect(snapshot.projectName == "alpha")
  #expect(snapshot.waitingSince == nil)
  #expect(snapshot.lastActivity == referenceDate)
}

@Test func specRow1UserPromptTextBlockContent() throws {
  let parser = ClaudeTranscriptParser()
  let line = makeLine(
    "{\"type\":\"user\",\"sessionId\":\"sess-2\","
      + "\"cwd\":\"/Users/dev/workspace/beta/\","
      + "\"timestamp\":\"2026-11-07T12:00:00.000Z\","
      + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Inspect\"}]}}"
  )
  let result = parser.parse([line], current: nil, now: referenceDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.id == "sess-2")
  #expect(snapshot.state == .running)
  #expect(snapshot.projectName == "beta")
  #expect(snapshot.lastActivity == referenceDate)
}

@Test func specRow2UserToolUseResultField() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-3",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "gamma",
    lastActivity: referenceDate,
    waitingSince: referenceDate
  )
  let nextDate = referenceDate.addingTimeInterval(5)
  let line = makeLine(
    "{\"type\":\"user\",\"sessionId\":\"sess-3\","
      + "\"timestamp\":\"2026-11-07T12:00:05.000Z\","
      + "\"toolUseResult\":{\"status\":\"ok\"},"
      + "\"message\":{\"role\":\"user\",\"content\":[]}}"
  )
  let result = parser.parse([line], current: initial, now: nextDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.state == .running)
  #expect(snapshot.waitingSince == nil)
  #expect(snapshot.lastActivity == nextDate)
}

@Test func specRow2UserToolResultBlock() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-4",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "delta",
    lastActivity: referenceDate,
    waitingSince: referenceDate
  )
  let nextDate = referenceDate.addingTimeInterval(10)
  let line = makeLine(
    "{\"type\":\"user\",\"sessionId\":\"sess-4\","
      + "\"timestamp\":\"2026-11-07T12:00:10.000Z\","
      + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"id\":\"tool-1\"}]}}"
  )
  let result = parser.parse([line], current: initial, now: nextDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.state == .running)
  #expect(snapshot.waitingSince == nil)
  #expect(snapshot.lastActivity == nextDate)
}

@Test func specRow3AssistantToolUse() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-5",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "epsilon",
    lastActivity: referenceDate,
    waitingSince: referenceDate
  )
  let nextDate = referenceDate.addingTimeInterval(15)
  let line = makeLine(
    "{\"type\":\"assistant\",\"sessionId\":\"sess-5\",\"cwd\":\"/path/to/epsilon\","
      + "\"timestamp\":\"2026-11-07T12:00:15.000Z\","
      + "\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\"}}"
  )
  let result = parser.parse([line], current: initial, now: nextDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.state == .running)
  #expect(snapshot.waitingSince == nil)
  #expect(snapshot.lastActivity == nextDate)
}

@Test func specRow3AssistantEndTurn() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-6",
    agent: .claudeCode,
    state: .running,
    projectName: "zeta",
    lastActivity: referenceDate,
    waitingSince: nil
  )
  let nextDate = referenceDate.addingTimeInterval(20)
  let line = makeLine(
    "{\"type\":\"assistant\",\"sessionId\":\"sess-6\",\"cwd\":\"/path/to/zeta\","
      + "\"timestamp\":\"2026-11-07T12:00:20.000Z\","
      + "\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\"}}"
  )
  let result = parser.parse([line], current: initial, now: nextDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.state == .waitingForInput)
  #expect(snapshot.waitingSince == nextDate)
  #expect(snapshot.lastActivity == nextDate)
}

@Test func specRow4SystemTurnDuration() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-7",
    agent: .claudeCode,
    state: .running,
    projectName: "eta",
    lastActivity: referenceDate,
    waitingSince: nil
  )
  let nextDate = referenceDate.addingTimeInterval(25)
  let line = makeLine(
    "{\"type\":\"system\",\"subtype\":\"turn_duration\","
      + "\"sessionId\":\"sess-7\",\"timestamp\":\"2026-11-07T12:00:25.000Z\"}"
  )
  let result = parser.parse([line], current: initial, now: nextDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.state == .waitingForInput)
  #expect(snapshot.waitingSince == nextDate)
  #expect(snapshot.lastActivity == nextDate)

  let laterDate = referenceDate.addingTimeInterval(30)
  let secondLine = makeLine(
    "{\"type\":\"system\",\"subtype\":\"turn_duration\","
      + "\"sessionId\":\"sess-7\",\"timestamp\":\"2026-11-07T12:00:30.000Z\"}"
  )
  let secondResult = parser.parse([secondLine], current: snapshot, now: laterDate)
  let secondSnapshot = try #require(secondResult.snapshot)
  #expect(secondSnapshot.state == .waitingForInput)
  #expect(secondSnapshot.waitingSince == nextDate)
  #expect(secondSnapshot.lastActivity == laterDate)
}

@Test func specRow5CustomTitle() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-8",
    agent: .claudeCode,
    state: .running,
    projectName: "theta",
    lastActivity: referenceDate,
    waitingSince: nil
  )
  let nextDate = referenceDate.addingTimeInterval(35)
  let line = makeLine(
    "{\"type\":\"custom-title\",\"sessionId\":\"sess-8\","
      + "\"customTitle\":\"Feature Plan\",\"timestamp\":\"2026-11-07T12:00:35.000Z\"}"
  )
  let result = parser.parse([line], current: initial, now: nextDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.title == "Feature Plan")
  #expect(snapshot.state == .running)
  #expect(snapshot.lastActivity == nextDate)
}

@Test func specRow6AnythingElse() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-9",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "iota",
    lastActivity: referenceDate,
    waitingSince: referenceDate
  )
  let nextDate = referenceDate.addingTimeInterval(40)
  let lines = [
    makeLine(
      "{\"type\":\"queue-operation\",\"sessionId\":\"sess-9\",\"timestamp\":\"2026-11-07T12:00:40.000Z\"}"
    ),
    makeLine(
      "{\"type\":\"attachment\",\"sessionId\":\"sess-9\",\"timestamp\":\"2026-11-07T12:00:40.000Z\"}"
    ),
    makeLine(
      "{\"type\":\"system\",\"subtype\":\"informational\",\"sessionId\":\"sess-9\","
        + "\"timestamp\":\"2026-11-07T12:00:40.000Z\"}"
    ),
  ]
  let result = parser.parse(lines, current: initial, now: nextDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.state == .waitingForInput)
  #expect(snapshot.waitingSince == referenceDate)
  #expect(snapshot.lastActivity == nextDate)
}

@Test func unknownRecordTypesAreSkippedAndCounted() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-10",
    agent: .claudeCode,
    state: .running,
    projectName: "kappa",
    lastActivity: referenceDate,
    waitingSince: nil
  )
  let lines = [
    makeLine(
      "{\"type\":\"unknown_future_message_type\",\"timestamp\":\"2026-11-07T12:00:45.000Z\"}"),
    makeLine("{\"no_type_field_at_all\":true,\"timestamp\":\"2026-11-07T12:00:45.000Z\"}"),
    makeLine("{\"type\":\"unsupported-alien-record\",\"data\":123}"),
  ]
  let result = parser.parse(lines, current: initial, now: referenceDate)
  #expect(result.skippedLines == 3)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.state == .running)
  #expect(snapshot.lastActivity == referenceDate)
}

@Test func malformedJsonIsSkippedAndCounted() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-11",
    agent: .claudeCode,
    state: .running,
    projectName: "lambda",
    lastActivity: referenceDate,
    waitingSince: nil
  )
  let lines = [
    makeLine("{\"unclosed JSON string: \"missing\""),
    makeLine("{not valid json at all}"),
    makeLine(""),
    makeLine("{\"type\":\"user\",\"timestamp\":\"not-an-iso8601-date\"}"),
  ]
  let result = parser.parse(lines, current: initial, now: referenceDate)
  #expect(result.skippedLines == 4)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.state == .running)
}

@Test func titleCappingAt80Characters() throws {
  let parser = ClaudeTranscriptParser()
  let shortTitle = "Short title within eighty characters"
  #expect(ClaudeTranscriptParser.sanitizeTitle(shortTitle) == shortTitle)

  let longTitle = String(repeating: "A", count: 120)
  let capped = ClaudeTranscriptParser.sanitizeTitle(longTitle)
  #expect(capped.count == 80)
  #expect(capped == String(repeating: "A", count: 80))

  let line = makeLine(
    "{\"type\":\"custom-title\",\"sessionId\":\"sess-12\","
      + "\"customTitle\":\"\(longTitle)\",\"timestamp\":\"2026-11-07T12:00:00.000Z\"}"
  )
  let result = parser.parse([line], current: nil, now: referenceDate)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.title == String(repeating: "A", count: 80))
}

@Test func projectNameExtractionFromCwd() throws {
  let clean1 = ClaudeTranscriptParser.extractProjectName(from: "/Users/alice/projects/hutchbar")
  #expect(clean1 == "hutchbar")
  let clean2 = ClaudeTranscriptParser.extractProjectName(from: "/Users/alice/projects/hutchbar/")
  #expect(clean2 == "hutchbar")
  let clean3 = ClaudeTranscriptParser.extractProjectName(from: "hutchbar")
  #expect(clean3 == "hutchbar")
  let clean4 = ClaudeTranscriptParser.extractProjectName(from: "///deep/nested/hutchbar///")
  #expect(clean4 == "hutchbar")
  #expect(ClaudeTranscriptParser.extractProjectName(from: "/") == "")
  #expect(ClaudeTranscriptParser.extractProjectName(from: "") == "")

  let parser = ClaudeTranscriptParser()
  let line = makeLine(
    "{\"type\":\"user\",\"sessionId\":\"sess-13\",\"cwd\":\"/deep/nested/path/target-tool/\","
      + "\"timestamp\":\"2026-11-07T12:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"test\"}}"
  )
  let result = parser.parse([line], current: nil, now: referenceDate)
  let snapshot = try #require(result.snapshot)
  #expect(snapshot.projectName == "target-tool")
}

@Test func sidechainRecordsDoNotChangeState() throws {
  let parser = ClaudeTranscriptParser()
  let initial = SessionSnapshot(
    id: "sess-14",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "mu",
    lastActivity: referenceDate,
    waitingSince: referenceDate
  )
  let nextDate = referenceDate.addingTimeInterval(12)
  let lines = [
    makeLine(
      "{\"type\":\"user\",\"isSidechain\":true,\"sessionId\":\"sess-14\","
        + "\"timestamp\":\"2026-11-07T12:00:10.000Z\","
        + "\"message\":{\"role\":\"user\",\"content\":\"subagent prompt\"}}"
    ),
    makeLine(
      "{\"type\":\"assistant\",\"isSidechain\":true,\"sessionId\":\"sess-14\","
        + "\"timestamp\":\"2026-11-07T12:00:12.000Z\","
        + "\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\"}}"
    ),
  ]
  let result = parser.parse(lines, current: initial, now: nextDate)
  let snapshot = try #require(result.snapshot)
  #expect(result.skippedLines == 0)
  #expect(snapshot.state == .waitingForInput)
  #expect(snapshot.waitingSince == referenceDate)
  #expect(snapshot.lastActivity == nextDate)
}

@Test func inactivityRuleTransitionsToFinished() throws {
  var snapshot = SessionSnapshot(
    id: "sess-15",
    agent: .claudeCode,
    state: .running,
    projectName: "nu",
    lastActivity: referenceDate,
    waitingSince: nil
  )

  let activeNow = referenceDate.addingTimeInterval(29 * 60)
  snapshot.applyInactivity(now: activeNow)
  #expect(snapshot.state == .running)

  let inactiveNow = referenceDate.addingTimeInterval(30 * 60)
  snapshot.applyInactivity(now: inactiveNow)
  #expect(snapshot.state == .finished)
  #expect(snapshot.waitingSince == nil)

  let waitingSnapshot = SessionSnapshot(
    id: "sess-16",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "xi",
    lastActivity: referenceDate,
    waitingSince: referenceDate
  )
  let finished = ClaudeTranscriptParser.applyInactivity(to: waitingSnapshot, now: inactiveNow)
  let unwrappedFinished = try #require(finished)
  #expect(unwrappedFinished.state == .finished)
  #expect(unwrappedFinished.waitingSince == nil)

  let parser = ClaudeTranscriptParser()
  let result = parser.parse([], current: waitingSnapshot, now: inactiveNow)
  let parsedSnapshot = try #require(result.snapshot)
  #expect(parsedSnapshot.state == .finished)
}

@Test func privacyRulesEnforcedNeverLeakLogsOrSecrets() throws {
  let secretPrompt = "SUPER_SECRET_PROMPT_WITH_API_KEY_9999"
  let secretToolOutput = "SECRET_DATABASE_PASSWORD_IN_TOOL_OUTPUT"
  let secretPathPrefix = "/Volumes/EncryptedDisk/private-team"

  let json =
    "{\"type\":\"user\",\"sessionId\":\"sess-priv\","
    + "\"cwd\":\"\(secretPathPrefix)/secret-proj\","
    + "\"timestamp\":\"2026-11-07T12:00:00.000Z\","
    + "\"toolUseResult\":{\"data\":\"\(secretToolOutput)\"},"
    + "\"lastPrompt\":\"\(secretPrompt)\","
    + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(secretPrompt)\"}]}}"
  let line = makeLine(json)
  let parser = ClaudeTranscriptParser()
  let result = parser.parse([line], current: nil, now: referenceDate)
  let snapshot = try #require(result.snapshot)

  #expect(snapshot.projectName == "secret-proj")

  for secret in [secretPrompt, secretToolOutput, secretPathPrefix] {
    #expect(!snapshot.projectName.contains(secret))
    #expect(!String(describing: snapshot).contains(secret))
    #expect(!String(reflecting: snapshot).contains(secret))
    #expect(!String(describing: parser).contains(secret))
    #expect(!String(reflecting: parser).contains(secret))

    var dumpedSnapshot = ""
    dump(snapshot, to: &dumpedSnapshot)
    #expect(!dumpedSnapshot.contains(secret))

    var dumpedParser = ""
    dump(parser, to: &dumpedParser)
    #expect(!dumpedParser.contains(secret))
  }
}

@Test func fixtureParsingAndPrivacy() throws {
  let lines = [
    makeLine(
      "{\"type\":\"queue-operation\",\"timestamp\":\"2026-11-07T12:00:00.000Z\",\"sessionId\":\"sess-syn\"}"
    ),
    makeLine(
      "{\"type\":\"user\",\"sessionId\":\"sess-syn\",\"cwd\":\"/private/sec/secret-proj\","
        + "\"timestamp\":\"2026-11-07T12:00:01.000Z\","
        + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"SECRET_USER_PROMPT_1\"}]}}"
    ),
    makeLine(
      "{\"type\":\"assistant\",\"sessionId\":\"sess-syn\",\"cwd\":\"/private/sec/secret-proj\","
        + "\"timestamp\":\"2026-11-07T12:00:05.000Z\","
        + "\"message\":{\"role\":\"assistant\",\"stop_reason\":\"tool_use\"}}"
    ),
    makeLine(
      "{\"type\":\"user\",\"sessionId\":\"sess-syn\",\"timestamp\":\"2026-11-07T12:00:08.000Z\","
        + "\"toolUseResult\":{\"out\":\"SECRET_TOOL_OUT\"},"
        + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\"}]}}"
    ),
    makeLine(
      "{\"type\":\"assistant\",\"sessionId\":\"sess-syn\",\"cwd\":\"/private/sec/secret-proj\","
        + "\"timestamp\":\"2026-11-07T12:00:15.000Z\","
        + "\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\"}}"
    ),
    makeLine(
      "{\"type\":\"system\",\"subtype\":\"turn_duration\","
        + "\"timestamp\":\"2026-11-07T12:00:16.000Z\",\"sessionId\":\"sess-syn\"}"
    ),
    makeLine(
      "{\"type\":\"custom-title\",\"sessionId\":\"sess-syn\",\"customTitle\":\"Synthetic Clean Title\","
        + "\"timestamp\":\"2026-11-07T12:00:20.000Z\"}"
    ),
  ]

  let parser = ClaudeTranscriptParser()
  let result = parser.parse(lines, current: nil, now: referenceDate.addingTimeInterval(30))
  let snapshot = try #require(result.snapshot)

  #expect(result.skippedLines == 0)
  #expect(snapshot.id == "sess-syn")
  #expect(snapshot.projectName == "secret-proj")
  #expect(snapshot.title == "Synthetic Clean Title")
  #expect(snapshot.state == .waitingForInput)

  let secrets = ["SECRET_USER_PROMPT_1", "SECRET_TOOL_OUT", "/private/sec"]
  for secret in secrets {
    #expect(!snapshot.projectName.contains(secret))
    #expect(!String(describing: snapshot).contains(secret))
    #expect(!String(reflecting: snapshot).contains(secret))
    var dumped = ""
    dump(snapshot, to: &dumped)
    #expect(!dumped.contains(secret))
  }
}
