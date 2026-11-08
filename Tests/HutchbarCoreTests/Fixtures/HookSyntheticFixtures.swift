// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@testable import HutchbarCore

enum HookSyntheticFixtures {
  static let secretPrompt = "SUPER-SECRET-USER-PROMPT-7777"
  static let secretToolOutput = "SECRET-DATABASE-PASSWORD-9999"
  static let secretPath = "/Volumes/EncryptedDisk/private-team/project"
  static let secretApiKey = "SK-SECRET-API-KEY-DO-NOT-LEAK"

  static let permissionPromptNotification = """
    {
      "session_id": "sess-hook-001",
      "cwd": "\(secretPath)",
      "hook_event_name": "Notification",
      "notification_type": "permission_prompt",
      "message": { "content": "\(secretPrompt)" },
      "toolUseResult": "\(secretToolOutput)",
      "apiKey": "\(secretApiKey)"
    }
    """

  static let idlePromptNotification = """
    {
      "session_id": "sess-hook-002",
      "cwd": "\(secretPath)",
      "hook_event_name": "Notification",
      "notification_type": "idle_prompt",
      "message": { "content": "\(secretPrompt)" }
    }
    """

  static let stopHook = """
    {
      "session_id": "sess-hook-003",
      "cwd": "\(secretPath)",
      "hook_event_name": "Stop"
    }
    """

  static let userPromptSubmitHook = """
    {
      "session_id": "sess-hook-004",
      "cwd": "\(secretPath)",
      "hook_event_name": "UserPromptSubmit",
      "lastPrompt": "\(secretPrompt)"
    }
    """

  static let sessionEndHook = """
    {
      "session_id": "sess-hook-005",
      "cwd": "\(secretPath)",
      "hook_event_name": "SessionEnd"
    }
    """
}
