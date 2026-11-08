// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How to start an agent CLI for a short, structured conversation
/// (see docs/specs/limits-v3.md, section 2).
public struct AgentProcessSpec: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  /// The complete environment of the child; nothing is inherited.
  public let environment: [String: String]
  public let timeout: TimeInterval

  public init(
    executable: String, arguments: [String], environment: [String: String],
    timeout: TimeInterval
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.timeout = timeout
  }
}

/// One running conversation with an agent CLI over stdin/stdout, one JSON value per line.
public protocol AgentProcessSession: Sendable {
  /// Writes one line (a newline is appended).
  func send(_ line: String) async throws
  /// Next stdout line, or nil when stdout closed. Throws `AgentProcessError.timeout`
  /// once the spec's deadline (counted from start) has passed.
  func nextLine() async throws -> String?
  /// Terminates the child if it still runs. Safe to call more than once.
  func close() async
}

/// Starts agent CLI processes. Tests use a fake that replays scripted lines.
public protocol AgentProcessRunner: Sendable {
  func start(_ spec: AgentProcessSpec) async throws -> any AgentProcessSession
}

public enum AgentProcessError: Error, Equatable, Sendable {
  case launchFailed
  case timeout
  case closed
}

/// Builds the child environment: an allow-list copied from `base`, never agent
/// credentials or overrides (docs/specs/limits-v3.md, section 2).
public enum AgentProcessEnvironment {
  static let copied: Set<String> = [
    "HOME", "USER", "LOGNAME", "TMPDIR", "LANG",
    "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
    "https_proxy", "http_proxy", "no_proxy", "all_proxy",
    "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE",
  ]

  public static func make(
    base: [String: String], executable: String, extra: [String: String] = [:]
  ) -> [String: String] {
    var env: [String: String] = [:]
    for (key, value) in base where copied.contains(key) || key.hasPrefix("LC_") {
      env[key] = value
    }
    let directory = (executable as NSString).deletingLastPathComponent
    env["PATH"] = directory + ":/usr/bin:/bin:/usr/sbin:/sbin"
    for (key, value) in extra {
      env[key] = value
    }
    return env
  }
}
