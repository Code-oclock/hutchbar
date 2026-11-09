// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension UsageScanner {
  public static var defaultGeminiTmpRoot: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".gemini/tmp").path
  }

  func discoverGeminiFiles(cutoff: Date) -> [FileMetadata] {
    let resolvedRoot = (geminiTmpRoot as NSString).expandingTildeInPath
    guard let projectEntries = try? directoryLister.contentsOfDirectory(atPath: resolvedRoot) else {
      return []
    }
    var results: [FileMetadata] = []
    for projectDir in projectEntries where projectDir.isDirectory {
      let dirName = (projectDir.path as NSString).lastPathComponent
      guard !dirName.hasPrefix(".") else { continue }
      let chatsDirPath = (projectDir.path as NSString).appendingPathComponent("chats")
      guard let chatFiles = try? directoryLister.contentsOfDirectory(atPath: chatsDirPath) else {
        continue
      }
      for chatFile in chatFiles where !chatFile.isDirectory {
        let fileName = (chatFile.path as NSString).lastPathComponent
        guard fileName.hasPrefix("session-") && fileName.hasSuffix(".json") else { continue }
        if chatFile.modificationDate >= cutoff {
          results.append(chatFile)
        }
      }
    }
    return results
  }
}

public func parseGeminiUsage(lines: [String], calendar: Calendar) -> [UsageEvent] {
  let text = lines.joined(separator: "\n")
  guard let jsonData = text.data(using: .utf8),
    let record = try? JSONDecoder().decode(GeminiSessionRecord.self, from: jsonData),
    let messages = record.messages
  else {
    return []
  }

  var events: [UsageEvent] = []
  var seenIds = Set<String>()

  for message in messages {
    guard message.type == "gemini",
      let messageId = message.id,
      !messageId.isEmpty,
      seenIds.insert(messageId).inserted
    else {
      continue
    }

    guard let tokenRecord = message.tokens else { continue }
    let rawInput = tokenRecord.input ?? 0
    let cached = tokenRecord.cached ?? 0
    let baseOutput = tokenRecord.output ?? 0
    let thoughts = tokenRecord.thoughts ?? 0

    let freshInput = max(0, rawInput - cached)
    let totalOutput = baseOutput + thoughts
    let cacheRead = cached

    guard freshInput > 0 || totalOutput > 0 || cacheRead > 0 else { continue }

    guard let timestampString = message.timestamp,
      let dateVal = parseUsageTimestamp(timestampString)
    else {
      continue
    }

    let modelName: String
    if let candidateModel = message.model?.trimmingCharacters(in: .whitespacesAndNewlines),
      !candidateModel.isEmpty
    {
      modelName = candidateModel
    } else {
      modelName = "gemini"
    }

    let dayDate = calendar.startOfDay(for: dateVal)
    let hourVal = calendar.component(.hour, from: dateVal)

    let tokens = TokenUsage(
      input: freshInput,
      output: totalOutput,
      cacheWrite5m: 0,
      cacheWrite1h: 0,
      cacheRead: cacheRead
    )

    events.append(
      UsageEvent(
        provider: .geminiCLI,
        model: modelName,
        day: dayDate,
        hour: hourVal,
        tokens: tokens,
        isFast: false
      )
    )
  }

  return events
}

private struct GeminiSessionRecord: Decodable {
  let messages: [GeminiMessageRecord]?

  init(messages: [GeminiMessageRecord]? = nil) {
    self.messages = messages
  }
}

private struct GeminiMessageRecord: Decodable {
  let id: String?
  let timestamp: String?
  let type: String?
  let model: String?
  let tokens: GeminiTokenRecord?

  init(
    id: String? = nil,
    timestamp: String? = nil,
    type: String? = nil,
    model: String? = nil,
    tokens: GeminiTokenRecord? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.type = type
    self.model = model
    self.tokens = tokens
  }
}

private struct GeminiTokenRecord: Decodable {
  let input: Int?
  let output: Int?
  let cached: Int?
  let thoughts: Int?
  let tool: Int?
  let total: Int?

  init(
    input: Int? = nil,
    output: Int? = nil,
    cached: Int? = nil,
    thoughts: Int? = nil,
    tool: Int? = nil,
    total: Int? = nil
  ) {
    self.input = input
    self.output = output
    self.cached = cached
    self.thoughts = thoughts
    self.tool = tool
    self.total = total
  }
}
