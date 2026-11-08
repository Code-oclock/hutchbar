// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Token counts partitioned by usage category.
public struct TokenUsage: Equatable, Sendable, Codable {
  public var input: Int
  public var output: Int
  public var cacheWrite5m: Int
  public var cacheWrite1h: Int
  public var cacheRead: Int

  public static let zero = TokenUsage(
    input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)

  public init(
    input: Int = 0,
    output: Int = 0,
    cacheWrite5m: Int = 0,
    cacheWrite1h: Int = 0,
    cacheRead: Int = 0
  ) {
    self.input = input
    self.output = output
    self.cacheWrite5m = cacheWrite5m
    self.cacheWrite1h = cacheWrite1h
    self.cacheRead = cacheRead
  }

  public var total: Int {
    input + output + cacheWrite5m + cacheWrite1h + cacheRead
  }

  public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
    TokenUsage(
      input: lhs.input + rhs.input,
      output: lhs.output + rhs.output,
      cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
      cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
      cacheRead: lhs.cacheRead + rhs.cacheRead
    )
  }

  public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
    lhs = lhs + rhs
  }
}

/// A parsed token usage event anchored to a calendar day and hour.
public struct UsageEvent: Equatable, Sendable, Codable {
  public let provider: AgentKind
  public let model: String
  /// Local start-of-day date.
  public let day: Date
  /// Local hour of the day (0...23).
  public let hour: Int
  public let tokens: TokenUsage

  public init(
    provider: AgentKind,
    model: String,
    day: Date,
    hour: Int,
    tokens: TokenUsage
  ) {
    self.provider = provider
    self.model = model
    self.day = day
    self.hour = hour
    self.tokens = tokens
  }
}

/// Tracks parser state across consecutive records within one Codex session log.
public struct CodexUsageState: Equatable, Sendable {
  public var lastModel: String?
  public var lastTotalUsage: TokenUsage?

  public init(lastModel: String? = nil, lastTotalUsage: TokenUsage? = nil) {
    self.lastModel = lastModel
    self.lastTotalUsage = lastTotalUsage
  }
}

// MARK: - Claude Parsing

/// Parses raw lines from a Claude Code JSONL transcript into usage events.
///
/// Deduplicates by `message.id`, skips `<synthetic>` models, and falls back
/// `cache_creation_input_tokens` to 5-minute ephemeral write tokens.
public func parseClaudeUsage(
  lines: [String],
  seenMessageIds: inout Set<String>,
  calendar: Calendar
) -> [UsageEvent] {
  let decoder = JSONDecoder()
  var events: [UsageEvent] = []

  for line in lines {
    guard !line.isEmpty,
      let data = line.data(using: .utf8),
      let record = try? decoder.decode(ClaudeUsageRecord.self, from: data),
      record.type == "assistant",
      let message = record.message,
      let model = message.model,
      model != "<synthetic>",
      let messageId = message.id,
      !messageId.isEmpty
    else {
      continue
    }

    if !seenMessageIds.insert(messageId).inserted {
      continue
    }

    guard let timestampString = record.timestamp,
      let date = parseUsageTimestamp(timestampString)
    else {
      continue
    }

    let usage = message.usage
    let input = usage?.inputTokens ?? 0
    let output = usage?.outputTokens ?? 0
    let cacheRead = usage?.cacheReadInputTokens ?? 0

    let write5m: Int
    let write1h: Int
    if let cacheCreation = usage?.cacheCreation,
      (cacheCreation.ephemeral5mInputTokens != nil || cacheCreation.ephemeral1hInputTokens != nil)
    {
      write5m = cacheCreation.ephemeral5mInputTokens ?? 0
      write1h = cacheCreation.ephemeral1hInputTokens ?? 0
    } else {
      write5m = usage?.cacheCreationInputTokens ?? 0
      write1h = 0
    }

    let tokens = TokenUsage(
      input: input,
      output: output,
      cacheWrite5m: write5m,
      cacheWrite1h: write1h,
      cacheRead: cacheRead
    )

    let day = calendar.startOfDay(for: date)
    let hour = calendar.component(.hour, from: date)
    events.append(
      UsageEvent(provider: .claudeCode, model: model, day: day, hour: hour, tokens: tokens)
    )
  }

  return events
}

// MARK: - Codex Parsing

/// Parses raw lines from a Codex session rollout log into usage events.
///
/// Uses `last_token_usage` when present, else the delta of `total_token_usage`.
/// The model is taken from the latest `turn_context.model`.
// A single linear pass over Codex records; splitting it would scatter the delta state.
// swiftlint:disable:next function_body_length
public func parseCodexUsage(
  lines: [String],
  state: inout CodexUsageState,
  calendar: Calendar
) -> [UsageEvent] {
  let decoder = JSONDecoder()
  var events: [UsageEvent] = []

  for line in lines {
    guard !line.isEmpty,
      let data = line.data(using: .utf8),
      let record = try? decoder.decode(CodexUsageRecord.self, from: data)
    else {
      continue
    }

    if let candidateModel = record.payload?.turnContext?.model
      ?? record.turnContext?.model
      ?? record.payload?.model
      ?? record.model,
      !candidateModel.isEmpty
    {
      state.lastModel = candidateModel
    }

    let isTokenCount =
      record.type == "token_count"
      || record.payload?.type == "token_count"
      || record.payload?.info?.lastTokenUsage != nil
      || record.payload?.info?.totalTokenUsage != nil
      || record.payload?.lastTokenUsage != nil
      || record.payload?.totalTokenUsage != nil
      || record.info?.lastTokenUsage != nil
      || record.info?.totalTokenUsage != nil

    guard isTokenCount, let date = record.timestamp?.date else {
      continue
    }

    let lastUsage =
      record.payload?.info?.lastTokenUsage
      ?? record.info?.lastTokenUsage
      ?? record.payload?.lastTokenUsage
    let totalUsage =
      record.payload?.info?.totalTokenUsage
      ?? record.info?.totalTokenUsage
      ?? record.payload?.totalTokenUsage

    let tokens: TokenUsage
    if let lastUsage {
      let input = lastUsage.inputTokens ?? 0
      let output = lastUsage.outputTokens ?? 0
      let cached = lastUsage.cachedInputTokens ?? 0
      tokens = TokenUsage(
        input: input,
        output: output,
        cacheWrite5m: 0,
        cacheWrite1h: 0,
        cacheRead: cached
      )
      if let totalUsage {
        state.lastTotalUsage = TokenUsage(
          input: totalUsage.inputTokens ?? 0,
          output: totalUsage.outputTokens ?? 0,
          cacheWrite5m: 0,
          cacheWrite1h: 0,
          cacheRead: totalUsage.cachedInputTokens ?? 0
        )
      }
    } else if let totalUsage {
      let currentTotal = TokenUsage(
        input: totalUsage.inputTokens ?? 0,
        output: totalUsage.outputTokens ?? 0,
        cacheWrite5m: 0,
        cacheWrite1h: 0,
        cacheRead: totalUsage.cachedInputTokens ?? 0
      )
      let previousTotal = state.lastTotalUsage ?? .zero
      let deltaInput = max(0, currentTotal.input - previousTotal.input)
      let deltaOutput = max(0, currentTotal.output - previousTotal.output)
      let deltaCached = max(0, currentTotal.cacheRead - previousTotal.cacheRead)
      tokens = TokenUsage(
        input: deltaInput,
        output: deltaOutput,
        cacheWrite5m: 0,
        cacheWrite1h: 0,
        cacheRead: deltaCached
      )
      state.lastTotalUsage = currentTotal
    } else {
      continue
    }

    guard tokens.total > 0 else { continue }

    let model = state.lastModel ?? "unknown"
    let day = calendar.startOfDay(for: date)
    let hour = calendar.component(.hour, from: date)
    events.append(
      UsageEvent(provider: .codex, model: model, day: day, hour: hour, tokens: tokens)
    )
  }

  return events
}

// MARK: - Privacy-Preserving Decodables

private struct ClaudeUsageRecord: Decodable {
  let type: String?
  let timestamp: String?
  let message: ClaudeUsageMessage?
}

private struct ClaudeUsageMessage: Decodable {
  let id: String?
  let model: String?
  let usage: ClaudeUsageDetails?
}

private struct ClaudeUsageDetails: Decodable {
  let inputTokens: Int?
  let outputTokens: Int?
  let cacheReadInputTokens: Int?
  let cacheCreationInputTokens: Int?
  let cacheCreation: ClaudeCacheCreationDetails?

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
    case cacheCreation = "cache_creation"
  }
}

private struct ClaudeCacheCreationDetails: Decodable {
  let ephemeral5mInputTokens: Int?
  let ephemeral1hInputTokens: Int?

  enum CodingKeys: String, CodingKey {
    case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
    case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
  }
}

private struct CodexUsageRecord: Decodable {
  let type: String?
  let timestamp: FlexibleDateValue?
  let payload: CodexUsagePayload?
  let model: String?
  let turnContext: CodexNestedModel?
  let info: CodexUsageInfo?

  enum CodingKeys: String, CodingKey {
    case type, timestamp, payload, model
    case turnContext = "turn_context"
    case info
  }
}

private struct CodexUsagePayload: Decodable {
  let type: String?
  let model: String?
  let turnContext: CodexNestedModel?
  let info: CodexUsageInfo?
  let lastTokenUsage: CodexUsageTokens?
  let totalTokenUsage: CodexUsageTokens?

  enum CodingKeys: String, CodingKey {
    case type, model
    case turnContext = "turn_context"
    case info
    case lastTokenUsage = "last_token_usage"
    case totalTokenUsage = "total_token_usage"
  }
}

private struct CodexNestedModel: Decodable {
  let model: String?
}

private struct CodexUsageInfo: Decodable {
  let lastTokenUsage: CodexUsageTokens?
  let totalTokenUsage: CodexUsageTokens?

  enum CodingKeys: String, CodingKey {
    case lastTokenUsage = "last_token_usage"
    case totalTokenUsage = "total_token_usage"
  }
}

private struct CodexUsageTokens: Decodable {
  let inputTokens: Int?
  let cachedInputTokens: Int?
  let outputTokens: Int?

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case cachedInputTokens = "cached_input_tokens"
    case outputTokens = "output_tokens"
  }
}

private struct FlexibleDateValue: Decodable {
  let date: Date?

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      date = nil
      return
    }
    if let str = try? container.decode(String.self) {
      date = parseUsageTimestamp(str)
      return
    }
    if let num = try? container.decode(Double.self) {
      if num > 100_000_000_000 {
        date = Date(timeIntervalSince1970: num / 1000.0)
      } else {
        date = Date(timeIntervalSince1970: num)
      }
      return
    }
    date = nil
  }
}

func parseUsageTimestamp(_ string: String) -> Date? {
  if let date = try? Date(string, strategy: .iso8601) { return date }
  let withFraction = ISO8601DateFormatter()
  withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = withFraction.date(from: string) { return date }
  let basic = ISO8601DateFormatter()
  basic.formatOptions = [.withInternetDateTime]
  return basic.date(from: string)
}
