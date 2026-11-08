// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import HutchbarCore

enum CodexSyntheticFixtures {
  static let secretPrompt = "SUPER-SECRET-PROMPT-12345-DO-NOT-LEAK"
  static let secretCode = "func sensitiveAlgorithm() { return 42; }"
  static let secretToken = "FAKE-SECRET-TOKEN-DO-NOT-LEAK-12345"
  static let secretPath = "/Users/alice/super-secret-vault/my-project"

  static func line(_ string: String) -> JSONLLine {
    JSONLLine(bytes: Data(string.utf8))
  }

  static let validSessionMeta = """
    {"type":"session_meta","timestamp":"2026-11-07T12:00:00Z",\
    "payload":{"id":"session-uuid-001","cwd":"/Users/developer/projects/sample-app",\
    "timestamp":"2026-11-07T12:00:00Z"}}
    """

  static let sessionMetaFallbackId = """
    {"type":"session_meta","timestamp":"2026-11-07T12:00:00Z",\
    "payload":{"session_id":"session-fallback-999","cwd":"/work/backend"}}
    """

  static let validTurnContext = """
    {"type":"turn_context","timestamp":"2026-11-07T12:01:00Z",\
    "payload":{"cwd":"/Users/developer/projects/sample-app-renamed"}}
    """

  static let taskStarted = """
    {"type":"event_msg","timestamp":"2026-11-07T12:05:00Z",\
    "payload":{"type":"task_started"}}
    """

  static let taskComplete = """
    {"type":"event_msg","timestamp":"2026-11-07T12:15:00Z",\
    "payload":{"type":"task_complete"}}
    """

  static let tokenCountFull = """
    {"type":"event_msg","timestamp":"2026-11-07T12:10:00Z",\
    "payload":{"type":"token_count","rate_limits":{"plan_type":"pro",\
    "primary":{"used_percent":25.5,"window_minutes":300,"resets_at":1762512000},\
    "secondary":{"used_percent":80.0,"window_minutes":10080,"resets_at":1762800000}}}}
    """

  static let tokenCountWithNulls = """
    {"type":"event_msg","timestamp":"2026-11-07T12:10:00Z",\
    "payload":{"type":"token_count","rate_limits":{"plan_type":null,\
    "primary":{"used_percent":null,"window_minutes":null,"resets_at":null},\
    "secondary":null}}}
    """

  static let privacySensitiveFixture = """
    {"type":"session_meta","timestamp":"2026-11-07T12:00:00Z",\
    "last_agent_message":"\(secretPrompt)",\
    "content":"\(secretCode)",\
    "payload":{"id":"session-privacy-123","cwd":"\(secretPath)",\
    "content":"\(secretToken)","last_agent_message":"\(secretPrompt)"}}
    """
}
