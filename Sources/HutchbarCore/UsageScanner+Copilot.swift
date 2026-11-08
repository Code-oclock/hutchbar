// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension UsageScanner {
  public static var defaultCopilotSessionRoot: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".copilot/session-state").path
  }

  func discoverCopilotFiles(cutoff: Date) -> [FileMetadata] {
    let resolvedRoot = (copilotSessionRoot as NSString).expandingTildeInPath
    guard let entries = try? directoryLister.contentsOfDirectory(atPath: resolvedRoot) else {
      return []
    }
    var results: [FileMetadata] = []
    for entry in entries where entry.isDirectory {
      let dirName = (entry.path as NSString).lastPathComponent
      guard !dirName.hasPrefix(".") else { continue }
      guard let files = try? directoryLister.contentsOfDirectory(atPath: entry.path) else {
        continue
      }
      for file in files where !file.isDirectory {
        let fileName = (file.path as NSString).lastPathComponent
        if fileName == "events.jsonl", file.modificationDate >= cutoff {
          results.append(file)
        }
      }
    }
    return results
  }
}

public func parseCopilotUsage(lines: [String], calendar: Calendar) -> [UsageEvent] {
  let decoder = JSONDecoder()
  var events: [UsageEvent] = []
  var seenIds = Set<String>()
  var previousTotalsByModel: [String: CopilotModelTotals] = [:]

  for line in lines {
    // The log also holds whole prompts and replies; decode only the shutdown events.
    guard line.contains("session.shutdown"),
      let data = line.data(using: .utf8),
      let envelope = try? decoder.decode(CopilotEventEnvelope.self, from: data),
      envelope.type == "session.shutdown",
      let eventId = envelope.id,
      !eventId.isEmpty
    else {
      continue
    }

    guard seenIds.insert(eventId).inserted else {
      continue
    }

    guard let timestampString = envelope.timestamp,
      let date = parseUsageTimestamp(timestampString),
      let metrics = envelope.data?.modelMetrics,
      !metrics.isEmpty
    else {
      continue
    }

    let day = calendar.startOfDay(for: date)
    let hour = calendar.component(.hour, from: date)

    for (modelKey, metric) in metrics.sorted(by: { left, right in left.key < right.key }) {
      guard !modelKey.isEmpty else { continue }

      let current = extractModelTotals(metric)
      let previous = previousTotalsByModel[modelKey]
      let delta = calculateDelta(current: current, previous: previous)
      previousTotalsByModel[modelKey] = current

      let totalDelta = delta.input + delta.output + delta.cacheRead + delta.cacheWrite
      guard totalDelta > 0 else { continue }

      let tokens = TokenUsage(
        input: delta.input,
        output: delta.output,
        cacheWrite5m: delta.cacheWrite,
        cacheWrite1h: 0,
        cacheRead: delta.cacheRead
      )

      events.append(
        UsageEvent(
          provider: .copilot,
          model: modelKey,
          day: day,
          hour: hour,
          tokens: tokens,
          isFast: false
        )
      )
    }
  }

  return events
}

private func extractModelTotals(_ metric: CopilotModelMetric) -> CopilotModelTotals {
  let input =
    metric.tokenDetails?.input?.tokenCount
    ?? metric.usage?.input
    ?? metric.usage?.inputTokens
    ?? 0
  let cacheRead =
    metric.tokenDetails?.cacheRead?.tokenCount
    ?? metric.usage?.cacheRead
    ?? metric.usage?.cacheReadTokens
    ?? 0
  let cacheWrite =
    metric.tokenDetails?.cacheWrite?.tokenCount
    ?? metric.usage?.cacheWrite
    ?? metric.usage?.cacheWriteTokens
    ?? 0
  let baseOutput =
    metric.tokenDetails?.output?.tokenCount
    ?? metric.usage?.output
    ?? metric.usage?.outputTokens
    ?? 0
  let reasoning = metric.usage?.reasoningTokens ?? 0
  let output = baseOutput + reasoning

  return CopilotModelTotals(
    input: input,
    output: output,
    cacheRead: cacheRead,
    cacheWrite: cacheWrite
  )
}

private func calculateDelta(current: CopilotModelTotals, previous: CopilotModelTotals?)
  -> (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)
{
  guard let previous else {
    return (current.input, current.output, current.cacheRead, current.cacheWrite)
  }
  if current.total < previous.total {
    return (current.input, current.output, current.cacheRead, current.cacheWrite)
  }
  return (
    max(0, current.input - previous.input),
    max(0, current.output - previous.output),
    max(0, current.cacheRead - previous.cacheRead),
    max(0, current.cacheWrite - previous.cacheWrite)
  )
}

struct CopilotModelTotals: Equatable {
  let input: Int
  let output: Int
  let cacheRead: Int
  let cacheWrite: Int

  var total: Int {
    input + output + cacheRead + cacheWrite
  }

  init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
  }
}

private struct CopilotEventEnvelope: Decodable {
  let id: String?
  let type: String?
  let timestamp: String?
  let data: CopilotEventData?

  init(
    id: String? = nil,
    type: String? = nil,
    timestamp: String? = nil,
    data: CopilotEventData? = nil
  ) {
    self.id = id
    self.type = type
    self.timestamp = timestamp
    self.data = data
  }
}

private struct CopilotEventData: Decodable {
  let modelMetrics: [String: CopilotModelMetric]?

  init(modelMetrics: [String: CopilotModelMetric]? = nil) {
    self.modelMetrics = modelMetrics
  }
}

private struct CopilotModelMetric: Decodable {
  let usage: CopilotUsageNumbers?
  let tokenDetails: CopilotTokenDetails?

  init(
    usage: CopilotUsageNumbers? = nil,
    tokenDetails: CopilotTokenDetails? = nil
  ) {
    self.usage = usage
    self.tokenDetails = tokenDetails
  }
}

private struct CopilotUsageNumbers: Decodable {
  let inputTokens: Int?
  let input: Int?
  let outputTokens: Int?
  let output: Int?
  let cacheReadTokens: Int?
  let cacheRead: Int?
  let cacheWriteTokens: Int?
  let cacheWrite: Int?
  let reasoningTokens: Int?

  enum CodingKeys: String, CodingKey {
    case inputTokens
    case input
    case outputTokens
    case output
    case cacheReadTokens
    case cacheRead = "cache_read"
    case cacheWriteTokens
    case cacheWrite = "cache_write"
    case reasoningTokens
  }

  init(
    inputTokens: Int? = nil,
    input: Int? = nil,
    outputTokens: Int? = nil,
    output: Int? = nil,
    cacheReadTokens: Int? = nil,
    cacheRead: Int? = nil,
    cacheWriteTokens: Int? = nil,
    cacheWrite: Int? = nil,
    reasoningTokens: Int? = nil
  ) {
    self.inputTokens = inputTokens
    self.input = input
    self.outputTokens = outputTokens
    self.output = output
    self.cacheReadTokens = cacheReadTokens
    self.cacheRead = cacheRead
    self.cacheWriteTokens = cacheWriteTokens
    self.cacheWrite = cacheWrite
    self.reasoningTokens = reasoningTokens
  }
}

private struct CopilotTokenDetails: Decodable {
  let input: CopilotTokenCount?
  let cacheRead: CopilotTokenCount?
  let cacheWrite: CopilotTokenCount?
  let output: CopilotTokenCount?

  enum CodingKeys: String, CodingKey {
    case input
    case cacheRead = "cache_read"
    case cacheWrite = "cache_write"
    case output
  }

  init(
    input: CopilotTokenCount? = nil,
    cacheRead: CopilotTokenCount? = nil,
    cacheWrite: CopilotTokenCount? = nil,
    output: CopilotTokenCount? = nil
  ) {
    self.input = input
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.output = output
  }
}

private struct CopilotTokenCount: Decodable {
  let tokenCount: Int?

  init(tokenCount: Int? = nil) {
    self.tokenCount = tokenCount
  }
}
