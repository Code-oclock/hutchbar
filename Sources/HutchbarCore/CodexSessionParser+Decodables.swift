// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Decodable Schema (Privacy-Preserving)

struct CodexRecord: Decodable {
  let type: String?
  let timestamp: FlexibleTimestamp?
  let payload: CodexPayload?

  init(type: String? = nil, timestamp: FlexibleTimestamp? = nil, payload: CodexPayload? = nil) {
    self.type = type
    self.timestamp = timestamp
    self.payload = payload
  }
}

struct CodexSource: Decodable {
  let isChild: Bool

  enum CodingKeys: String, CodingKey {
    case subagent
    case `internal`
  }

  init(isChild: Bool = false) {
    self.isChild = isChild
  }

  init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: CodingKeys.self) {
      let isSubagentNil = (try? container.decodeNil(forKey: .subagent)) ?? true
      let isInternalNil = (try? container.decodeNil(forKey: .internal)) ?? true
      let sub = container.contains(.subagent) && !isSubagentNil
      let inter = container.contains(.internal) && !isInternalNil
      self.isChild = sub || inter
      return
    }
    if let single = try? decoder.singleValueContainer(),
      let str = try? single.decode(String.self)
    {
      self.isChild = (str == "subagent" || str == "internal")
      return
    }
    self.isChild = false
  }
}

struct CodexPayload: Decodable {
  let id: String?
  let sessionId: String?
  let parentThreadId: String?
  let source: CodexSource?
  let cwd: String?
  let timestamp: FlexibleTimestamp?
  let type: String?
  let rateLimits: CodexRateLimits?

  enum CodingKeys: String, CodingKey {
    case id
    case sessionId = "session_id"
    case parentThreadId = "parent_thread_id"
    case source
    case cwd
    case timestamp
    case type
    case rateLimits = "rate_limits"
  }

  init(
    id: String? = nil,
    sessionId: String? = nil,
    parentThreadId: String? = nil,
    source: CodexSource? = nil,
    cwd: String? = nil,
    timestamp: FlexibleTimestamp? = nil,
    type: String? = nil,
    rateLimits: CodexRateLimits? = nil
  ) {
    self.id = id
    self.sessionId = sessionId
    self.parentThreadId = parentThreadId
    self.source = source
    self.cwd = cwd
    self.timestamp = timestamp
    self.type = type
    self.rateLimits = rateLimits
  }
}

struct CodexRateLimits: Decodable {
  let planType: String?
  let primary: CodexRateLimitWindow?
  let secondary: CodexRateLimitWindow?

  enum CodingKeys: String, CodingKey {
    case planType = "plan_type"
    case primary
    case secondary
  }

  init(
    planType: String? = nil,
    primary: CodexRateLimitWindow? = nil,
    secondary: CodexRateLimitWindow? = nil
  ) {
    self.planType = planType
    self.primary = primary
    self.secondary = secondary
  }
}

struct CodexRateLimitWindow: Decodable {
  let usedPercent: Double?
  let windowMinutes: Int?
  let resetsAt: FlexibleDate?

  enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case windowMinutes = "window_minutes"
    case resetsAt = "resets_at"
  }

  init(usedPercent: Double? = nil, windowMinutes: Int? = nil, resetsAt: FlexibleDate? = nil) {
    self.usedPercent = usedPercent
    self.windowMinutes = windowMinutes
    self.resetsAt = resetsAt
  }
}

struct FlexibleTimestamp: Decodable {
  let string: String?
  let date: Date?

  init(string: String? = nil, date: Date? = nil) {
    self.string = string
    self.date = date
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      string = nil
      date = nil
      return
    }
    if let str = try? container.decode(String.self) {
      string = str
      date = CodexSessionParser.parseDate(str)
      return
    }
    if let number = try? container.decode(Double.self) {
      string = nil
      if number > 100_000_000_000 {
        date = Date(timeIntervalSince1970: number / 1000.0)
      } else {
        date = Date(timeIntervalSince1970: number)
      }
      return
    }
    string = nil
    date = nil
  }
}

struct FlexibleDate: Decodable {
  let date: Date?

  init(date: Date? = nil) {
    self.date = date
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      date = nil
      return
    }
    if let seconds = try? container.decode(Double.self) {
      date = Date(timeIntervalSince1970: seconds)
      return
    }
    if let string = try? container.decode(String.self) {
      if let seconds = Double(string) {
        date = Date(timeIntervalSince1970: seconds)
        return
      }
      date = CodexSessionParser.parseDate(string)
      return
    }
    date = nil
  }
}
