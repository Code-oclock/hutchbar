// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// HTTP client seam for Copilot quota requests.
public protocol CopilotHTTPClient: Sendable {
  func get(url: URL, headers: [String: String]) async throws -> (Int, Data)
}

/// Production HTTP client using URLSession with ephemeral configuration.
public struct URLSessionCopilotHTTPClient: CopilotHTTPClient {
  public init() {}

  public func get(url: URL, headers: [String: String]) async throws -> (Int, Data) {
    guard url.scheme == "https", url.host == "api.github.com" else {
      throw CopilotQuotaProbe.Failure.unreachable
    }

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20.0
    config.timeoutIntervalForResource = 20.0
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 20.0
    for (headerKey, headerValue) in headers {
      request.setValue(headerValue, forHTTPHeaderField: headerKey)
    }

    let rawData: Data
    let response: URLResponse
    do {
      (rawData, response) = try await session.data(for: request)
    } catch {
      throw CopilotQuotaProbe.Failure.unreachable
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw CopilotQuotaProbe.Failure.unreachable
    }

    return (httpResponse.statusCode, rawData)
  }
}

/// Probes GitHub Copilot internal quota API to retrieve monthly premium interactions.
public struct CopilotQuotaProbe: Sendable {
  public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
    case missing
    case needsSignIn
    case unreachable
    case malformed

    public var description: String {
      switch self {
      case .missing: return "CopilotQuotaProbe.Failure.missing"
      case .needsSignIn: return "CopilotQuotaProbe.Failure.needsSignIn"
      case .unreachable: return "CopilotQuotaProbe.Failure.unreachable"
      case .malformed: return "CopilotQuotaProbe.Failure.malformed"
      }
    }
  }

  public static var defaultAppsConfigPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/github-copilot/apps.json").path
  }

  public static var defaultHostsConfigPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/github-copilot/hosts.json").path
  }

  /// Environment variables a GitHub token may come from, in order of preference.
  static let tokenVariables = ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]

  private let httpClient: any CopilotHTTPClient
  private let runner: any AgentProcessRunner
  private let locator: ExecutableLocator
  private let environment: [String: String]
  private let appsConfigPath: String
  private let hostsConfigPath: String
  private let appVersion: String

  public init(
    httpClient: any CopilotHTTPClient = URLSessionCopilotHTTPClient(),
    runner: any AgentProcessRunner = LocalAgentProcessRunner(),
    locator: ExecutableLocator = ExecutableLocator(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    appsConfigPath: String = CopilotQuotaProbe.defaultAppsConfigPath,
    hostsConfigPath: String = CopilotQuotaProbe.defaultHostsConfigPath,
    appVersion: String = "1.0.0"
  ) {
    self.httpClient = httpClient
    self.runner = runner
    self.locator = locator
    // Keep only the token variables: the probe must not carry the whole process environment.
    self.environment = environment.filter { Self.tokenVariables.contains($0.key) }
    self.appsConfigPath = appsConfigPath
    self.hostsConfigPath = hostsConfigPath
    self.appVersion = appVersion
  }

  public func read(now: Date = Date()) async -> Result<AccountQuota, Failure> {
    guard let token = await resolveToken() else {
      return .failure(.missing)
    }

    guard let endpointURL = URL(string: "https://api.github.com/copilot_internal/user") else {
      return .failure(.unreachable)
    }

    let headers: [String: String] = [
      "Authorization": "token \(token)",
      "Accept": "application/json",
      "User-Agent": "hutchbar",
      "Editor-Version": "hutchbar/\(appVersion)",
    ]

    let statusCode: Int
    let responseData: Data
    do {
      (statusCode, responseData) = try await httpClient.get(url: endpointURL, headers: headers)
    } catch let failure as Failure {
      return .failure(failure)
    } catch {
      return .failure(.unreachable)
    }

    switch statusCode {
    case 200...299:
      return parseQuotaResponse(data: responseData, now: now)
    case 401, 403:
      return .failure(.needsSignIn)
    case 404:
      return .failure(.missing)
    case 500...599:
      return .failure(.unreachable)
    default:
      return .failure(.unreachable)
    }
  }

  private func resolveToken() async -> String? {
    let envCandidate =
      environment["COPILOT_GITHUB_TOKEN"]
      ?? environment["GH_TOKEN"]
      ?? environment["GITHUB_TOKEN"]
    if let envCandidate {
      let trimmed = envCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    if let appsToken = readTokenFromAppsConfig(path: appsConfigPath) {
      return appsToken
    }

    if let hostsToken = readTokenFromHostsConfig(path: hostsConfigPath) {
      return hostsToken
    }

    if let ghToken = await readTokenFromGHCLI() {
      return ghToken
    }

    return nil
  }

  private func readTokenFromAppsConfig(path: String) -> String? {
    let resolved = (path as NSString).expandingTildeInPath
    guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
      let jsonObject = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any]
    else {
      return nil
    }

    for (_, value) in jsonObject {
      if let dict = value as? [String: Any],
        let token = dict["oauth_token"] as? String
      {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    }

    if let directToken = jsonObject["oauth_token"] as? String {
      let trimmed = directToken.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    return nil
  }

  private func readTokenFromHostsConfig(path: String) -> String? {
    let resolved = (path as NSString).expandingTildeInPath
    guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
      let jsonObject = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any]
    else {
      return nil
    }

    let candidateKeys = jsonObject.keys.filter { key in key.hasPrefix("github.com") }.sorted()
    for key in candidateKeys {
      if let dict = jsonObject[key] as? [String: Any],
        let token = dict["oauth_token"] as? String
      {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          return trimmed
        }
      }
    }

    return nil
  }

  private func readTokenFromGHCLI() async -> String? {
    guard let executable = locator.locate(executable: "gh") else {
      return nil
    }

    let spec = AgentProcessSpec(
      executable: executable,
      arguments: ["auth", "token"],
      environment: [:],
      timeout: 10.0
    )

    do {
      let session = try await runner.start(spec)
      while let line = try await session.nextLine() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          await session.close()
          return trimmed
        }
      }
      await session.close()
      return nil
    } catch {
      return nil
    }
  }

  private func parseQuotaResponse(data: Data, now: Date) -> Result<AccountQuota, Failure> {
    guard let response = try? JSONDecoder().decode(CopilotInternalUserResponse.self, from: data)
    else {
      return .failure(.malformed)
    }

    guard let premium = response.quotaSnapshots?.premiumInteractions,
      premium.unlimited != true
    else {
      return .failure(.malformed)
    }

    let usedPercent: Double
    if let pctRemaining = premium.percentRemaining {
      usedPercent = max(0.0, min(100.0, 100.0 - pctRemaining))
    } else if let entitlement = premium.entitlement, entitlement > 0,
      let remaining = premium.remaining
    {
      let raw = (Double(entitlement - remaining) / Double(entitlement)) * 100.0
      usedPercent = max(0.0, min(100.0, raw))
    } else {
      return .failure(.malformed)
    }

    let resetsAt = parseQuotaResetDate(response.quotaResetDate)

    let window = QuotaWindow(
      windowMinutes: 43200,
      usedPercent: usedPercent,
      resetsAt: resetsAt,
      scope: nil
    )

    let accountName: String
    if let login = response.login, !login.isEmpty {
      accountName = login
    } else {
      accountName = "copilot"
    }

    let quota = AccountQuota(
      agent: .copilot,
      accountName: accountName,
      windows: [window],
      observedAt: now,
      source: .serviceAPI,
      plan: response.copilotPlan
    )
    return .success(quota)
  }

  private func parseQuotaResetDate(_ dateString: String?) -> Date? {
    guard let dateString, !dateString.isEmpty else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let formatter = DateFormatter()
    formatter.calendar = cal
    formatter.timeZone = cal.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: dateString)
  }
}

extension CopilotQuotaProbe: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  /// No children: `dump()` or a debugger must never show the token variables.
  public var customMirror: Mirror { Mirror(self, children: [:]) }

  public var description: String {
    "CopilotQuotaProbe(appVersion: \(appVersion))"
  }

  public var debugDescription: String {
    description
  }
}

private struct CopilotInternalUserResponse: Decodable {
  let copilotPlan: String?
  let login: String?
  let quotaResetDate: String?
  let quotaSnapshots: CopilotQuotaSnapshots?

  enum CodingKeys: String, CodingKey {
    case copilotPlan = "copilot_plan"
    case login
    case quotaResetDate = "quota_reset_date"
    case quotaSnapshots = "quota_snapshots"
  }

  init(
    copilotPlan: String? = nil,
    login: String? = nil,
    quotaResetDate: String? = nil,
    quotaSnapshots: CopilotQuotaSnapshots? = nil
  ) {
    self.copilotPlan = copilotPlan
    self.login = login
    self.quotaResetDate = quotaResetDate
    self.quotaSnapshots = quotaSnapshots
  }
}

private struct CopilotQuotaSnapshots: Decodable {
  let premiumInteractions: CopilotPremiumInteractions?

  enum CodingKeys: String, CodingKey {
    case premiumInteractions = "premium_interactions"
  }

  init(premiumInteractions: CopilotPremiumInteractions? = nil) {
    self.premiumInteractions = premiumInteractions
  }
}

private struct CopilotPremiumInteractions: Decodable {
  let entitlement: Int?
  let remaining: Int?
  let percentRemaining: Double?
  let unlimited: Bool?

  enum CodingKeys: String, CodingKey {
    case entitlement
    case remaining
    case percentRemaining = "percent_remaining"
    case unlimited
  }

  init(
    entitlement: Int? = nil,
    remaining: Int? = nil,
    percentRemaining: Double? = nil,
    unlimited: Bool? = nil
  ) {
    self.entitlement = entitlement
    self.remaining = remaining
    self.percentRemaining = percentRemaining
    self.unlimited = unlimited
  }
}
