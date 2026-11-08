// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

@Suite("AntigravityUsageProbeTests")
struct AntigravityUsageProbeTests {
  private let standardUsageJSON = """
    {"command":{"name":"usage","data":{"groups":[
      {"name":"Gemini Models","buckets":[
        {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.657,"reset_time":"2026-11-14T10:49:49Z"},
        {"id":"gemini-5h","window":"5h","remaining_fraction":0.806,"reset_time":"2026-11-08T23:50:41Z"}]},
      {"name":"Claude and GPT models","buckets":[
        {"id":"3p-weekly","window":"weekly","remaining_fraction":0.0043,"reset_time":"2026-11-08T23:38:32Z"},
        {"id":"3p-5h","window":"5h","remaining_fraction":1,"reset_time":"2026-11-09T00:52:20Z"}]}]}}}
    """

  @Test func parsesFourWindowsAndScopesSuccessfully() async throws {
    let fakeRunner = FakeAgentProcessRunner(initialLines: [standardUsageJSON])
    let locator = ExecutableLocator(
      fileSystem: FixedExecutableLocatorFileSystem(executable: "/usr/local/bin/agy"))
    let probe = AntigravityUsageProbe(runner: fakeRunner, locator: locator)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let result = await probe.read(now: now)
    guard case .success(let quota) = result else {
      Issue.record("Expected successful AccountQuota parsing, got: \(result)")
      return
    }

    #expect(quota.agent == .antigravity)
    #expect(quota.accountName == "agy")
    #expect(quota.source == .agentCLI)
    #expect(quota.observedAt == now)
    #expect(quota.windows.count == 4)

    // Window 0: Gemini weekly
    #expect(quota.windows[0].windowMinutes == 10080)
    #expect(abs(quota.windows[0].usedPercent - 34.3) < 0.001)
    #expect(quota.windows[0].scope == "Gemini")
    #expect(quota.windows[0].resetsAt != nil)

    // Window 1: Gemini 5h
    #expect(quota.windows[1].windowMinutes == 300)
    #expect(abs(quota.windows[1].usedPercent - 19.4) < 0.001)
    #expect(quota.windows[1].scope == "Gemini")
    #expect(quota.windows[1].resetsAt != nil)

    // Window 2: Claude+GPT weekly
    #expect(quota.windows[2].windowMinutes == 10080)
    #expect(abs(quota.windows[2].usedPercent - 99.57) < 0.001)
    #expect(quota.windows[2].scope == "Claude+GPT")
    #expect(quota.windows[2].resetsAt != nil)

    // Window 3: Claude+GPT 5h
    #expect(quota.windows[3].windowMinutes == 300)
    #expect(quota.windows[3].usedPercent == 0.0)
    #expect(quota.windows[3].scope == "Claude+GPT")
    #expect(quota.windows[3].resetsAt != nil)

    #expect(fakeRunner.closed == 1)
  }

  @Test func ignoresForeignLinesBeforeJSON() async throws {
    let lines = [
      "Welcome to Antigravity CLI v1.5.0",
      "Checking configuration...",
      standardUsageJSON,
    ]
    let fakeRunner = FakeAgentProcessRunner(initialLines: lines)
    let locator = ExecutableLocator(
      fileSystem: FixedExecutableLocatorFileSystem(executable: "/usr/local/bin/agy"))
    let probe = AntigravityUsageProbe(runner: fakeRunner, locator: locator)

    let result = await probe.read(now: Date())
    guard case .success(let quota) = result else {
      Issue.record("Expected success with foreign lines before JSON, got: \(result)")
      return
    }

    #expect(quota.windows.count == 4)
    #expect(fakeRunner.closed == 1)
  }

  @Test func emptyOutputYieldsUnreachable() async throws {
    let fakeRunner = FakeAgentProcessRunner(initialLines: [])
    let locator = ExecutableLocator(
      fileSystem: FixedExecutableLocatorFileSystem(executable: "/usr/local/bin/agy"))
    let probe = AntigravityUsageProbe(runner: fakeRunner, locator: locator)

    let result = await probe.read(now: Date())
    #expect(result == .failure(.unreachable))
    #expect(fakeRunner.closed == 1)
  }

  @Test func missingGroupsYieldsMalformed() async throws {
    let malformedJSON = "{\"command\":{\"name\":\"usage\",\"data\":{}}}"
    let fakeRunner = FakeAgentProcessRunner(initialLines: [malformedJSON])
    let locator = ExecutableLocator(
      fileSystem: FixedExecutableLocatorFileSystem(executable: "/usr/local/bin/agy"))
    let probe = AntigravityUsageProbe(runner: fakeRunner, locator: locator)

    let result = await probe.read(now: Date())
    #expect(result == .failure(.malformed))
    #expect(fakeRunner.closed == 1)
  }

  @Test func missingExecutableYieldsMissing() async throws {
    let fakeRunner = FakeAgentProcessRunner(initialLines: [standardUsageJSON])
    let locator = ExecutableLocator(
      fileSystem: FixedExecutableLocatorFileSystem(executable: "/nonexistent/agy"))
    let probe = AntigravityUsageProbe(runner: fakeRunner, locator: locator)

    let result = await probe.read(now: Date())
    #expect(result == .failure(.missing))
    #expect(fakeRunner.closed == 0)
  }

  @Test func processTimeoutYieldsUnreachable() async throws {
    let fakeRunner = FakeAgentProcessRunner(initialLines: nil)
    let locator = ExecutableLocator(
      fileSystem: FixedExecutableLocatorFileSystem(executable: "/usr/local/bin/agy"))
    let probe = AntigravityUsageProbe(runner: fakeRunner, locator: locator)

    let result = await probe.read(now: Date())
    #expect(result == .failure(.unreachable))
    #expect(fakeRunner.closed == 1)
  }
}
