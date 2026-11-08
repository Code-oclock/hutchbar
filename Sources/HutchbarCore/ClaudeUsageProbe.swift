// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// One discovered Claude Code profile directory and configuration.
public struct ClaudeProfile: Equatable, Sendable {
  public let directoryPath: String
  public let configFilePath: String
  public let isDefault: Bool
  public let directoryName: String

  public init(
    directoryPath: String,
    configFilePath: String,
    isDefault: Bool,
    directoryName: String
  ) {
    self.directoryPath = directoryPath
    self.configFilePath = configFilePath
    self.isDefault = isDefault
    self.directoryName = directoryName
  }
}

/// Filesystem access for ClaudeUsageProbe profile discovery and config inspection.
public protocol ClaudeProbeFileSystem: Sendable {
  func homeDirectory() -> String
  func fileExists(atPath path: String) -> Bool
  func contentsOfDirectory(atPath path: String) -> [String]
  func readFile(atPath path: String) -> Data?
  func isSecureProfileDirectory(atPath path: String) -> Bool
}

public struct DefaultClaudeProbeFileSystem: ClaudeProbeFileSystem {
  public init() {}

  public func homeDirectory() -> String {
    FileManager.default.homeDirectoryForCurrentUser.path
  }

  public func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func contentsOfDirectory(atPath path: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
  }

  public func readFile(atPath path: String) -> Data? {
    try? Data(contentsOf: URL(fileURLWithPath: path))
  }

  public func isSecureProfileDirectory(atPath path: String) -> Bool {
    var status = stat()
    guard stat(path, &status) == 0 else { return false }
    guard (status.st_mode & S_IFMT) == S_IFDIR else { return false }
    guard status.st_uid == getuid() else { return false }
    guard (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return false }
    return true
  }
}

/// Reads Claude subscription quotas directly from the `claude` CLI via control requests
/// (docs/specs/limits-v3.md, section 3).
public struct ClaudeUsageProbe: Sendable {
  public enum Failure: Error, Equatable, Sendable {
    case missing
    case needsSignIn
    case outdated
    case unreachable
    case malformed
  }

  private let fileSystem: any ClaudeProbeFileSystem
  private let runner: any AgentProcessRunner
  private let locator: ExecutableLocator
  private let baseEnvironment: [String: String]
  private let cacheSettleTimeout: Double

  public init(
    fileSystem: any ClaudeProbeFileSystem = DefaultClaudeProbeFileSystem(),
    runner: any AgentProcessRunner = LocalAgentProcessRunner(),
    locator: ExecutableLocator? = nil,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    cacheSettleTimeout: Double = 2.0
  ) {
    self.fileSystem = fileSystem
    self.runner = runner
    self.locator = locator ?? ExecutableLocator()
    self.baseEnvironment = baseEnvironment
    self.cacheSettleTimeout = cacheSettleTimeout
  }

  public func profiles() -> [ClaudeProfile] {
    let home = fileSystem.homeDirectory()
    var discovered: [ClaudeProfile] = []

    let defaultDir = "\(home)/.claude"
    let defaultConfig = "\(home)/.claude.json"
    if fileSystem.fileExists(atPath: defaultDir),
      fileSystem.isSecureProfileDirectory(atPath: defaultDir)
    {
      discovered.append(
        ClaudeProfile(
          directoryPath: defaultDir,
          configFilePath: defaultConfig,
          isDefault: true,
          directoryName: "default"
        )
      )
    }

    let entries = fileSystem.contentsOfDirectory(atPath: home).sorted()
    var customCount = 0
    for entry in entries where entry.hasPrefix(".claude-") && customCount < 8 {
      let dirPath = "\(home)/\(entry)"
      let configPath = "\(dirPath)/.claude.json"
      guard fileSystem.isSecureProfileDirectory(atPath: dirPath),
        fileSystem.fileExists(atPath: configPath)
      else {
        continue
      }
      discovered.append(
        ClaudeProfile(
          directoryPath: dirPath,
          configFilePath: configPath,
          isDefault: false,
          directoryName: entry
        )
      )
      customCount += 1
    }

    return discovered
  }

  public func read(
    _ profile: ClaudeProfile,
    now: Date = Date()
  ) async -> Result<AccountQuota, ClaudeUsageProbe.Failure> {
    guard let executable = locator.locate(.claudeCode) else {
      return .failure(.missing)
    }

    var extra: [String: String] = ["DISABLE_AUTOUPDATER": "1"]
    if !profile.isDefault {
      extra["CLAUDE_CONFIG_DIR"] = profile.directoryPath
    }
    let environment = AgentProcessEnvironment.make(
      base: baseEnvironment,
      executable: executable,
      extra: extra
    )

    let spec = AgentProcessSpec(
      executable: executable,
      arguments: [
        "--print",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--no-session-persistence",
        "--tools", "",
        "--strict-mcp-config",
        "--mcp-config", "{\"mcpServers\":{}}",
        "--setting-sources", "",
        "--settings", "{\"disableAllHooks\":true}",
      ],
      environment: environment,
      timeout: 25.0
    )

    let session: any AgentProcessSession
    do {
      session = try await runner.start(spec)
    } catch {
      return .failure(.unreachable)
    }

    let result: Result<AccountQuota, ClaudeUsageProbe.Failure>
    do {
      result = try await performConversation(session: session, profile: profile, now: now)
    } catch let failure as ClaudeUsageProbe.Failure {
      result = .failure(failure)
    } catch {
      result = .failure(.unreachable)
    }
    await session.close()
    return result
  }

  private func performConversation(
    session: any AgentProcessSession,
    profile: ClaudeProfile,
    now: Date
  ) async throws -> Result<AccountQuota, ClaudeUsageProbe.Failure> {
    let initLine =
      "{\"type\":\"control_request\",\"request_id\":\"initialize\",\"request\":{\"subtype\":\"initialize\"}}"
    try await session.send(initLine)

    _ = try await waitForControlResponse(session: session, expectedRequestId: "initialize")

    let usageLine =
      "{\"type\":\"control_request\",\"request_id\":\"usage\","
      + "\"request\":{\"subtype\":\"get_usage\",\"skip_behaviors\":true}}"
    try await session.send(usageLine)

    let usageResponse = try await waitForControlResponse(
      session: session, expectedRequestId: "usage")

    try await verifyNotStaleCache(profile: profile, now: now)

    return try parseUsagePayload(usageResponse, profile: profile, now: now)
  }

  private func waitForControlResponse(
    session: any AgentProcessSession,
    expectedRequestId: String
  ) async throws -> [String: Any] {
    while true {
      guard let line = try await session.nextLine() else {
        throw Failure.unreachable
      }

      guard let data = line.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        continue
      }

      if let errorDict = json["error"] as? [String: Any] {
        let message = (errorDict["message"] as? String ?? "").lowercased()
        if message.contains("login") || message.contains("auth") {
          throw Failure.needsSignIn
        }
        if message.contains("unknown") {
          throw Failure.outdated
        }
      }

      guard let type = json["type"] as? String, type == "control_response",
        let response = json["response"] as? [String: Any]
      else {
        continue
      }

      let requestId = response["request_id"] as? String ?? ""
      guard requestId == expectedRequestId else {
        continue
      }

      if let subtype = response["subtype"] as? String, subtype == "error" {
        let errMessage = (response["error"] as? String ?? "").lowercased()
        if errMessage.contains("login") || errMessage.contains("auth") {
          throw Failure.needsSignIn
        }
        if errMessage.contains("unknown") {
          throw Failure.outdated
        }
        throw Failure.malformed
      }

      return response
    }
  }

  /// Claude answers from its saved copy while it is younger than 60 s, otherwise asks the
  /// account and saves the new copy, but only after it has answered. So a stale-looking copy
  /// is re-read for up to `cacheSettleTimeout` before the answer counts as an offline copy.
  private func verifyNotStaleCache(profile: ClaudeProfile, now: Date) async throws {
    let deadline = ContinuousClock.now + .seconds(cacheSettleTimeout)
    while true {
      guard let fetchedAt = cachedUsageFetchedAt(profile: profile) else { return }
      if now.timeIntervalSince(fetchedAt) <= 60.0 { return }
      if ContinuousClock.now >= deadline { throw Failure.unreachable }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  private func cachedUsageFetchedAt(profile: ClaudeProfile) -> Date? {
    guard let data = fileSystem.readFile(atPath: profile.configFilePath),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let cachedUsage = json["cachedUsageUtilization"] as? [String: Any],
      let fetchedAtMs = (cachedUsage["fetchedAtMs"] as? NSNumber)?.doubleValue
    else {
      return nil
    }
    return Date(timeIntervalSince1970: fetchedAtMs / 1000.0)
  }

  private func parseUsagePayload(
    _ response: [String: Any],
    profile: ClaudeProfile,
    now: Date
  ) throws -> Result<AccountQuota, ClaudeUsageProbe.Failure> {
    guard let payload = response["response"] as? [String: Any] else {
      throw Failure.malformed
    }

    guard payload["rate_limits_available"] as? Bool == true else {
      throw Failure.needsSignIn
    }

    let plan = payload["subscription_type"] as? String
    let label = extractAccountLabel(profile: profile)

    let windows = extractQuotaWindows(from: payload)
    guard !windows.isEmpty else {
      throw Failure.malformed
    }

    return .success(
      AccountQuota(
        agent: .claudeCode,
        accountName: label,
        windows: windows,
        observedAt: now,
        source: .agentCLI,
        plan: plan
      )
    )
  }

  private func extractAccountLabel(profile: ClaudeProfile) -> String {
    let fallback = (profile.directoryPath as NSString).lastPathComponent
    guard let data = fileSystem.readFile(atPath: profile.configFilePath),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let oauth = json["oauthAccount"] as? [String: Any],
      let email = oauth["emailAddress"] as? String
    else {
      return fallback
    }

    if let atIndex = email.firstIndex(of: "@"), atIndex > email.startIndex {
      return String(email[..<atIndex])
    }
    return fallback
  }

  private func extractQuotaWindows(from payload: [String: Any]) -> [QuotaWindow] {
    let rateLimits = payload["rate_limits"] as? [String: Any]

    if let limits = rateLimits?["limits"] as? [[String: Any]], !limits.isEmpty {
      var windows: [QuotaWindow] = []
      for limit in limits {
        guard let group = limit["group"] as? String else { continue }
        let windowMinutes: Int
        switch group {
        case "session": windowMinutes = 300
        case "weekly": windowMinutes = 10080
        default: continue
        }

        let usedPercent = (limit["percent"] as? NSNumber)?.doubleValue ?? 0.0
        let resetsAt = parseDate(limit["resets_at"])
        let scope = limit["scope"] as? String

        windows.append(
          QuotaWindow(
            windowMinutes: windowMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            scope: scope
          )
        )
      }
      if !windows.isEmpty {
        return windows
      }
    }

    let fallbackContainer = rateLimits ?? payload
    var fallbackWindows: [QuotaWindow] = []
    let fallbackKeys: [(key: String, minutes: Int, scope: String?)] = [
      ("five_hour", 300, nil),
      ("seven_day", 10080, nil),
      ("seven_day_opus", 10080, "Opus"),
      ("seven_day_sonnet", 10080, "Sonnet"),
    ]

    for item in fallbackKeys {
      guard let limitDict = fallbackContainer[item.key] as? [String: Any],
        let utilization = (limitDict["utilization"] as? NSNumber)?.doubleValue
      else {
        continue
      }
      let usedPercent = utilization <= 1.0 ? utilization * 100.0 : utilization
      let resetsAt = parseDate(limitDict["resets_at"])
      fallbackWindows.append(
        QuotaWindow(
          windowMinutes: item.minutes,
          usedPercent: usedPercent,
          resetsAt: resetsAt,
          scope: item.scope
        )
      )
    }

    return fallbackWindows
  }

  private func parseDate(_ value: Any?) -> Date? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return fractional.date(from: string) ?? standard.date(from: string)
  }
}
