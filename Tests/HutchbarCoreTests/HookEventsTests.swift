// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing

@testable import HutchbarCore

private let fixedDate: Date = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: "2026-11-07T20:00:00Z") ?? Date(timeIntervalSince1970: 1_794_081_600)
}()

@Test func mappingAllHookEventsFromSpec() throws {
  let approvalData = Data(HookSyntheticFixtures.permissionPromptNotification.utf8)
  let approvalEvent = try #require(makeHookEvent(stdin: approvalData, now: fixedDate))
  #expect(approvalEvent.session == "sess-hook-001")
  #expect(approvalEvent.kind == .approval)
  #expect(approvalEvent.ts == fixedDate)

  let idleData = Data(HookSyntheticFixtures.idlePromptNotification.utf8)
  let idleEvent = try #require(makeHookEvent(stdin: idleData, now: fixedDate))
  #expect(idleEvent.session == "sess-hook-002")
  #expect(idleEvent.kind == .idle)
  #expect(idleEvent.ts == fixedDate)

  let stopData = Data(HookSyntheticFixtures.stopHook.utf8)
  let stopEvent = try #require(makeHookEvent(stdin: stopData, now: fixedDate))
  #expect(stopEvent.session == "sess-hook-003")
  #expect(stopEvent.kind == .stop)

  let promptData = Data(HookSyntheticFixtures.userPromptSubmitHook.utf8)
  let promptEvent = try #require(makeHookEvent(stdin: promptData, now: fixedDate))
  #expect(promptEvent.session == "sess-hook-004")
  #expect(promptEvent.kind == .prompt)

  let endData = Data(HookSyntheticFixtures.sessionEndHook.utf8)
  let endEvent = try #require(makeHookEvent(stdin: endData, now: fixedDate))
  #expect(endEvent.session == "sess-hook-005")
  #expect(endEvent.kind == .end)
}

@Test func mappingInvalidAndUnknownEvents() throws {
  let unknownNotification = """
    {"session_id":"s1","hook_event_name":"Notification","notification_type":"other_type"}
    """
  #expect(makeHookEvent(stdin: Data(unknownNotification.utf8), now: fixedDate) == nil)

  let missingNotificationType = """
    {"session_id":"s1","hook_event_name":"Notification"}
    """
  #expect(makeHookEvent(stdin: Data(missingNotificationType.utf8), now: fixedDate) == nil)

  let unknownEvent = """
    {"session_id":"s1","hook_event_name":"PreToolUse"}
    """
  #expect(makeHookEvent(stdin: Data(unknownEvent.utf8), now: fixedDate) == nil)

  let missingSession = """
    {"hook_event_name":"Stop"}
    """
  #expect(makeHookEvent(stdin: Data(missingSession.utf8), now: fixedDate) == nil)

  let emptySession = """
    {"session_id":"","hook_event_name":"Stop"}
    """
  #expect(makeHookEvent(stdin: Data(emptySession.utf8), now: fixedDate) == nil)

  let whitespaceSession = """
    {"session_id":"   ","hook_event_name":"Stop"}
    """
  #expect(makeHookEvent(stdin: Data(whitespaceSession.utf8), now: fixedDate) == nil)

  #expect(makeHookEvent(stdin: Data(), now: fixedDate) == nil)
  #expect(makeHookEvent(stdin: Data("not valid json".utf8), now: fixedDate) == nil)
}

@Test func sixtyFourKiBLimitEnforced() throws {
  let baseJson = "{\"session_id\":\"sess-limit\",\"hook_event_name\":\"Stop\""
  let closing = "}"
  let requiredPadding = 65_536 - baseJson.utf8.count - closing.utf8.count
  let validPadded = baseJson + String(repeating: " ", count: requiredPadding) + closing
  let validData = Data(validPadded.utf8)
  #expect(validData.count == 65_536)
  let parsed = try #require(makeHookEvent(stdin: validData, now: fixedDate))
  #expect(parsed.session == "sess-limit")
  #expect(parsed.kind == .stop)

  let oversizePadded = validPadded + " "
  let oversizeData = Data(oversizePadded.utf8)
  #expect(oversizeData.count == 65_537)
  #expect(makeHookEvent(stdin: oversizeData, now: fixedDate) == nil)

  let hugeData = Data(repeating: 0x20, count: 100_000)
  #expect(makeHookEvent(stdin: hugeData, now: fixedDate) == nil)
}

@Test func encodeProducesSingleLineFormatAndRoundTrips() throws {
  let event = HookEvent(ts: fixedDate, session: "sess-abc", kind: .approval)
  let data = encode(event)
  let string = String(decoding: data, as: UTF8.self)

  #expect(
    string
      == "{\"v\":1,\"ts\":\"2026-11-07T20:00:00Z\",\"session\":\"sess-abc\",\"event\":\"approval\"}"
  )
  #expect(!string.contains("\n"))

  let line = JSONLLine(bytes: data)
  let decoded = try #require(parseHookEventLine(line))
  #expect(decoded == event)

  for kind in HookEventKind.allCases {
    let evt = HookEvent(ts: fixedDate, session: "s-\(kind.rawValue)", kind: kind)
    let encodedLine = JSONLLine(bytes: encode(evt))
    let roundtripped = try #require(parseHookEventLine(encodedLine))
    #expect(roundtripped == evt)
  }
}

@Test func parseHookEventLineRejectsInvalidPayloads() throws {
  let invalidVersion = JSONLLine(
    bytes: Data(
      "{\"v\":2,\"ts\":\"2026-11-07T20:00:00Z\",\"session\":\"s1\",\"event\":\"stop\"}".utf8))
  #expect(parseHookEventLine(invalidVersion) == nil)

  let missingVersion = JSONLLine(
    bytes: Data("{\"ts\":\"2026-11-07T20:00:00Z\",\"session\":\"s1\",\"event\":\"stop\"}".utf8))
  #expect(parseHookEventLine(missingVersion) == nil)

  let badDate = JSONLLine(
    bytes: Data("{\"v\":1,\"ts\":\"not-a-date\",\"session\":\"s1\",\"event\":\"stop\"}".utf8))
  #expect(parseHookEventLine(badDate) == nil)

  let unknownEvent = JSONLLine(
    bytes: Data(
      "{\"v\":1,\"ts\":\"2026-11-07T20:00:00Z\",\"session\":\"s1\",\"event\":\"alien\"}".utf8))
  #expect(parseHookEventLine(unknownEvent) == nil)

  let emptySession = JSONLLine(
    bytes: Data(
      "{\"v\":1,\"ts\":\"2026-11-07T20:00:00Z\",\"session\":\"\",\"event\":\"stop\"}".utf8))
  #expect(parseHookEventLine(emptySession) == nil)

  #expect(parseHookEventLine(JSONLLine(bytes: Data())) == nil)
}

@Test func snapshotMergeRuleAllTransitions() throws {
  let baseSnapshot = SessionSnapshot(
    id: "sess-merge",
    agent: .claudeCode,
    state: .running,
    projectName: "my-project",
    title: "Feature",
    lastActivity: fixedDate,
    waitingSince: nil
  )

  let olderDate = fixedDate.addingTimeInterval(-10)
  let olderEvent = HookEvent(ts: olderDate, session: "sess-merge", kind: .end)
  let ignoredResult = apply(olderEvent, to: baseSnapshot)
  #expect(ignoredResult == baseSnapshot)

  let approvalDate = fixedDate.addingTimeInterval(5)
  let approvalEvent = HookEvent(ts: approvalDate, session: "sess-merge", kind: .approval)
  let approvalResult = apply(approvalEvent, to: baseSnapshot)
  #expect(approvalResult.state == .waitingForApproval)
  #expect(approvalResult.waitingSince == approvalDate)
  #expect(approvalResult.lastActivity == approvalDate)

  let idleDate = approvalDate.addingTimeInterval(5)
  let idleEvent = HookEvent(ts: idleDate, session: "sess-merge", kind: .idle)
  let idleResult = apply(idleEvent, to: approvalResult)
  #expect(idleResult.state == .waitingForInput)
  #expect(idleResult.waitingSince == idleDate)
  #expect(idleResult.lastActivity == idleDate)

  let laterIdleDate = idleDate.addingTimeInterval(5)
  let laterIdleEvent = HookEvent(ts: laterIdleDate, session: "sess-merge", kind: .idle)
  let laterIdleResult = apply(laterIdleEvent, to: idleResult)
  #expect(laterIdleResult.state == .waitingForInput)
  #expect(laterIdleResult.waitingSince == idleDate)
  #expect(laterIdleResult.lastActivity == laterIdleDate)

  let promptDate = laterIdleDate.addingTimeInterval(5)
  let promptEvent = HookEvent(ts: promptDate, session: "sess-merge", kind: .prompt)
  let promptResult = apply(promptEvent, to: laterIdleResult)
  #expect(promptResult.state == .running)
  #expect(promptResult.waitingSince == nil)
  #expect(promptResult.lastActivity == promptDate)

  let stopDate = promptDate.addingTimeInterval(5)
  let stopEvent = HookEvent(ts: stopDate, session: "sess-merge", kind: .stop)
  let stopResult = apply(stopEvent, to: promptResult)
  #expect(stopResult.state == .waitingForInput)
  #expect(stopResult.waitingSince == stopDate)
  #expect(stopResult.lastActivity == stopDate)

  let endDate = stopDate.addingTimeInterval(5)
  let endEvent = HookEvent(ts: endDate, session: "sess-merge", kind: .end)
  let endResult = apply(endEvent, to: stopResult)
  #expect(endResult.state == .finished)
  #expect(endResult.waitingSince == nil)
  #expect(endResult.lastActivity == endDate)
}

@Test func hookEventWriterDirectoryAndFilePermissions() throws {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? fileManager.removeItem(at: tempRoot) }

  let targetDir = tempRoot.appendingPathComponent("subfolder")
  let targetFile = targetDir.appendingPathComponent("events.jsonl")

  let event = HookEvent(ts: fixedDate, session: "sess-write", kind: .stop)
  let success = HookEventWriter.write(event: event, to: targetFile.path)
  #expect(success)

  var dirStat = stat()
  #expect(lstat(targetDir.path, &dirStat) == 0)
  #expect((dirStat.st_mode & S_IFMT) == S_IFDIR)
  #expect((dirStat.st_mode & 0o777) == 0o700)

  var fileStat = stat()
  #expect(stat(targetFile.path, &fileStat) == 0)
  #expect((fileStat.st_mode & S_IFMT) == S_IFREG)
  #expect((fileStat.st_mode & 0o777) == 0o600)

  let writtenData = try Data(contentsOf: targetFile)
  let writtenString = String(decoding: writtenData, as: UTF8.self)
  #expect(writtenString.hasSuffix("\n"))
  let trimmed = writtenString.trimmingCharacters(in: .newlines)
  let parsed = try #require(parseHookEventLine(JSONLLine(bytes: Data(trimmed.utf8))))
  #expect(parsed == event)
}

@Test func hookEventWriterTruncatesOversizeFile() throws {
  let fileManager = FileManager.default
  let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? fileManager.removeItem(at: tempDir) }

  let targetFile = tempDir.appendingPathComponent("events.jsonl")
  try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

  let oversizeCount = 1_048_577
  let largeData = Data(repeating: 0x41, count: oversizeCount)
  try largeData.write(to: targetFile)

  var initialStat = stat()
  #expect(stat(targetFile.path, &initialStat) == 0)
  #expect(initialStat.st_size == off_t(oversizeCount))

  let event = HookEvent(ts: fixedDate, session: "sess-trunc", kind: .prompt)
  let success = HookEventWriter.write(event: event, to: targetFile.path)
  #expect(success)

  var postStat = stat()
  #expect(stat(targetFile.path, &postStat) == 0)
  #expect(postStat.st_size < 200)

  let contents = try Data(contentsOf: targetFile)
  let line = String(decoding: contents, as: UTF8.self).trimmingCharacters(in: .newlines)
  let parsed = try #require(parseHookEventLine(JSONLLine(bytes: Data(line.utf8))))
  #expect(parsed == event)

  let secondEvent = HookEvent(
    ts: fixedDate.addingTimeInterval(1), session: "sess-trunc", kind: .stop)
  let secondSuccess = HookEventWriter.write(event: secondEvent, to: targetFile.path)
  #expect(secondSuccess)

  var appendedStat = stat()
  #expect(stat(targetFile.path, &appendedStat) == 0)
  #expect(appendedStat.st_size > postStat.st_size)
}

@Test func hookEventWriterRejectsSymlinkTarget() throws {
  let fileManager = FileManager.default
  let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? fileManager.removeItem(at: tempDir) }

  try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
  let realFile = tempDir.appendingPathComponent("real.jsonl")
  let initialContent = "EXISTING_LINE\n"
  try initialContent.write(to: realFile, atomically: true, encoding: .utf8)

  let symlinkFile = tempDir.appendingPathComponent("symlink.jsonl")
  try fileManager.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

  let event = HookEvent(ts: fixedDate, session: "sess-symlink", kind: .approval)
  let success = HookEventWriter.write(event: event, to: symlinkFile.path)
  #expect(!success)

  let contentAfter = try String(contentsOf: realFile, encoding: .utf8)
  #expect(contentAfter == initialContent)
}

@Test func hookEventPrivacyRulesEnforcedNeverLeakLogsOrSecrets() throws {
  let stdinData = Data(HookSyntheticFixtures.permissionPromptNotification.utf8)
  let event = try #require(makeHookEvent(stdin: stdinData, now: fixedDate))
  let encoded = encode(event)
  let encodedString = String(decoding: encoded, as: UTF8.self)
  let writer = HookEventWriter()

  let sensitiveTokens = [
    HookSyntheticFixtures.secretPrompt,
    HookSyntheticFixtures.secretToolOutput,
    HookSyntheticFixtures.secretPath,
    HookSyntheticFixtures.secretApiKey,
  ]

  let stringRepresentations = [
    encodedString,
    String(describing: event),
    String(reflecting: event),
    event.description,
    event.debugDescription,
    String(describing: writer),
    String(reflecting: writer),
    writer.description,
    writer.debugDescription,
  ]

  for representation in stringRepresentations {
    for secret in sensitiveTokens {
      #expect(!representation.contains(secret))
    }
  }

  var dumpedEvent = ""
  dump(event, to: &dumpedEvent)
  var dumpedWriter = ""
  dump(writer, to: &dumpedWriter)

  for secret in sensitiveTokens {
    #expect(!dumpedEvent.contains(secret))
    #expect(!dumpedWriter.contains(secret))
  }
}

@Test func hooksConfigurationSnippetValidAndAccurate() throws {
  let binary = "/Applications/Hutchbar.app/Contents/MacOS/hutchbar"
  let snippetString = generateHooksConfiguration(binaryPath: binary)

  let data = Data(snippetString.utf8)
  let snippet = try JSONDecoder().decode(ClaudeHooksSnippet.self, from: data)

  let notifEntries = snippet.hooks.notification
  #expect(notifEntries.count == 1)
  let notif = notifEntries[0]
  #expect(notif.matcher == "permission_prompt|idle_prompt")
  #expect(notif.hooks.count == 1)
  #expect(notif.hooks[0].type == "command")
  #expect(notif.hooks[0].command == "'\(binary)' --hook")

  let stopEntries = snippet.hooks.stop
  #expect(stopEntries.count == 1)
  #expect(stopEntries[0].matcher == nil)
  #expect(stopEntries[0].hooks[0].command == "'\(binary)' --hook")

  let submitEntries = snippet.hooks.userPromptSubmit
  #expect(submitEntries.count == 1)
  #expect(submitEntries[0].hooks[0].command == "'\(binary)' --hook")

  let endEntries = snippet.hooks.sessionEnd
  #expect(endEntries.count == 1)
  #expect(endEntries[0].hooks[0].command == "'\(binary)' --hook")
}

@Test func unsafeSessionIdentifiersAreRejected() throws {
  for bad in ["", "a b", "x\ny", "../../etc", String(repeating: "a", count: 129), "s\"; rm -rf ~"] {
    let encoded = try #require(String(data: try JSONEncoder().encode(bad), encoding: .utf8))
    let input = #"{"session_id":"# + encoded + #","hook_event_name":"Stop"}"#
    #expect(makeHookEvent(stdin: Data(input.utf8)) == nil, "accepted \(bad.count) chars")
  }
  #expect(
    makeHookEvent(stdin: Data(#"{"session_id":"0a1b-2C_3","hook_event_name":"Stop"}"#.utf8)) != nil)
}

@Test func hooksSnippetQuotesBinaryPath() {
  let snippet = generateHooksConfiguration(
    binaryPath: "/Applications/Hutchbar Dev.app/Contents/MacOS/it's")
  // JSON escapes the backslash of the shell quote sequence '\''.
  #expect(snippet.contains(#"'/Applications/Hutchbar Dev.app/Contents/MacOS/it'\\''s' --hook"#))
}
