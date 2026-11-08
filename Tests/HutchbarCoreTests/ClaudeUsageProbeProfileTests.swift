// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

@Suite("ClaudeUsageProbeProfileTests")
struct ClaudeUsageProbeProfileTests {
  @Test func claudeUsageProbe_environmentStripsAnthropicAndClaudeSecretsExceptConfigDir()
    async throws
  {
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"pro",\
      "rate_limits_available":true,"rate_limits":{"limits":[{"group":"session","percent":5.0,\
      "resets_at":null,"scope":null,"is_active":true}]}}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [usageResponse]),
    ])

    let baseEnv = [
      "HOME": "/Users/testuser",
      "USER": "testuser",
      "ANTHROPIC_API_KEY": "sk-secret-token",
      "CLAUDE_SECRET": "dangerous-token",
      "OPENAI_API_KEY": "sk-openai",
      "CLAUDECODE": "1",
    ]

    let customProfile = ClaudeProfile(
      directoryPath: "/Users/testuser/.claude-work",
      configFilePath: "/Users/testuser/.claude-work/.claude.json",
      isDefault: false,
      directoryName: ".claude-work"
    )

    let probe = ClaudeUsageProbe(
      fileSystem: FakeClaudeProbeFileSystem(),
      runner: fakeRunner,
      locator: ExecutableLocator(fileSystem: FixedExecutableLocatorFileSystem()),
      baseEnvironment: baseEnv
    )

    _ = await probe.read(customProfile, now: Date())

    guard let spec = fakeRunner.specs.first else {
      Issue.record("Expected process spec to be recorded")
      return
    }

    #expect(spec.environment["ANTHROPIC_API_KEY"] == nil)
    #expect(spec.environment["CLAUDE_SECRET"] == nil)
    #expect(spec.environment["OPENAI_API_KEY"] == nil)
    #expect(spec.environment["CLAUDECODE"] == nil)
    #expect(spec.environment["DISABLE_AUTOUPDATER"] == "1")
    #expect(spec.environment["CLAUDE_CONFIG_DIR"] == "/Users/testuser/.claude-work")
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_extractsAccountLabelBeforeAtSymbol() async throws {
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"pro",\
      "rate_limits_available":true,"rate_limits":{"limits":[{"group":"session","percent":5.0,\
      "resets_at":null,"scope":null,"is_active":true}]}}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [usageResponse]),
    ])

    let secretEmail = "topsecret@classified.org"
    let configData = Data("{\"oauthAccount\":{\"emailAddress\":\"\(secretEmail)\"}}".utf8)
    let fileSystem = FakeClaudeProbeFileSystem(
      files: ["/Users/testuser/.claude.json": configData]
    )

    let probe = ClaudeUsageProbe(
      fileSystem: fileSystem,
      runner: fakeRunner,
      locator: ExecutableLocator(fileSystem: FixedExecutableLocatorFileSystem())
    )

    let profile = ClaudeProfile(
      directoryPath: "/Users/testuser/.claude",
      configFilePath: "/Users/testuser/.claude.json",
      isDefault: true,
      directoryName: "default"
    )

    let result = await probe.read(profile, now: Date())
    guard case .success(let quota) = result else {
      Issue.record("Expected success, got: \(result)")
      return
    }

    #expect(quota.accountName == "topsecret")
    #expect(!quota.accountName.contains("@"))
    #expect(!quota.accountName.contains("classified.org"))
  }

  @Test func claudeUsageProbe_detectsStaleCachedUsageInConfigFile() async throws {
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"pro",\
      "rate_limits_available":true,"rate_limits":{"limits":[{"group":"session","percent":5.0,\
      "resets_at":null,"scope":null,"is_active":true}]}}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [usageResponse]),
    ])

    let now = Date(timeIntervalSince1970: 1_700_000_100)
    // 100 seconds old cached data (> 60s limit)
    let oldMs = Int64(1_700_000_000 * 1000)
    let configData = Data("{\"cachedUsageUtilization\":{\"fetchedAtMs\":\(oldMs)}}".utf8)
    let fileSystem = FakeClaudeProbeFileSystem(
      files: ["/Users/testuser/.claude.json": configData]
    )

    let probe = ClaudeUsageProbe(
      fileSystem: fileSystem,
      runner: fakeRunner,
      locator: ExecutableLocator(fileSystem: FixedExecutableLocatorFileSystem()),
      cacheSettleTimeout: 0
    )

    let profile = ClaudeProfile(
      directoryPath: "/Users/testuser/.claude",
      configFilePath: "/Users/testuser/.claude.json",
      isDefault: true,
      directoryName: "default"
    )

    let result = await probe.read(profile, now: now)
    #expect(result == .failure(.unreachable))
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_discoversDefaultAndCustomProfiles() {
    let home = "/Users/testuser"
    let fileSystem = FakeClaudeProbeFileSystem(
      home: home,
      files: [
        "\(home)/.claude.json": Data(),
        "\(home)/.claude-work/.claude.json": Data(),
        "\(home)/.claude-personal/.claude.json": Data(),
        "\(home)/.claude-insecure/.claude.json": Data(),
      ],
      directories: [
        home: [".claude", ".claude-work", ".claude-personal", ".claude-insecure"]
      ],
      secureDirs: [
        "\(home)/.claude",
        "\(home)/.claude-work",
        "\(home)/.claude-personal",
      ]
    )

    let probe = ClaudeUsageProbe(
      fileSystem: fileSystem,
      locator: ExecutableLocator(fileSystem: FixedExecutableLocatorFileSystem())
    )

    let profiles = probe.profiles()
    #expect(profiles.count == 3)
    #expect(profiles[0].isDefault)
    #expect(profiles[0].directoryPath == "\(home)/.claude")
    #expect(profiles[1].directoryName == ".claude-personal")
    #expect(profiles[2].directoryName == ".claude-work")
  }
}
