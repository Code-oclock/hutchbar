// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func geminiSessionParserMakeData(_ json: String) -> Data {
  Data(json.utf8)
}

private func geminiSessionParserDate(_ isoString: String) throws -> Date {
  try #require(GeminiSessionParser.parseDate(isoString))
}

@Suite("GeminiSessionParserTests")
struct GeminiSessionParserTests {
  @Test func geminiSessionUserStateTransitionsToRunning() throws {
    let now = try geminiSessionParserDate("2026-11-09T10:05:00.000Z")
    let json = """
      {
        "sessionId": "gem-sess-user",
        "lastUpdated": "2026-11-09T10:05:00.000Z",
        "messages": [
          {"id": "m1", "timestamp": "2026-11-09T10:05:00.000Z", "type": "user"}
        ]
      }
      """
    let project = GeminiProjectInfo(projectName: "project-a")
    let snapshot = try #require(
      GeminiSessionParser.parse(
        data: geminiSessionParserMakeData(json),
        filePath: "/tmp/chats/session-1.json",
        projectInfo: project,
        now: now
      )
    )

    #expect(snapshot.id == "gem-sess-user")
    #expect(snapshot.agent == .geminiCLI)
    #expect(snapshot.state == .running)
    #expect(snapshot.waitingSince == nil)
    #expect(snapshot.lastActivity == now)
    #expect(snapshot.projectName == "project-a")
  }

  @Test func geminiSessionAwaitingApprovalToolCallTransitionsToWaitingForApproval() throws {
    let msgDate = try geminiSessionParserDate("2026-11-09T10:03:00.000Z")
    let now = try geminiSessionParserDate("2026-11-09T10:03:10.000Z")
    let json = """
      {
        "sessionId": "gem-sess-approval",
        "messages": [
          {
            "id": "m1",
            "timestamp": "2026-11-09T10:03:00.000Z",
            "type": "gemini",
            "toolCalls": [
              {"status": "awaiting_approval"}
            ]
          }
        ]
      }
      """
    let project = GeminiProjectInfo(projectName: "project-b")
    let snapshot = try #require(
      GeminiSessionParser.parse(
        data: geminiSessionParserMakeData(json),
        filePath: "/tmp/chats/session-2.json",
        projectInfo: project,
        now: now
      )
    )

    #expect(snapshot.state == .waitingForApproval)
    #expect(snapshot.waitingSince == msgDate)
    #expect(snapshot.lastActivity == msgDate)
  }

  @Test func geminiSessionValidatingScheduledExecutingTransitionsToRunning() throws {
    let now = try geminiSessionParserDate("2026-11-09T10:04:00.000Z")
    let project = GeminiProjectInfo(projectName: "project-c")

    for status in ["validating", "scheduled", "executing"] {
      let json = """
        {
          "sessionId": "gem-sess-\(status)",
          "messages": [
            {
              "id": "m1",
              "timestamp": "2026-11-09T10:04:00.000Z",
              "type": "gemini",
              "toolCalls": [{"status": "\(status)"}]
            }
          ]
        }
        """
      let snapshot = try #require(
        GeminiSessionParser.parse(
          data: geminiSessionParserMakeData(json),
          filePath: "/tmp/chats/session-\(status).json",
          projectInfo: project,
          now: now
        )
      )
      #expect(snapshot.state == .running)
      #expect(snapshot.waitingSince == nil)
    }
  }

  @Test func geminiSessionAwaitingApprovalTakesPrecedenceOverExecuting() throws {
    let msgDate = try geminiSessionParserDate("2026-11-09T10:02:00.000Z")
    let now = try geminiSessionParserDate("2026-11-09T10:02:05.000Z")
    let json = """
      {
        "sessionId": "gem-sess-priority",
        "messages": [
          {
            "id": "m1",
            "timestamp": "2026-11-09T10:02:00.000Z",
            "type": "gemini",
            "toolCalls": [
              {"status": "executing"},
              {"status": "awaiting_approval"}
            ]
          }
        ]
      }
      """
    let snapshot = try #require(
      GeminiSessionParser.parse(
        data: geminiSessionParserMakeData(json),
        filePath: "/tmp/chats/session-priority.json",
        projectInfo: GeminiProjectInfo(projectName: "priority-proj"),
        now: now
      )
    )
    #expect(snapshot.state == .waitingForApproval)
    #expect(snapshot.waitingSince == msgDate)
  }

  @Test func geminiSessionCompletedToolCallsTransitionsToWaitingForInput() throws {
    let msgDate = try geminiSessionParserDate("2026-11-09T10:01:00.000Z")
    let now = try geminiSessionParserDate("2026-11-09T10:01:30.000Z")
    let project = GeminiProjectInfo(projectName: "project-d")

    for status in ["success", "error", "cancelled"] {
      let json = """
        {
          "sessionId": "gem-sess-\(status)",
          "messages": [
            {
              "id": "m1",
              "timestamp": "2026-11-09T10:01:00.000Z",
              "type": "gemini",
              "toolCalls": [{"status": "\(status)"}]
            }
          ]
        }
        """
      let snapshot = try #require(
        GeminiSessionParser.parse(
          data: geminiSessionParserMakeData(json),
          filePath: "/tmp/chats/session-\(status).json",
          projectInfo: project,
          now: now
        )
      )
      #expect(snapshot.state == .waitingForInput)
      #expect(snapshot.waitingSince == msgDate)
    }
  }

  @Test func geminiSessionGeminiWithoutToolCallsTransitionsToWaitingForInput() throws {
    let msgDate = try geminiSessionParserDate("2026-11-09T10:00:00.000Z")
    let now = try geminiSessionParserDate("2026-11-09T10:00:10.000Z")
    let json = """
      {
        "sessionId": "gem-sess-no-tools",
        "messages": [
          {"id": "m1", "timestamp": "2026-11-09T10:00:00.000Z", "type": "gemini"}
        ]
      }
      """
    let snapshot = try #require(
      GeminiSessionParser.parse(
        data: geminiSessionParserMakeData(json),
        filePath: "/tmp/chats/session-no-tools.json",
        projectInfo: GeminiProjectInfo(projectName: "no-tools"),
        now: now
      )
    )
    #expect(snapshot.state == .waitingForInput)
    #expect(snapshot.waitingSince == msgDate)
  }

  @Test func geminiSessionInfoErrorWarningTransitionsToWaitingForInput() throws {
    let msgDate = try geminiSessionParserDate("2026-11-09T09:50:00.000Z")
    let now = try geminiSessionParserDate("2026-11-09T09:50:15.000Z")
    let project = GeminiProjectInfo(projectName: "project-misc")

    for msgType in ["info", "error", "warning"] {
      let json = """
        {
          "sessionId": "gem-sess-\(msgType)",
          "messages": [
            {"id": "m1", "timestamp": "2026-11-09T09:50:00.000Z", "type": "\(msgType)"}
          ]
        }
        """
      let snapshot = try #require(
        GeminiSessionParser.parse(
          data: geminiSessionParserMakeData(json),
          filePath: "/tmp/chats/session-\(msgType).json",
          projectInfo: project,
          now: now
        )
      )
      #expect(snapshot.state == .waitingForInput)
      #expect(snapshot.waitingSince == msgDate)
    }
  }

  @Test func geminiSessionNoMessagesTransitionsToWaitingForInputFromStartTime() throws {
    let startDate = try geminiSessionParserDate("2026-11-09T08:00:00.000Z")
    let now = try geminiSessionParserDate("2026-11-09T08:05:00.000Z")
    let json = """
      {
        "sessionId": "gem-sess-empty",
        "startTime": "2026-11-09T08:00:00.000Z",
        "messages": []
      }
      """
    let snapshot = try #require(
      GeminiSessionParser.parse(
        data: geminiSessionParserMakeData(json),
        filePath: "/tmp/chats/session-empty.json",
        projectInfo: GeminiProjectInfo(projectName: "empty-proj"),
        now: now
      )
    )
    #expect(snapshot.state == .waitingForInput)
    #expect(snapshot.waitingSince == startDate)
  }

  @Test func geminiSessionMissingSessionIdUsesFilename() throws {
    let now = try geminiSessionParserDate("2026-11-09T10:00:00.000Z")
    let json = """
      {
        "messages": [
          {"id": "m1", "timestamp": "2026-11-09T10:00:00.000Z", "type": "user"}
        ]
      }
      """
    let snapshot = try #require(
      GeminiSessionParser.parse(
        data: geminiSessionParserMakeData(json),
        filePath: "/tmp/chats/session-abc-456.json",
        projectInfo: GeminiProjectInfo(projectName: "proj"),
        now: now
      )
    )
    #expect(snapshot.id == "session-abc-456")
  }

  @Test func geminiSessionCorruptedJSONYieldsNil() throws {
    let now = try geminiSessionParserDate("2026-11-09T10:00:00.000Z")
    let brokenData = geminiSessionParserMakeData("not-a-valid-json")
    let result = GeminiSessionParser.parse(
      data: brokenData,
      filePath: "/tmp/chats/session-broken.json",
      projectInfo: GeminiProjectInfo(projectName: "proj"),
      now: now
    )
    #expect(result == nil)
  }

  @Test func geminiSessionProjectResolution() {
    let rootContent = "/Users/developer/repos/frontend-service\n"
    let infoFromRoot = GeminiSessionParser.resolveProject(
      projectDirName: "64charhashorwhatever",
      projectRootContent: rootContent
    )
    #expect(infoFromRoot.projectName == "frontend-service")
    #expect(infoFromRoot.cwd == "/Users/developer/repos/frontend-service")

    let infoFromShort = GeminiSessionParser.resolveProject(
      projectDirName: "my-backend-app",
      projectRootContent: nil
    )
    #expect(infoFromShort.projectName == "my-backend-app")
    #expect(infoFromShort.cwd == nil)

    let hex64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    let infoFromHex = GeminiSessionParser.resolveProject(
      projectDirName: hex64,
      projectRootContent: nil
    )
    #expect(infoFromHex.projectName == "gemini")
    #expect(infoFromHex.cwd == nil)
  }

  @Test func geminiSessionInactivityRuleApplies() throws {
    let date0 = try geminiSessionParserDate("2026-11-09T10:00:00.000Z")
    let nowActive = try geminiSessionParserDate("2026-11-09T10:20:00.000Z")
    let nowInactive = try geminiSessionParserDate("2026-11-09T10:35:00.000Z")

    let activeSnapshot = SessionSnapshot(
      id: "sess-inact",
      agent: .geminiCLI,
      state: .waitingForInput,
      projectName: "sample",
      lastActivity: date0,
      waitingSince: date0
    )

    let stillActive = GeminiSessionParser.applyInactivityRule(to: activeSnapshot, now: nowActive)
    #expect(stillActive.state == .waitingForInput)
    #expect(stillActive.waitingSince == date0)

    let finished = GeminiSessionParser.applyInactivityRule(to: activeSnapshot, now: nowInactive)
    #expect(finished.state == .finished)
    #expect(finished.waitingSince == nil)
  }
}
