// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

private func copilotQuotaMakeTempFile(content: String) throws -> String {
  let tempDir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  let fileURL = tempDir.appendingPathComponent("config.json")
  try content.write(to: fileURL, atomically: true, encoding: .utf8)
  return fileURL.path
}

private final class CopilotQuotaFakeHTTPClient: CopilotHTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var statusCode: Int
  private var responseData: Data
  private var lastRequestedURL: URL?
  private var lastSentHeaders: [String: String] = [:]

  init(statusCode: Int = 200, responseData: Data = Data()) {
    self.statusCode = statusCode
    self.responseData = responseData
  }

  func setResponse(statusCode: Int, responseData: Data) {
    lock.withLock {
      self.statusCode = statusCode
      self.responseData = responseData
    }
  }

  var requestedURL: URL? {
    lock.withLock { lastRequestedURL }
  }

  var sentHeaders: [String: String] {
    lock.withLock { lastSentHeaders }
  }

  func get(url: URL, headers: [String: String]) async throws -> (Int, Data) {
    lock.withLock {
      self.lastRequestedURL = url
      self.lastSentHeaders = headers
      return (statusCode, responseData)
    }
  }
}

private final class CopilotQuotaFakeProcessRunner: AgentProcessRunner, @unchecked Sendable {
  private let lock = NSLock()
  private let outputLines: [String]
  private var executedSpecs: [AgentProcessSpec] = []

  init(outputLines: [String] = []) {
    self.outputLines = outputLines
  }

  var specs: [AgentProcessSpec] {
    lock.withLock { executedSpecs }
  }

  func start(_ spec: AgentProcessSpec) async throws -> any AgentProcessSession {
    lock.withLock {
      executedSpecs.append(spec)
    }
    return CopilotQuotaFakeSession(lines: outputLines)
  }
}

private final class CopilotQuotaFakeSession: AgentProcessSession, @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String]

  init(lines: [String]) {
    self.lines = lines
  }

  func send(_ line: String) async throws {}

  func nextLine() async throws -> String? {
    lock.withLock {
      if lines.isEmpty { return nil }
      return lines.removeFirst()
    }
  }

  func close() async {}
}

@Suite("CopilotQuotaProbeTests")
struct CopilotQuotaProbeTests {
  private let standardResponseJSON = """
    {
      "copilot_plan": "individual",
      "login": "octocat",
      "quota_reset_date": "2026-12-01",
      "quota_snapshots": {
        "premium_interactions": {
          "entitlement": 300,
          "remaining": 87,
          "percent_remaining": 29.0,
          "unlimited": false
        },
        "chat": {"unlimited": true},
        "completions": {"unlimited": true}
      }
    }
    """

  @Test func parsesStandardResponseWithRemainingPercentAndResetsMidnightUTC() async throws {
    let httpClient = CopilotQuotaFakeHTTPClient(
      statusCode: 200,
      responseData: Data(standardResponseJSON.utf8)
    )
    let probe = CopilotQuotaProbe(
      httpClient: httpClient,
      environment: ["COPILOT_GITHUB_TOKEN": "gho_test_token_123"],
      appVersion: "1.2.3"
    )

    let nowDate = Date(timeIntervalSince1970: 1_762_680_000)
    let result = await probe.read(now: nowDate)

    guard case .success(let quota) = result else {
      Issue.record("Expected success, got: \(result)")
      return
    }

    #expect(quota.agent == .copilot)
    #expect(quota.accountName == "octocat")
    #expect(quota.plan == "individual")
    #expect(quota.source == .serviceAPI)
    #expect(quota.observedAt == nowDate)
    #expect(quota.windows.count == 1)

    let window = try #require(quota.windows.first)
    #expect(window.windowMinutes == 43200)
    #expect(abs(window.usedPercent - 71.0) < 0.001)

    let resetsAtDate = try #require(window.resetsAt)
    var gmtCal = Calendar(identifier: .gregorian)
    gmtCal.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let comps = gmtCal.dateComponents([.year, .month, .day, .hour, .minute], from: resetsAtDate)
    #expect(comps.year == 2026)
    #expect(comps.month == 12)
    #expect(comps.day == 1)
    #expect(comps.hour == 0)
    #expect(comps.minute == 0)
  }

  @Test func calculatesUsedPercentWhenPercentRemainingIsMissing() async throws {
    let jsonWithoutPercent = """
      {
        "copilot_plan": "business",
        "login": "mona",
        "quota_reset_date": "2026-12-05",
        "quota_snapshots": {
          "premium_interactions": {
            "entitlement": 300,
            "remaining": 87,
            "unlimited": false
          }
        }
      }
      """
    let httpClient = CopilotQuotaFakeHTTPClient(
      statusCode: 200,
      responseData: Data(jsonWithoutPercent.utf8)
    )
    let probe = CopilotQuotaProbe(
      httpClient: httpClient,
      environment: ["GH_TOKEN": "gho_mona_token"]
    )

    let result = await probe.read()
    guard case .success(let quota) = result else {
      Issue.record("Expected success, got: \(result)")
      return
    }

    let window = try #require(quota.windows.first)
    #expect(abs(window.usedPercent - 71.0) < 0.001)
  }

  @Test func unlimitedOrMissingPremiumInteractionsYieldsMalformed() async throws {
    let unlimitedJSON = """
      {
        "login": "octocat",
        "quota_snapshots": {
          "premium_interactions": {"unlimited": true}
        }
      }
      """
    let httpClient = CopilotQuotaFakeHTTPClient(
      statusCode: 200,
      responseData: Data(unlimitedJSON.utf8)
    )
    let probe = CopilotQuotaProbe(
      httpClient: httpClient,
      environment: ["GITHUB_TOKEN": "gho_token"]
    )

    let unlimitedResult = await probe.read()
    #expect(unlimitedResult == .failure(.malformed))

    let emptySnapshotsJSON = "{\"login\":\"octocat\",\"quota_snapshots\":{}}"
    httpClient.setResponse(statusCode: 200, responseData: Data(emptySnapshotsJSON.utf8))
    let emptyResult = await probe.read()
    #expect(emptyResult == .failure(.malformed))
  }

  @Test func tokenPriorityEnvironmentTakesPrecedenceOverConfigFiles() async throws {
    let appsFile = try copilotQuotaMakeTempFile(
      content: "{\"copilot\":{\"oauth_token\":\"token_from_apps\"}}"
    )
    let hostsFile = try copilotQuotaMakeTempFile(
      content: "{\"github.com\":{\"oauth_token\":\"token_from_hosts\"}}"
    )
    let httpClient = CopilotQuotaFakeHTTPClient(
      statusCode: 200,
      responseData: Data(standardResponseJSON.utf8)
    )

    let probeEnv = CopilotQuotaProbe(
      httpClient: httpClient,
      environment: ["COPILOT_GITHUB_TOKEN": "token_from_env"],
      appsConfigPath: appsFile,
      hostsConfigPath: hostsFile
    )
    _ = await probeEnv.read()
    #expect(httpClient.sentHeaders["Authorization"] == "token token_from_env")

    let probeApps = CopilotQuotaProbe(
      httpClient: httpClient,
      environment: [:],
      appsConfigPath: appsFile,
      hostsConfigPath: hostsFile
    )
    _ = await probeApps.read()
    #expect(httpClient.sentHeaders["Authorization"] == "token token_from_apps")
  }

  @Test func hostsConfigMatchesPrefixWithPortOrClientID() async throws {
    let hostsFile = try copilotQuotaMakeTempFile(
      content: "{\"github.com:Iv1.abcdef123456\":{\"oauth_token\":\"gho_from_iv1\"}}"
    )
    let httpClient = CopilotQuotaFakeHTTPClient(
      statusCode: 200,
      responseData: Data(standardResponseJSON.utf8)
    )
    let probe = CopilotQuotaProbe(
      httpClient: httpClient,
      environment: [:],
      appsConfigPath: "/nonexistent/apps.json",
      hostsConfigPath: hostsFile
    )

    _ = await probe.read()
    #expect(httpClient.sentHeaders["Authorization"] == "token gho_from_iv1")
  }

  @Test func fallsBackToGHCLITokenWhenEnvAndFilesAreMissing() async throws {
    let fakeRunner = CopilotQuotaFakeProcessRunner(outputLines: ["gho_from_gh_cli"])
    let locator = ExecutableLocator(
      fileSystem: FixedExecutableLocatorFileSystem(executable: "/usr/local/bin/gh")
    )
    let httpClient = CopilotQuotaFakeHTTPClient(
      statusCode: 200,
      responseData: Data(standardResponseJSON.utf8)
    )

    let probe = CopilotQuotaProbe(
      httpClient: httpClient,
      runner: fakeRunner,
      locator: locator,
      environment: [:],
      appsConfigPath: "/nonexistent/apps.json",
      hostsConfigPath: "/nonexistent/hosts.json"
    )

    _ = await probe.read()
    #expect(httpClient.sentHeaders["Authorization"] == "token gho_from_gh_cli")
    #expect(!fakeRunner.specs.isEmpty)
  }

  @Test func handlesHTTPErrorCodesProperly() async throws {
    let httpClient = CopilotQuotaFakeHTTPClient()
    let probe = CopilotQuotaProbe(
      httpClient: httpClient,
      environment: ["COPILOT_GITHUB_TOKEN": "token_test"]
    )

    httpClient.setResponse(statusCode: 401, responseData: Data())
    #expect(await probe.read() == .failure(.needsSignIn))

    httpClient.setResponse(statusCode: 403, responseData: Data())
    #expect(await probe.read() == .failure(.needsSignIn))

    httpClient.setResponse(statusCode: 404, responseData: Data())
    #expect(await probe.read() == .failure(.missing))

    httpClient.setResponse(statusCode: 500, responseData: Data())
    #expect(await probe.read() == .failure(.unreachable))

    httpClient.setResponse(statusCode: 503, responseData: Data())
    #expect(await probe.read() == .failure(.unreachable))
  }

  @Test func tokenNeverAppearsInProbeOrFailureDescriptions() {
    let secret = "gho_super_secret_never_leak_9999"
    let probe = CopilotQuotaProbe(
      environment: ["COPILOT_GITHUB_TOKEN": secret]
    )

    let probeDesc = String(describing: probe)
    #expect(!probeDesc.contains(secret))
    var dumped = ""
    dump(probe, to: &dumped)
    #expect(!dumped.contains(secret))
    #expect(!String(reflecting: probe).contains(secret))

    let missingFailure = CopilotQuotaProbe.Failure.missing
    #expect(!String(describing: missingFailure).contains(secret))

    let signinFailure = CopilotQuotaProbe.Failure.needsSignIn
    #expect(!String(describing: signinFailure).contains(secret))
  }

  @Test func sendsExpectedRequestHeadersToClient() async throws {
    let httpClient = CopilotQuotaFakeHTTPClient(
      statusCode: 200,
      responseData: Data(standardResponseJSON.utf8)
    )
    let probe = CopilotQuotaProbe(
      httpClient: httpClient,
      environment: ["COPILOT_GITHUB_TOKEN": "gho_my_token"],
      appVersion: "2.4.0"
    )

    _ = await probe.read()
    let headers = httpClient.sentHeaders
    #expect(headers["Authorization"] == "token gho_my_token")
    #expect(headers["Accept"] == "application/json")
    #expect(headers["User-Agent"] == "hutchbar")
    #expect(headers["Editor-Version"] == "hutchbar/2.4.0")
    #expect(
      httpClient.requestedURL?.absoluteString == "https://api.github.com/copilot_internal/user")
  }

  @Test func localizedMonthWindowNameAndUsedUpLabels() {
    #expect(L10n.quotaWindowName(minutes: 43200, language: .en) == "Month")
    #expect(L10n.quotaWindowName(minutes: 43200, language: .ru) == "Месяц")

    let usedUpRu = L10n.windowUsedUp(windowName: "Месяц", minutes: 43200, language: .ru)
    #expect(usedUpRu == "месяц исчерпан")

    let usedUpEn = L10n.windowUsedUp(windowName: "Month", minutes: 43200, language: .en)
    #expect(usedUpEn == "month used up")
  }
}
