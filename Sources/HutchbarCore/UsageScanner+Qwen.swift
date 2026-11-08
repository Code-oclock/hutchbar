// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension UsageScanner {
  public static var defaultQwenUsageRoot: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".qwen/usage").path
  }

  func discoverQwenFiles(cutoff: Date, now: Date) -> [FileMetadata] {
    let resolvedRoot = (qwenUsageRoot as NSString).expandingTildeInPath
    guard let entries = try? directoryLister.contentsOfDirectory(atPath: resolvedRoot) else {
      return []
    }
    var results: [FileMetadata] = []
    for entry in entries where !entry.isDirectory && entry.path.hasSuffix(".jsonl") {
      let fileName = (entry.path as NSString).lastPathComponent
      guard fileName.hasPrefix("token-usage-") else { continue }
      if isQwenFileInCutoff(
        fileName: fileName, modificationDate: entry.modificationDate, cutoff: cutoff)
      {
        results.append(entry)
      }
    }
    return results
  }

  private func isQwenFileInCutoff(fileName: String, modificationDate: Date, cutoff: Date) -> Bool {
    guard modificationDate >= cutoff else { return false }
    let prefixCount = "token-usage-".count
    let suffixCount = ".jsonl".count
    guard fileName.count > prefixCount + suffixCount else { return false }
    let base = String(fileName.dropFirst(prefixCount).dropLast(suffixCount))
    let parts = base.split(separator: "-")
    guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else {
      return true
    }

    var comp = DateComponents()
    comp.year = (month == 12) ? year + 1 : year
    comp.month = (month == 12) ? 1 : month + 1
    comp.day = 1
    let gmtCal = Calendar(identifier: .gregorian)
    if let nextMonthStart = gmtCal.date(from: comp), nextMonthStart <= cutoff {
      return false
    }
    return true
  }
}

public func parseQwenUsage(
  lines: [String],
  seenIds: inout Set<String>,
  calendar: Calendar
) -> [UsageEvent] {
  let decoder = JSONDecoder()
  var events: [UsageEvent] = []

  for line in lines {
    guard !line.isEmpty,
      let data = line.data(using: .utf8),
      let record = try? decoder.decode(QwenUsageRecord.self, from: data),
      let recordId = record.id,
      !recordId.isEmpty
    else {
      continue
    }

    if !seenIds.insert(recordId).inserted {
      continue
    }

    guard let timestampString = record.timestamp,
      let date = parseUsageTimestamp(timestampString),
      let model = record.model,
      !model.isEmpty
    else {
      continue
    }

    let inputTotal = record.inputTokens ?? 0
    let cached = record.cachedTokens ?? 0
    let output = record.outputTokens ?? 0
    let freshInput = max(0, inputTotal - cached)

    let tokens = TokenUsage(
      input: freshInput,
      output: output,
      cacheWrite5m: 0,
      cacheWrite1h: 0,
      cacheRead: cached
    )

    let day = calendar.startOfDay(for: date)
    let hour = calendar.component(.hour, from: date)
    events.append(
      UsageEvent(
        provider: .qwen,
        model: model,
        day: day,
        hour: hour,
        tokens: tokens,
        isFast: false
      )
    )
  }

  return events
}

private struct QwenUsageRecord: Decodable {
  let id: String?
  let timestamp: String?
  let model: String?
  let inputTokens: Int?
  let outputTokens: Int?
  let cachedTokens: Int?

  init(
    id: String? = nil,
    timestamp: String? = nil,
    model: String? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    cachedTokens: Int? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.model = model
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cachedTokens = cachedTokens
  }
}
