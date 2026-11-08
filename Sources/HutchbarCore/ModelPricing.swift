// SPDX-License-Identifier: GPL-3.0-or-later
// Portions: Copyright (C) 2026 Vorssaint
import Foundation

/// File system access protocol for loading model price overrides.
public protocol ModelPriceFileSystem: Sendable {
  func fileExists(atPath path: String) -> Bool
  func readFile(atPath path: String) -> Data?
}

/// Default local file system implementation using Foundation.
public struct LocalModelPriceFileSystem: ModelPriceFileSystem {
  public init() {}

  public func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  public func readFile(atPath path: String) -> Data? {
    try? Data(contentsOf: URL(fileURLWithPath: path))
  }
}

/// Internal thread-safe cache for model price entries.
private final class PriceTableStorage: @unchecked Sendable {
  static let shared = PriceTableStorage()
  private let lock = NSLock()
  private var cachedEntries: [ModelPriceEntry]?
  private var fileSystem: any ModelPriceFileSystem = LocalModelPriceFileSystem()
  private var overridePath: String = defaultOverridePath

  static var defaultOverridePath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/hutchbar/model-prices.json").path
  }

  func getEntries() -> [ModelPriceEntry] {
    lock.lock()
    defer { lock.unlock() }
    if let cachedEntries {
      return cachedEntries
    }
    let loaded = ModelPriceDecoder.load(fileSystem: fileSystem, path: overridePath)
    cachedEntries = loaded
    return loaded
  }

  func resetForTesting(
    fileSystem: any ModelPriceFileSystem = LocalModelPriceFileSystem(),
    overridePath: String? = nil
  ) {
    lock.lock()
    defer { lock.unlock() }
    self.fileSystem = fileSystem
    self.overridePath = overridePath ?? Self.defaultOverridePath
    self.cachedEntries = nil
  }
}

/// Helper for decoding and validating schema 1 model price files.
enum ModelPriceDecoder {
  static let maxFileSize = 256 * 1024

  static func load(fileSystem: any ModelPriceFileSystem, path: String) -> [ModelPriceEntry] {
    let resolved = (path as NSString).expandingTildeInPath
    guard fileSystem.fileExists(atPath: resolved),
      let data = fileSystem.readFile(atPath: resolved),
      let entries = decode(from: data)
    else {
      return ModelPriceTable.bundled
    }
    return entries
  }

  static func decode(from data: Data) -> [ModelPriceEntry]? {
    guard data.count <= maxFileSize,
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let schema = json["schema"] as? Int, schema == 1,
      let updatedString = json["updated"] as? String,
      isValidDateString(updatedString),
      updatedString >= ModelPriceTable.bundledUpdated
    else {
      return nil
    }

    var entries: [ModelPriceEntry] = []
    var seenIds = Set<String>()

    if let claudeObject = json["claude"] as? [String: Any],
      let claudeModels = claudeObject["models"] as? [[String: Any]]
    {
      for modelDict in claudeModels {
        guard let entry = parseEntry(modelDict, provider: .claude, seenIds: &seenIds) else {
          return nil
        }
        entries.append(entry)
      }
    }

    if let codexObject = json["codex"] as? [String: Any],
      let codexModels = codexObject["models"] as? [[String: Any]]
    {
      for modelDict in codexModels {
        guard let entry = parseEntry(modelDict, provider: .codex, seenIds: &seenIds) else {
          return nil
        }
        entries.append(entry)
      }
    }

    guard (1...500).contains(entries.count) else { return nil }
    return entries
  }

  private static func parseEntry(
    _ dict: [String: Any],
    provider: PriceProvider,
    seenIds: inout Set<String>
  ) -> ModelPriceEntry? {
    guard let modelId = dict["id"] as? String,
      !modelId.isEmpty,
      seenIds.insert(modelId).inserted,
      let inputRate = parseRate(dict["input"]),
      let outputRate = parseRate(dict["output"]),
      let cacheReadRate = parseRate(dict["cacheRead"])
    else {
      return nil
    }

    let cacheWriteRate: Double?
    if let writeValue = dict["cacheWrite"] {
      guard let parsed = parseRate(writeValue) else { return nil }
      cacheWriteRate = parsed
    } else {
      cacheWriteRate = nil
    }

    let cacheWriteLongRate: Double?
    if let writeLongValue = dict["cacheWriteLong"] {
      guard let parsed = parseRate(writeLongValue) else { return nil }
      cacheWriteLongRate = parsed
    } else {
      cacheWriteLongRate = nil
    }

    let fastMultiplier: Double?
    if let fastValue = dict["fastMultiplier"] {
      guard let parsed = parsePositiveMultiplier(fastValue) else { return nil }
      fastMultiplier = parsed
    } else {
      fastMultiplier = nil
    }

    let longAbove: Double?
    let longInputMult: Double?
    let longOutputMult: Double?
    if let longObject = dict["longContext"] as? [String: Any] {
      guard let above = parsePositiveMultiplier(longObject["above"]),
        let inputMult = parsePositiveMultiplier(longObject["inputMultiplier"]),
        let outputMult = parsePositiveMultiplier(longObject["outputMultiplier"])
      else {
        return nil
      }
      longAbove = above
      longInputMult = inputMult
      longOutputMult = outputMult
    } else {
      longAbove = nil
      longInputMult = nil
      longOutputMult = nil
    }

    return ModelPriceEntry(
      modelId, provider, inputRate, outputRate, cacheReadRate,
      cacheWriteRate, cacheWriteLongRate, fastMultiplier,
      longAbove, longInputMult, longOutputMult
    )
  }

  private static func parseRate(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      return nil
    }
    let doubleVal = number.doubleValue
    guard doubleVal.isFinite, (0.0...1000.0).contains(doubleVal) else { return nil }
    return doubleVal
  }

  private static func parsePositiveMultiplier(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      return nil
    }
    let doubleVal = number.doubleValue
    guard doubleVal.isFinite, doubleVal > 0.0 else { return nil }
    return doubleVal
  }

  private static func isValidDateString(_ string: String) -> Bool {
    let parts = string.split(separator: "-")
    guard parts.count == 3,
      parts[0].count == 4, parts[0].allSatisfy(\.isNumber),
      parts[1].count == 2, parts[1].allSatisfy(\.isNumber),
      parts[2].count == 2, parts[2].allSatisfy(\.isNumber),
      let year = Int(parts[0]), (2000...2100).contains(year),
      let month = Int(parts[1]), (1...12).contains(month),
      let day = Int(parts[2]), (1...31).contains(day)
    else {
      return false
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let components = DateComponents(year: year, month: month, day: day)
    return components.isValidDate(in: calendar)
  }
}

// MARK: - ModelPriceTable Extensions

extension ModelPriceTable {
  public static let neighbors = [
    "mini", "nano", "pro", "lite", "research", "search", "audio", "realtime",
    "transcribe", "tts", "cyber", "image",
  ]

  /// Returns the current active list of model prices.
  public static func entries() -> [ModelPriceEntry] {
    PriceTableStorage.shared.getEntries()
  }

  /// Resets the in-memory cached entries for testing purposes.
  public static func resetCacheForTesting(
    fileSystem: any ModelPriceFileSystem = LocalModelPriceFileSystem(),
    overridePath: String? = nil
  ) {
    PriceTableStorage.shared.resetForTesting(fileSystem: fileSystem, overridePath: overridePath)
  }

  /// Normalizes a model identifier by lowering case, removing router prefixes, tags, and date tails.
  public static func normalizeModelId(_ rawModel: String) -> String? {
    var identifier = rawModel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty, identifier != "<synthetic>" else { return nil }

    if let slashIndex = identifier.lastIndex(of: "/") {
      identifier = String(identifier[identifier.index(after: slashIndex)...])
    }

    if identifier.hasPrefix("us.anthropic.") {
      identifier = String(identifier.dropFirst("us.anthropic.".count))
    }
    if identifier.hasPrefix("anthropic.") {
      identifier = String(identifier.dropFirst("anthropic.".count))
    }
    if identifier.hasPrefix("openai.") {
      identifier = String(identifier.dropFirst("openai.".count))
    }

    for marker in ["@", "["] {
      if let markerIndex = identifier.firstIndex(of: Character(marker)) {
        identifier = String(identifier[..<markerIndex])
      }
    }

    let dashParts = identifier.split(separator: "-")
    if let lastComponent = dashParts.last,
      lastComponent.count == 8,
      lastComponent.allSatisfy(\.isNumber)
    {
      identifier = dashParts.dropLast().joined(separator: "-")
    }

    guard !identifier.isEmpty, identifier != "<synthetic>" else { return nil }
    return identifier
  }

  /// Finds the price entry for a model by exact match or longest family prefix match.
  public static func price(
    for model: String,
    entries: [ModelPriceEntry] = entries()
  ) -> ModelPriceEntry? {
    guard let normalized = normalizeModelId(model) else { return nil }

    if let exactMatch = entries.first(where: { $0.id == normalized }) {
      return exactMatch
    }

    var bestMatch: ModelPriceEntry?
    var bestLength = 0

    for candidate in entries {
      guard normalized.hasPrefix(candidate.id) else { continue }
      let remainder = normalized.dropFirst(candidate.id.count)
      guard let boundaryChar = remainder.first,
        boundaryChar == "-" || boundaryChar == "."
      else {
        continue
      }

      if neighbors.contains(where: { remainder.contains($0) }) {
        continue
      }

      if candidate.id.count > bestLength {
        bestMatch = candidate
        bestLength = candidate.id.count
      }
    }

    return bestMatch
  }

  /// Calculates the USD cost for a single request.
  public static func cost(
    model: String,
    tokens: TokenUsage,
    isFast: Bool = false
  ) -> Double? {
    cost(model: model, tokens: tokens, isFast: isFast, entries: entries())
  }

  /// Calculates the USD cost for a single request using an explicit entry table.
  public static func cost(
    model: String,
    tokens: TokenUsage,
    isFast: Bool = false,
    entries: [ModelPriceEntry]
  ) -> Double? {
    guard let entry = price(for: model, entries: entries) else { return nil }

    let promptTokens = tokens.input + tokens.cacheRead + tokens.cacheWrite5m + tokens.cacheWrite1h
    var inRate: Double = 1.0
    var outRate: Double = 1.0

    if let threshold = entry.longAbove, Double(promptTokens) > threshold {
      inRate = entry.longInputMultiplier ?? 1.0
      outRate = entry.longOutputMultiplier ?? 1.0
    }

    if isFast, let fastMultiplier = entry.fastMultiplier {
      inRate *= fastMultiplier
      outRate *= fastMultiplier
    }

    let write5mPrice = entry.cacheWrite ?? entry.input
    let write1hPrice = entry.cacheWriteLong ?? entry.cacheWrite ?? entry.input

    let inputCost =
      Double(tokens.input) * entry.input
      + Double(tokens.cacheWrite5m) * write5mPrice
      + Double(tokens.cacheWrite1h) * write1hPrice
      + Double(tokens.cacheRead) * entry.cacheRead

    let outputCost = Double(tokens.output) * entry.output

    let totalUSD = (inputCost * inRate + outputCost * outRate) / 1_000_000.0
    return totalUSD
  }
}
