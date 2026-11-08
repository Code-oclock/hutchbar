// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reads Antigravity subscription quotas directly from the `agy` CLI via `-p /usage`.
public struct AntigravityUsageProbe: Sendable {
  public enum Failure: Error, Equatable, Sendable {
    case missing
    case unreachable
    case malformed
  }

  private let runner: any AgentProcessRunner
  private let locator: ExecutableLocator
  private let baseEnvironment: [String: String]

  public init(
    runner: any AgentProcessRunner = LocalAgentProcessRunner(),
    locator: ExecutableLocator? = nil,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.runner = runner
    self.locator = locator ?? ExecutableLocator()
    self.baseEnvironment = baseEnvironment
  }

  public func read(now: Date = Date()) async -> Result<AccountQuota, Failure> {
    guard let executable = locator.locate(.antigravity) else {
      return .failure(.missing)
    }

    let environment = AgentProcessEnvironment.make(
      base: baseEnvironment,
      executable: executable
    )

    let spec = AgentProcessSpec(
      executable: executable,
      arguments: ["-p", "/usage", "--output-format", "json"],
      environment: environment,
      timeout: 60.0
    )

    let session: any AgentProcessSession
    do {
      session = try await runner.start(spec)
    } catch {
      return .failure(.unreachable)
    }

    let result: Result<AccountQuota, Failure>
    do {
      result = try await performRead(session: session, now: now)
    } catch let failure as Failure {
      result = .failure(failure)
    } catch {
      result = .failure(.unreachable)
    }
    await session.close()
    return result
  }

  private func performRead(
    session: any AgentProcessSession,
    now: Date
  ) async throws -> Result<AccountQuota, Failure> {
    var output = ""
    while let line = try await session.nextLine() {
      output.append(line)
      output.append("\n")
    }

    guard let firstBrace = output.firstIndex(of: "{") else {
      throw Failure.unreachable
    }

    let jsonString = output[firstBrace...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = jsonString.data(using: .utf8),
      let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw Failure.unreachable
    }

    guard let commandDict = jsonObject["command"] as? [String: Any],
      let dataDict = commandDict["data"] as? [String: Any],
      let groups = dataDict["groups"] as? [[String: Any]]
    else {
      throw Failure.malformed
    }

    var windows: [QuotaWindow] = []
    for group in groups {
      let groupName = group["name"] as? String ?? ""
      let scope = mapScope(from: groupName)
      guard let buckets = group["buckets"] as? [[String: Any]] else {
        continue
      }
      for bucket in buckets {
        if let window = parseBucket(from: bucket, scope: scope) {
          windows.append(window)
        }
      }
    }

    guard !windows.isEmpty else {
      throw Failure.malformed
    }

    return .success(
      AccountQuota(
        agent: .antigravity,
        accountName: "agy",
        windows: windows,
        observedAt: now,
        source: .agentCLI
      )
    )
  }

  private func mapScope(from groupName: String) -> String {
    switch groupName {
    case "Gemini Models":
      return "Gemini"
    case "Claude and GPT models":
      return "Claude+GPT"
    default:
      return groupName
    }
  }

  private func parseBucket(from bucket: [String: Any], scope: String) -> QuotaWindow? {
    guard let windowString = bucket["window"] as? String else { return nil }
    let windowMinutes: Int
    switch windowString {
    case "weekly":
      windowMinutes = 10080
    case "5h":
      windowMinutes = 300
    default:
      if windowString.hasSuffix("h"), let hours = Int(windowString.dropLast()) {
        windowMinutes = hours * 60
      } else if windowString.hasSuffix("d"), let days = Int(windowString.dropLast()) {
        windowMinutes = days * 1440
      } else if windowString.hasSuffix("m"), let mins = Int(windowString.dropLast()) {
        windowMinutes = mins
      } else {
        return nil
      }
    }

    let remainingFraction: Double
    if let fractionNum = bucket["remaining_fraction"] as? NSNumber {
      remainingFraction = fractionNum.doubleValue
    } else if let fractionDouble = bucket["remaining_fraction"] as? Double {
      remainingFraction = fractionDouble
    } else {
      return nil
    }

    let rawPercent = (1.0 - remainingFraction) * 100.0
    let usedPercent = max(0.0, min(100.0, rawPercent))
    let resetsAt = parseDate(bucket["reset_time"] as? String)

    return QuotaWindow(
      windowMinutes: windowMinutes,
      usedPercent: usedPercent,
      resetsAt: resetsAt,
      scope: scope
    )
  }

  private func parseDate(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return fractional.date(from: string) ?? standard.date(from: string)
  }
}
