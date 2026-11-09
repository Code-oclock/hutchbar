// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Privacy-Preserving Decodables for Copilot Logs

struct CopilotRecord: Decodable, Sendable {
  let id: String?
  let type: String?
  let timestamp: String?
  let agentId: String?
  let data: CopilotData?

  init(
    id: String? = nil,
    type: String? = nil,
    timestamp: String? = nil,
    agentId: String? = nil,
    data: CopilotData? = nil
  ) {
    self.id = id
    self.type = type
    self.timestamp = timestamp
    self.agentId = agentId
    self.data = data
  }
}

struct CopilotData: Decodable, Sendable {
  let sessionId: String?
  let turnId: String?
  let gitRoot: String?
  let cwd: String?
  let repository: String?
  let phase: String?
  let toolRequests: [CopilotToolRequest]?
  let context: CopilotContext?

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case sessionIdCamel = "sessionId"
    case turnId = "turn_id"
    case turnIdCamel = "turnId"
    case gitRoot = "git_root"
    case gitRootCamel = "gitRoot"
    case cwd
    case repository
    case phase
    case toolRequests = "tool_requests"
    case toolRequestsCamel = "toolRequests"
    case context
  }

  init(
    sessionId: String? = nil,
    turnId: String? = nil,
    gitRoot: String? = nil,
    cwd: String? = nil,
    repository: String? = nil,
    phase: String? = nil,
    toolRequests: [CopilotToolRequest]? = nil,
    context: CopilotContext? = nil
  ) {
    self.sessionId = sessionId
    self.turnId = turnId
    self.gitRoot = gitRoot
    self.cwd = cwd
    self.repository = repository
    self.phase = phase
    self.toolRequests = toolRequests
    self.context = context
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.sessionId =
      (try? container.decodeIfPresent(String.self, forKey: .sessionId))
      ?? (try? container.decodeIfPresent(String.self, forKey: .sessionIdCamel))
    self.turnId =
      (try? container.decodeIfPresent(String.self, forKey: .turnId))
      ?? (try? container.decodeIfPresent(String.self, forKey: .turnIdCamel))
    self.gitRoot =
      (try? container.decodeIfPresent(String.self, forKey: .gitRoot))
      ?? (try? container.decodeIfPresent(String.self, forKey: .gitRootCamel))
    self.cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
    self.repository = try? container.decodeIfPresent(String.self, forKey: .repository)
    self.phase = try? container.decodeIfPresent(String.self, forKey: .phase)
    self.toolRequests =
      (try? container.decodeIfPresent([CopilotToolRequest].self, forKey: .toolRequests))
      ?? (try? container.decodeIfPresent([CopilotToolRequest].self, forKey: .toolRequestsCamel))
    self.context = try? container.decodeIfPresent(CopilotContext.self, forKey: .context)
  }
}

struct CopilotContext: Decodable, Sendable {
  let gitRoot: String?
  let cwd: String?
  let repository: String?

  enum CodingKeys: String, CodingKey {
    case gitRoot = "git_root"
    case gitRootCamel = "gitRoot"
    case cwd
    case repository
  }

  init(gitRoot: String? = nil, cwd: String? = nil, repository: String? = nil) {
    self.gitRoot = gitRoot
    self.cwd = cwd
    self.repository = repository
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.gitRoot =
      (try? container.decodeIfPresent(String.self, forKey: .gitRoot))
      ?? (try? container.decodeIfPresent(String.self, forKey: .gitRootCamel))
    self.cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
    self.repository = try? container.decodeIfPresent(String.self, forKey: .repository)
  }
}

struct CopilotToolRequest: Decodable, Sendable {
  init() {}
  init(from decoder: Decoder) throws {
    // Deliberately discard all tool content and arguments for privacy.
  }
}
