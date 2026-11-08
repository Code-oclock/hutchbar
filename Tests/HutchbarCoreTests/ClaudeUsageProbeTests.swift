// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

struct FixedExecutableLocatorFileSystem: ExecutableLocatorFileSystem {
  let executable: String
  init(executable: String = "/opt/homebrew/bin/claude") {
    self.executable = executable
  }
  func isExecutableFile(atPath path: String) -> Bool { path == executable }
  func contentsOfDirectory(atPath path: String) -> [String] { [] }
  func homeDirectory() -> String { "/Users/testuser" }
}

struct FakeClaudeProbeFileSystem: ClaudeProbeFileSystem {
  let home: String
  let files: [String: Data]
  let directories: [String: [String]]
  let secureDirs: Set<String>

  init(
    home: String = "/Users/testuser",
    files: [String: Data] = [:],
    directories: [String: [String]] = [:],
    secureDirs: Set<String> = []
  ) {
    self.home = home
    self.files = files
    self.directories = directories
    self.secureDirs = secureDirs
  }

  func homeDirectory() -> String { home }
  func fileExists(atPath path: String) -> Bool {
    files[path] != nil || directories[path] != nil || secureDirs.contains(path)
  }
  func contentsOfDirectory(atPath path: String) -> [String] {
    directories[path] ?? []
  }
  func readFile(atPath path: String) -> Data? {
    files[path]
  }
  func isSecureProfileDirectory(atPath path: String) -> Bool {
    secureDirs.contains(path)
  }
}

let standardInitResponse =
  "{\"type\":\"control_response\",\"response\":{\"request_id\":\"initialize\",\"subtype\":\"success\"}}"

@Suite("ClaudeUsageProbeTests")
struct ClaudeUsageProbeTests {
  @Test func claudeUsageProbe_parsesLimitsArraySuccessfully() async throws {
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"pro",\
      "rate_limits_available":true,"rate_limits":{"limits":[{"group":"session","percent":25.0,\
      "resets_at":"2026-11-08T22:00:00Z","scope":null,"is_active":true},{"group":"weekly","percent":60.0,\
      "resets_at":"2026-11-15T10:00:00Z","scope":"Sonnet","is_active":true}]}}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [usageResponse]),
    ])

    let configData = Data("{\"oauthAccount\":{\"emailAddress\":\"alice@work.corp\"}}".utf8)
    let fileSystem = FakeClaudeProbeFileSystem(
      home: "/Users/testuser",
      files: ["/Users/testuser/.claude.json": configData],
      directories: ["/Users/testuser": [".claude"]],
      secureDirs: ["/Users/testuser/.claude"]
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
      Issue.record("Expected successful AccountQuota parsing, got: \(result)")
      return
    }

    #expect(quota.agent == .claudeCode)
    #expect(quota.accountName == "alice")
    #expect(quota.plan == "pro")
    #expect(quota.source == .agentCLI)
    #expect(quota.windows.count == 2)
    #expect(quota.windows[0].windowMinutes == 300)
    #expect(quota.windows[0].usedPercent == 25.0)
    #expect(quota.windows[0].scope == nil)
    #expect(quota.windows[1].windowMinutes == 10080)
    #expect(quota.windows[1].usedPercent == 60.0)
    #expect(quota.windows[1].scope == "Sonnet")
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_parsesFallbackLegacyKeysAndSkipsNull() async throws {
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"max",\
      "rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":0.35,"resets_at":"2026-11-08T21:00:00Z"},\
      "seven_day":null,"seven_day_opus":{"utilization":0.8,"resets_at":"2026-11-14T08:00:00Z"},\
      "seven_day_sonnet":null}}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [usageResponse]),
    ])

    let configData = Data("{\"oauthAccount\":{\"emailAddress\":\"bob@example.com\"}}".utf8)
    let fileSystem = FakeClaudeProbeFileSystem(
      files: ["/Users/testuser/.claude.json": configData],
      secureDirs: ["/Users/testuser/.claude"]
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
      Issue.record("Expected successful AccountQuota parsing, got: \(result)")
      return
    }

    #expect(quota.windows.count == 2)
    #expect(quota.windows[0].windowMinutes == 300)
    #expect(quota.windows[0].usedPercent == 35.0)
    #expect(quota.windows[0].scope == nil)
    #expect(quota.windows[1].windowMinutes == 10080)
    #expect(quota.windows[1].usedPercent == 80.0)
    #expect(quota.windows[1].scope == "Opus")
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_nullResetsAtYieldsNilResetsAtWindow() async throws {
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"pro",\
      "rate_limits_available":true,"rate_limits":{"limits":[{"group":"session","percent":0.0,\
      "resets_at":null,"scope":null,"is_active":true}]}}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [usageResponse]),
    ])

    let probe = ClaudeUsageProbe(
      fileSystem: FakeClaudeProbeFileSystem(),
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

    #expect(quota.windows.count == 1)
    #expect(quota.windows[0].resetsAt == nil)
    #expect(quota.windows[0].usedPercent == 0.0)
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_parsesOpusAndSonnetScopes() async throws {
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"max",\
      "rate_limits_available":true,"rate_limits":{"limits":[{"group":"weekly","percent":10.0,\
      "resets_at":null,"scope":"Opus","is_active":true},{"group":"weekly","percent":20.0,\
      "resets_at":null,"scope":"Sonnet","is_active":true}]}}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [usageResponse]),
    ])

    let probe = ClaudeUsageProbe(
      fileSystem: FakeClaudeProbeFileSystem(),
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

    #expect(quota.windows.count == 2)
    #expect(quota.windows[0].scope == "Opus")
    #expect(quota.windows[1].scope == "Sonnet")
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_rateLimitsUnavailableFailsWithNeedsSignIn() async throws {
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"free",\
      "rate_limits_available":false,"rate_limits":null}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [usageResponse]),
    ])

    let probe = ClaudeUsageProbe(
      fileSystem: FakeClaudeProbeFileSystem(),
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
    #expect(result == .failure(.needsSignIn))
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_loginOrAuthErrorFailsWithNeedsSignIn() async throws {
    let errorResponse = """
      {"type":"control_response","response":{"request_id":"initialize","subtype":"error",\
      "error":"Please login to authenticate"}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [errorResponse])
    ])

    let probe = ClaudeUsageProbe(
      fileSystem: FakeClaudeProbeFileSystem(),
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
    #expect(result == .failure(.needsSignIn))
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_silenceFailsWithUnreachable() async throws {
    let fakeRunner = FakeAgentProcessRunner(replies: [])

    let probe = ClaudeUsageProbe(
      fileSystem: FakeClaudeProbeFileSystem(),
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
    #expect(result == .failure(.unreachable))
    #expect(fakeRunner.closed == 1)
  }

  @Test func claudeUsageProbe_ignoresSystemAndStreamEventsBeforeResponse() async throws {
    let systemLine = "{\"type\":\"system\",\"subtype\":\"notice\",\"message\":\"starting\"}"
    let streamEventLine = "{\"type\":\"stream_event\",\"event\":\"loading\"}"
    let usageResponse = """
      {"type":"control_response","response":{"request_id":"usage","response":{"subscription_type":"pro",\
      "rate_limits_available":true,"rate_limits":{"limits":[{"group":"session","percent":10.0,\
      "resets_at":null,"scope":null,"is_active":true}]}}}}
      """

    let fakeRunner = FakeAgentProcessRunner(replies: [
      .init(whenSentContains: "initialize", lines: [systemLine, standardInitResponse]),
      .init(whenSentContains: "get_usage", lines: [streamEventLine, usageResponse]),
    ])

    let probe = ClaudeUsageProbe(
      fileSystem: FakeClaudeProbeFileSystem(),
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

    #expect(quota.windows.count == 1)
    #expect(fakeRunner.closed == 1)
  }
}
