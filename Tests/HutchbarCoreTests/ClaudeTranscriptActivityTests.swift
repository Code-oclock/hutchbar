// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func activityLine(_ string: String) -> JSONLLine {
  JSONLLine(bytes: Data(string.utf8))
}

@Test func recordsWithoutTimestampNeverUseNowAsActivity() throws {
  // Real transcripts start with timestamp-less records such as custom-title.
  let lines = [
    activityLine(#"{"type":"custom-title","customTitle":"t","sessionId":"s-ts"}"#),
    activityLine(
      #"{"type":"assistant","sessionId":"s-ts","cwd":"/a/b","timestamp":"2026-11-07T10:00:00.000Z","#
        + #""message":{"role":"assistant","stop_reason":"end_turn"}}"#
    ),
  ]
  let now = try #require(ClaudeTranscriptParser.parseISO8601Date("2026-11-07T18:00:00.000Z"))
  let result = ClaudeTranscriptParser().parse(lines, current: nil, now: now)
  let snapshot = try #require(result.snapshot)
  let expected = try #require(ClaudeTranscriptParser.parseISO8601Date("2026-11-07T10:00:00.000Z"))
  #expect(snapshot.lastActivity == expected)
  #expect(snapshot.lastActivity != now)
}
