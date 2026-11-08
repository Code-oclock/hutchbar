// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How an agent is named and drawn everywhere in the UI. Generic SF Symbols only, no brand logos.
public struct AgentInfo: Equatable, Sendable {
  public let displayName: String
  /// SF Symbol name.
  public let symbol: String
  public let color: PanelColorToken
  /// Executable name of the agent's CLI process.
  public let executable: String
}

extension AgentKind {
  public var info: AgentInfo {
    switch self {
    case .claudeCode:
      return AgentInfo(
        displayName: "Claude", symbol: "asterisk", color: .orange, executable: "claude")
    case .codex:
      return AgentInfo(displayName: "Codex", symbol: "hexagon", color: .blue, executable: "codex")
    case .antigravity:
      return AgentInfo(
        displayName: "Antigravity", symbol: "diamond.fill", color: .purple, executable: "agy")
    case .qwen:
      return AgentInfo(
        displayName: "Qwen Code", symbol: "circle.circle", color: .teal, executable: "qwen")
    case .opencode:
      return AgentInfo(
        displayName: "OpenCode", symbol: "terminal", color: .secondary, executable: "opencode")
    case .copilot:
      return AgentInfo(
        displayName: "Copilot", symbol: "airplane", color: .secondary, executable: "copilot")
    }
  }

  /// The agent whose CLI has this executable name, if any.
  public static func forExecutable(_ name: String) -> AgentKind? {
    allCases.first { $0.info.executable == name }
  }
}
