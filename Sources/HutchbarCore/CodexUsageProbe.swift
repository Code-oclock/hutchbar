// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// A discovered Codex profile configuration directory.
public struct CodexProfile: Equatable, Sendable, Identifiable, Hashable {
  public var id: String { path }
  public let path: String
  public let isDefault: Bool

  public init(path: String, isDefault: Bool = false) {
    self.path = path
    self.isDefault = isDefault
  }

  public var directoryName: String {
    (path as NSString).lastPathComponent
  }

  public var directoryPath: String {
    path
  }
}

/// POSIX file attributes required for profile security validation.
public struct CodexFileAttributes: Equatable, Sendable {
  public let ownerUID: UInt32
  public let posixMode: UInt16
  public let isDirectory: Bool

  public init(ownerUID: UInt32, posixMode: UInt16, isDirectory: Bool) {
    self.ownerUID = ownerUID
    self.posixMode = posixMode
    self.isDirectory = isDirectory
  }

  /// Whether the file is writable by group or others (mode & 0o022 != 0).
  public var isGroupOrWorldWritable: Bool {
    (posixMode & 0o022) != 0
  }
}

/// Filesystem access interface for profile discovery and validation.
public protocol CodexFileSystem: Sendable {
  var homeDirectoryPath: String { get }
  var currentUID: UInt32 { get }
  func contentsOfDirectory(atPath path: String) throws -> [String]
  func itemExists(atPath path: String) -> Bool
  func posixAttributes(atPath path: String) throws -> CodexFileAttributes
}

/// Default filesystem implementation backed by Darwin POSIX calls.
public struct DefaultCodexFileSystem: CodexFileSystem, Sendable {
  public init() {}

  public var homeDirectoryPath: String {
    FileManager.default.homeDirectoryForCurrentUser.path
  }

  public var currentUID: UInt32 {
    getuid()
  }

  public func contentsOfDirectory(atPath path: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: path)
  }

  public func itemExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func posixAttributes(atPath path: String) throws -> CodexFileAttributes {
    var statInfo = stat()
    guard stat(path, &statInfo) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }
    let isDir = (statInfo.st_mode & S_IFMT) == S_IFDIR
    return CodexFileAttributes(
      ownerUID: statInfo.st_uid,
      posixMode: UInt16(statInfo.st_mode & 0o7777),
      isDirectory: isDir
    )
  }
}

/// Probes quota limits from `codex app-server` via JSON-RPC 2.0.
public struct CodexUsageProbe: Sendable {
  public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
    case missing
    case needsSignIn
    case unreachable
    case malformed

    public var description: String {
      switch self {
      case .missing: "missing"
      case .needsSignIn: "needsSignIn"
      case .unreachable: "unreachable"
      case .malformed: "malformed"
      }
    }
  }

  public let executable: String
  public let runner: any AgentProcessRunner
  public let fileSystem: any CodexFileSystem
  public let baseEnvironment: [String: String]
  public let appVersion: String

  public init(
    executable: String,
    runner: any AgentProcessRunner,
    fileSystem: any CodexFileSystem = DefaultCodexFileSystem(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    appVersion: String = "0.1.0"
  ) {
    self.executable = executable
    self.runner = runner
    self.fileSystem = fileSystem
    self.baseEnvironment = baseEnvironment
    self.appVersion = appVersion
  }

  /// Discovers valid profiles: default ~/.codex and up to 8 ~/.codex-* directories.
  public func profiles() -> [CodexProfile] {
    var result: [CodexProfile] = []
    let home = fileSystem.homeDirectoryPath

    let defaultPath = (home as NSString).appendingPathComponent(".codex")
    if isProfileDirectoryValid(defaultPath) {
      result.append(CodexProfile(path: defaultPath, isDefault: true))
    }

    let entries = (try? fileSystem.contentsOfDirectory(atPath: home)) ?? []
    let customNames = entries.filter { $0.hasPrefix(".codex-") }.sorted()

    var validCustom: [CodexProfile] = []
    for name in customNames {
      let path = (home as NSString).appendingPathComponent(name)
      if isProfileDirectoryValid(path) {
        validCustom.append(CodexProfile(path: path, isDefault: false))
        if validCustom.count == 8 {
          break
        }
      }
    }

    result.append(contentsOf: validCustom)
    return result
  }

  private func isProfileDirectoryValid(_ path: String) -> Bool {
    guard let attrs = try? fileSystem.posixAttributes(atPath: path),
      attrs.isDirectory,
      attrs.ownerUID == fileSystem.currentUID,
      !attrs.isGroupOrWorldWritable
    else {
      return false
    }
    let authPath = (path as NSString).appendingPathComponent("auth.json")
    return fileSystem.itemExists(atPath: authPath)
  }

  /// Reads quota information for a given profile.
  public func read(
    _ profile: CodexProfile,
    now: Date = Date()
  ) async -> Result<AccountQuota, Failure> {
    var extra: [String: String] = [:]
    if !profile.isDefault {
      extra["CODEX_HOME"] = profile.path
    }
    let env = AgentProcessEnvironment.make(
      base: baseEnvironment,
      executable: executable,
      extra: extra
    )
    let spec = AgentProcessSpec(
      executable: executable,
      arguments: ["-c", "features.plugins=false", "app-server"],
      environment: env,
      timeout: 25.0
    )

    let session: any AgentProcessSession
    do {
      session = try await runner.start(spec)
    } catch let error as AgentProcessError {
      if error == .launchFailed {
        return .failure(.missing)
      }
      return .failure(.unreachable)
    } catch {
      return .failure(.unreachable)
    }

    let result: Result<AccountQuota, Failure>
    do {
      result = try await converse(session: session, profile: profile, now: now)
    } catch let failure as Failure {
      result = .failure(failure)
    } catch {
      result = .failure(.unreachable)
    }

    await session.close()
    return result
  }

  private func converse(
    session: any AgentProcessSession,
    profile: CodexProfile,
    now: Date
  ) async throws -> Result<AccountQuota, Failure> {
    try await sendInitialize(session: session)
    _ = try await receiveResponse(expectedId: 1, session: session)

    try await session.send("{\"method\":\"initialized\"}")

    try await session.send(
      "{\"id\":2,\"method\":\"account/read\",\"params\":{\"refreshToken\":false}}"
    )
    let accountResult = try await receiveResponse(expectedId: 2, session: session)
    let (accountName, accountPlan) = try parseAccount(accountResult, profile: profile)

    try await session.send(
      "{\"id\":3,\"method\":\"account/rateLimits/read\",\"params\":{}}"
    )
    let limitsResult = try await receiveResponse(expectedId: 3, session: session)
    let (windows, limitsPlan, resetCredits) = try parseRateLimits(limitsResult)

    let quota = AccountQuota(
      agent: .codex,
      accountName: accountName,
      windows: windows,
      observedAt: now,
      source: .agentCLI,
      plan: accountPlan ?? limitsPlan,
      resetCredits: resetCredits
    )
    return .success(quota)
  }

  private func sendInitialize(session: any AgentProcessSession) async throws {
    let escaped = jsonEscape(appVersion)
    let line =
      "{\"id\":1,\"method\":\"initialize\",\"params\":{"
      + "\"clientInfo\":{\"name\":\"hutchbar\",\"title\":\"hutchbar\",\"version\":\(escaped)},"
      + "\"capabilities\":null}}"
    try await session.send(line)
  }

  private func receiveResponse(
    expectedId: Int,
    session: any AgentProcessSession
  ) async throws -> [String: Any] {
    while true {
      let rawLine: String?
      do {
        rawLine = try await session.nextLine()
      } catch {
        throw Failure.unreachable
      }

      guard let rawLine else {
        throw Failure.unreachable
      }

      let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }

      guard let data = trimmed.data(using: .utf8),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else {
        throw Failure.malformed
      }

      guard let rawId = json["id"], !(rawId is NSNull) else {
        // Notification without id: skip
        continue
      }

      let id: Int?
      if let intId = rawId as? Int {
        id = intId
      } else if let numId = rawId as? NSNumber {
        id = numId.intValue
      } else {
        id = nil
      }

      guard let id, id == expectedId else {
        // Unrelated id: skip
        continue
      }

      if json["error"] != nil && !(json["error"] is NSNull) {
        throw Failure.malformed
      }

      guard let result = json["result"] as? [String: Any] else {
        throw Failure.malformed
      }

      return result
    }
  }

  private func parseAccount(
    _ result: [String: Any],
    profile: CodexProfile
  ) throws -> (String, String?) {
    guard let account = result["account"] as? [String: Any] else {
      throw Failure.malformed
    }
    guard let accountType = account["type"] as? String else {
      throw Failure.malformed
    }
    guard accountType == "chatgpt" else {
      throw Failure.needsSignIn
    }

    let plan = account["planType"] as? String
    let rawEmail = account["email"] as? String
    let name = resolveAccountName(email: rawEmail, fallback: profile.directoryName)
    return (name, plan)
  }

  private func resolveAccountName(email: String?, fallback: String) -> String {
    guard let email, !email.isEmpty else { return fallback }
    let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2, let first = parts.first, !first.isEmpty {
      return String(first)
    }
    return fallback
  }

  private func parseRateLimits(
    _ result: [String: Any]
  ) throws -> ([QuotaWindow], String?, Int?) {
    let container: [String: Any]?
    if let byLimitId = result["rateLimitsByLimitId"] as? [String: Any],
      let codex = byLimitId["codex"] as? [String: Any]
    {
      container = codex
    } else if let direct = result["rateLimits"] as? [String: Any] {
      container = direct
    } else {
      container = nil
    }

    guard let container else {
      throw Failure.malformed
    }

    var windows: [QuotaWindow] = []
    if let primary = container["primary"] as? [String: Any],
      let win = parseQuotaWindow(primary)
    {
      windows.append(win)
    }
    if let secondary = container["secondary"] as? [String: Any],
      let win = parseQuotaWindow(secondary)
    {
      windows.append(win)
    }

    let plan = container["planType"] as? String
    var resetCredits: Int?
    if let creditsDict = result["rateLimitResetCredits"] as? [String: Any] {
      if let count = creditsDict["availableCount"] as? Int {
        resetCredits = count
      } else if let countNum = creditsDict["availableCount"] as? NSNumber {
        resetCredits = countNum.intValue
      }
    }

    return (windows, plan, resetCredits)
  }

  private func parseQuotaWindow(_ dict: [String: Any]) -> QuotaWindow? {
    let windowMinutes: Int?
    if let mins = dict["windowDurationMins"] as? Int {
      windowMinutes = mins
    } else if let minsNum = dict["windowDurationMins"] as? NSNumber {
      windowMinutes = minsNum.intValue
    } else {
      windowMinutes = nil
    }

    guard let windowMinutes else { return nil }

    let usedPercent: Double?
    if let percent = dict["usedPercent"] as? Double {
      usedPercent = percent
    } else if let percentInt = dict["usedPercent"] as? Int {
      usedPercent = Double(percentInt)
    } else if let percentNum = dict["usedPercent"] as? NSNumber {
      usedPercent = percentNum.doubleValue
    } else {
      usedPercent = nil
    }

    guard let usedPercent else { return nil }

    let resetsAt: Date?
    if let epoch = dict["resetsAt"] as? TimeInterval {
      resetsAt = Date(timeIntervalSince1970: epoch)
    } else if let epochInt = dict["resetsAt"] as? Int {
      resetsAt = Date(timeIntervalSince1970: TimeInterval(epochInt))
    } else if let epochNum = dict["resetsAt"] as? NSNumber {
      resetsAt = Date(timeIntervalSince1970: epochNum.doubleValue)
    } else {
      resetsAt = nil
    }

    return QuotaWindow(
      windowMinutes: windowMinutes,
      usedPercent: usedPercent,
      resetsAt: resetsAt
    )
  }

  private func jsonEscape(_ string: String) -> String {
    if let data = try? JSONEncoder().encode(string),
      let json = String(data: data, encoding: .utf8)
    {
      return json
    }
    let escaped =
      string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
