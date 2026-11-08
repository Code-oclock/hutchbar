// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

final class CodexProbeFakeFileSystem: CodexFileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var home: String
  private var uid: UInt32
  private var directoryListings: [String: [String]] = [:]
  private var existingFiles: Set<String> = []
  private var attributesTable: [String: CodexFileAttributes] = [:]

  init(home: String = "/Users/testuser", uid: UInt32 = 501) {
    self.home = home
    self.uid = uid
  }

  var homeDirectoryPath: String {
    lock.withLock { home }
  }

  var currentUID: UInt32 {
    lock.withLock { uid }
  }

  func registerDirectory(
    path: String,
    ownerUID: UInt32 = 501,
    posixMode: UInt16 = 0o700,
    hasAuthJson: Bool = true
  ) {
    lock.withLock {
      attributesTable[path] = CodexFileAttributes(
        ownerUID: ownerUID,
        posixMode: posixMode,
        isDirectory: true
      )
      if hasAuthJson {
        let authPath = (path as NSString).appendingPathComponent("auth.json")
        existingFiles.insert(authPath)
      }
    }
  }

  func setContentsOfDirectory(path: String, entries: [String]) {
    lock.withLock {
      directoryListings[path] = entries
    }
  }

  func contentsOfDirectory(atPath path: String) throws -> [String] {
    lock.withLock {
      directoryListings[path] ?? []
    }
  }

  func itemExists(atPath path: String) -> Bool {
    lock.withLock {
      existingFiles.contains(path) || attributesTable[path] != nil
    }
  }

  func posixAttributes(atPath path: String) throws -> CodexFileAttributes {
    try lock.withLock {
      guard let attrs = attributesTable[path] else {
        throw POSIXError(.ENOENT)
      }
      return attrs
    }
  }
}

enum CodexUsageProbeSyntheticFixtures {
  static let initializeResponse =
    "{\"id\":1,\"result\":{\"capabilities\":{}}}"

  static let accountReadResponse =
    "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\",\"email\":\"user@example.com\","
    + "\"planType\":\"plus\"},\"requiresOpenaiAuth\":true}}"

  static let rateLimitsReadResponse =
    "{\"id\":3,\"result\":{\"ordinaryUsageAllowed\":true,"
    + "\"rateLimits\":{\"limitId\":\"codex\","
    + "\"primary\":{\"usedPercent\":0,\"windowDurationMins\":300,\"resetsAt\":1794173082},"
    + "\"secondary\":{\"usedPercent\":53,\"windowDurationMins\":10080,\"resetsAt\":1794402027},"
    + "\"planType\":\"plus\"},"
    + "\"rateLimitsByLimitId\":{\"codex\":{\"limitId\":\"codex\","
    + "\"primary\":{\"usedPercent\":0,\"windowDurationMins\":300,\"resetsAt\":1794173082},"
    + "\"secondary\":{\"usedPercent\":53,\"windowDurationMins\":10080,\"resetsAt\":1794402027},"
    + "\"planType\":\"plus\"}},"
    + "\"rateLimitResetCredits\":{\"availableCount\":2,\"credits\":[]}}}"

  static let rateLimitsDirectOnlyResponse =
    "{\"id\":3,\"result\":{\"ordinaryUsageAllowed\":true,"
    + "\"rateLimits\":{\"limitId\":\"codex\","
    + "\"primary\":{\"usedPercent\":12,\"windowDurationMins\":300,\"resetsAt\":1794173082},"
    + "\"secondary\":{\"usedPercent\":45,\"windowDurationMins\":10080,\"resetsAt\":1794402027},"
    + "\"planType\":\"plus\"},"
    + "\"rateLimitResetCredits\":{\"availableCount\":1,\"credits\":[]}}}"

  static let rateLimitsPrimaryOnlyResponse =
    "{\"id\":3,\"result\":{\"ordinaryUsageAllowed\":true,"
    + "\"rateLimits\":{\"limitId\":\"codex\","
    + "\"primary\":{\"usedPercent\":20,\"windowDurationMins\":300,\"resetsAt\":1794173082},"
    + "\"planType\":\"team\"},"
    + "\"rateLimitResetCredits\":{\"availableCount\":0,\"credits\":[]}}}"

  static let accountApiKeyResponse =
    "{\"id\":2,\"result\":{\"account\":{\"type\":\"apiKey\",\"email\":\"api-key@example.com\","
    + "\"planType\":\"pro\"}}}"

  static let rateLimitsErrorResponse =
    "{\"id\":3,\"error\":{\"code\":-32603,\"message\":\"rate limit service unavailable\"}}"

  static let notifyAccountUpdated =
    "{\"method\":\"account/updated\",\"params\":{\"session\":\"xyz\"}}"

  static let notifyRemoteControl =
    "{\"method\":\"remoteControl/status/changed\",\"params\":{\"connected\":true}}"

  static let unrelatedIdResponse =
    "{\"id\":99,\"result\":{\"ignored\":true}}"
}

@Test func codexUsageProbe_fullSuccessfulConversation() async throws {
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [CodexUsageProbeSyntheticFixtures.accountReadResponse]
    ),
    .init(
      whenSentContains: "account/rateLimits/read",
      lines: [CodexUsageProbeSyntheticFixtures.rateLimitsReadResponse]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: replies)
  let probe = CodexUsageProbe(
    executable: "/usr/local/bin/codex",
    runner: runner,
    appVersion: "0.162.1"
  )
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)
  let fixedNow = Date(timeIntervalSince1970: 1_794_000_000)

  let result = await probe.read(profile, now: fixedNow)
  let quota = try #require(try? result.get())

  #expect(quota.agent == .codex)
  #expect(quota.accountName == "user")
  #expect(quota.source == .agentCLI)
  #expect(quota.plan == "plus")
  #expect(quota.resetCredits == 2)
  #expect(quota.observedAt == fixedNow)
  #expect(quota.windows.count == 2)

  let primary = try #require(quota.windows.first { $0.windowMinutes == 300 })
  #expect(primary.usedPercent == 0.0)
  #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_794_173_082))

  let secondary = try #require(quota.windows.first { $0.windowMinutes == 10080 })
  #expect(secondary.usedPercent == 53.0)
  #expect(secondary.resetsAt == Date(timeIntervalSince1970: 1_794_402_027))

  #expect(runner.closed == 1)
}

@Test func codexUsageProbe_fallbackToRateLimitsWhenByLimitIdMissing() async throws {
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [CodexUsageProbeSyntheticFixtures.accountReadResponse]
    ),
    .init(
      whenSentContains: "account/rateLimits/read",
      lines: [CodexUsageProbeSyntheticFixtures.rateLimitsDirectOnlyResponse]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: replies)
  let probe = CodexUsageProbe(executable: "codex", runner: runner)
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)

  let result = await probe.read(profile, now: Date())
  let quota = try #require(try? result.get())

  #expect(quota.windows.count == 2)
  #expect(quota.windows[0].usedPercent == 12.0)
  #expect(quota.windows[1].usedPercent == 45.0)
  #expect(quota.resetCredits == 1)
  #expect(runner.closed == 1)
}

@Test func codexUsageProbe_missingSecondaryWindowIsSkipped() async throws {
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [CodexUsageProbeSyntheticFixtures.accountReadResponse]
    ),
    .init(
      whenSentContains: "account/rateLimits/read",
      lines: [CodexUsageProbeSyntheticFixtures.rateLimitsPrimaryOnlyResponse]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: replies)
  let probe = CodexUsageProbe(executable: "codex", runner: runner)
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)

  let result = await probe.read(profile, now: Date())
  let quota = try #require(try? result.get())

  #expect(quota.windows.count == 1)
  #expect(quota.windows[0].windowMinutes == 300)
  #expect(quota.windows[0].usedPercent == 20.0)
  #expect(quota.resetCredits == 0)
  #expect(runner.closed == 1)
}

@Test func codexUsageProbe_accountTypeApiKeyFailsWithNeedsSignIn() async {
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [CodexUsageProbeSyntheticFixtures.accountApiKeyResponse]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: replies)
  let probe = CodexUsageProbe(executable: "codex", runner: runner)
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)

  let result = await probe.read(profile, now: Date())
  #expect(result == .failure(.needsSignIn))
  #expect(runner.closed == 1)
}

@Test func codexUsageProbe_jsonRpcErrorOnId3Fails() async {
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [CodexUsageProbeSyntheticFixtures.accountReadResponse]
    ),
    .init(
      whenSentContains: "account/rateLimits/read",
      lines: [CodexUsageProbeSyntheticFixtures.rateLimitsErrorResponse]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: replies)
  let probe = CodexUsageProbe(executable: "codex", runner: runner)
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)

  let result = await probe.read(profile, now: Date())
  #expect(result == .failure(.malformed))
  #expect(runner.closed == 1)
}

@Test func codexUsageProbe_notificationsIgnoredBetweenResponses() async throws {
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [
        CodexUsageProbeSyntheticFixtures.notifyRemoteControl,
        CodexUsageProbeSyntheticFixtures.initializeResponse,
      ]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [
        CodexUsageProbeSyntheticFixtures.notifyAccountUpdated,
        CodexUsageProbeSyntheticFixtures.unrelatedIdResponse,
        CodexUsageProbeSyntheticFixtures.accountReadResponse,
      ]
    ),
    .init(
      whenSentContains: "account/rateLimits/read",
      lines: [
        CodexUsageProbeSyntheticFixtures.notifyAccountUpdated,
        CodexUsageProbeSyntheticFixtures.rateLimitsPrimaryOnlyResponse,
      ]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: replies)
  let probe = CodexUsageProbe(executable: "codex", runner: runner)
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)

  let result = await probe.read(profile, now: Date())
  let quota = try #require(try? result.get())
  #expect(quota.accountName == "user")
  #expect(quota.windows.count == 1)
  #expect(runner.closed == 1)
}

@Test func codexUsageProbe_silenceTimesOutWithUnreachable() async {
  let runner = FakeAgentProcessRunner(replies: [])
  let probe = CodexUsageProbe(executable: "codex", runner: runner)
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)

  let result = await probe.read(profile, now: Date())
  #expect(result == .failure(.unreachable))
  #expect(runner.closed == 1)
}

@Test func codexUsageProbe_environmentSanitizationAndCodexHome() async throws {
  let dirtyEnv = [
    "HOME": "/Users/testuser",
    "USER": "testuser",
    "OPENAI_API_KEY": "sk-secret-123",
    "OPENAI_BASE_URL": "https://api.openai.com/v1",
    "CODEX_API_KEY": "cx-secret-456",
    "CODEX_HOME": "/stale/codex/home",
  ]
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [CodexUsageProbeSyntheticFixtures.accountReadResponse]
    ),
    .init(
      whenSentContains: "account/rateLimits/read",
      lines: [CodexUsageProbeSyntheticFixtures.rateLimitsPrimaryOnlyResponse]
    ),
  ]

  let defaultRunner = FakeAgentProcessRunner(replies: replies)
  let defaultProbe = CodexUsageProbe(
    executable: "/bin/codex",
    runner: defaultRunner,
    baseEnvironment: dirtyEnv
  )
  let defaultProfile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)
  _ = await defaultProbe.read(defaultProfile, now: Date())

  let defaultSpec = try #require(defaultRunner.specs.first)
  for (key, _) in defaultSpec.environment {
    #expect(!key.hasPrefix("OPENAI_"))
    #expect(!key.hasPrefix("CODEX_"))
  }
  #expect(defaultSpec.environment["HOME"] == "/Users/testuser")

  let customRunner = FakeAgentProcessRunner(replies: replies)
  let customProbe = CodexUsageProbe(
    executable: "/bin/codex",
    runner: customRunner,
    baseEnvironment: dirtyEnv
  )
  let customProfile = CodexProfile(path: "/Users/testuser/.codex-work", isDefault: false)
  _ = await customProbe.read(customProfile, now: Date())

  let customSpec = try #require(customRunner.specs.first)
  for (key, _) in customSpec.environment {
    #expect(!key.hasPrefix("OPENAI_"))
    if key.hasPrefix("CODEX_") {
      #expect(key == "CODEX_HOME")
    }
  }
  #expect(customSpec.environment["CODEX_HOME"] == "/Users/testuser/.codex-work")
}

@Test func codexUsageProbe_firstSentLineIsInitializeWithClientInfo() async throws {
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [CodexUsageProbeSyntheticFixtures.accountApiKeyResponse]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: replies)
  let probe = CodexUsageProbe(executable: "codex", runner: runner, appVersion: "3.2.1")
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)

  _ = await probe.read(profile, now: Date())

  let firstSent = try #require(runner.sent.first)
  let data = try #require(firstSent.data(using: .utf8))
  let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

  #expect(json["method"] as? String == "initialize")
  #expect(json["id"] as? Int == 1)

  let params = try #require(json["params"] as? [String: Any])
  let clientInfo = try #require(params["clientInfo"] as? [String: Any])
  #expect(clientInfo["name"] as? String == "hutchbar")
  #expect(clientInfo["title"] as? String == "hutchbar")
  #expect(clientInfo["version"] as? String == "3.2.1")
}

@Test func codexUsageProbe_sessionClosedExactlyOnce() async {
  let replies: [FakeAgentProcessRunner.Reply] = [
    .init(
      whenSentContains: "initialize",
      lines: [CodexUsageProbeSyntheticFixtures.initializeResponse]
    ),
    .init(whenSentContains: "initialized", lines: []),
    .init(
      whenSentContains: "account/read",
      lines: [CodexUsageProbeSyntheticFixtures.accountReadResponse]
    ),
    .init(
      whenSentContains: "account/rateLimits/read",
      lines: [CodexUsageProbeSyntheticFixtures.rateLimitsReadResponse]
    ),
  ]
  let runner = FakeAgentProcessRunner(replies: replies)
  let probe = CodexUsageProbe(executable: "codex", runner: runner)
  let profile = CodexProfile(path: "/Users/testuser/.codex", isDefault: true)

  _ = await probe.read(profile, now: Date())
  #expect(runner.closed == 1)
}
