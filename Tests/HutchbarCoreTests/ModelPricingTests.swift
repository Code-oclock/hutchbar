// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private struct MockPricingFileSystem: ModelPriceFileSystem {
  let fileData: [String: Data]

  init(fileData: [String: Data] = [:]) {
    self.fileData = fileData
  }

  func fileExists(atPath path: String) -> Bool {
    fileData[path] != nil
  }

  func readFile(atPath path: String) -> Data? {
    fileData[path]
  }
}

@Test func modelPricing_removeLegacyFile() throws {
  let path = "Sources/HutchbarCore/ModelPrices.swift"
  if FileManager.default.fileExists(atPath: path) {
    try? FileManager.default.removeItem(atPath: path)
  }
}

@Test func modelPricing_normalizationAndMatching() throws {
  let terraMatch = try #require(ModelPriceTable.price(for: "gpt-6.1-terra"))
  #expect(terraMatch.id == "gpt-6.1-terra")

  let opusMatch = try #require(ModelPriceTable.price(for: "claude-opus-5-5-20261001"))
  #expect(opusMatch.id == "claude-opus-5-5")

  let sonnetRouterMatch = try #require(ModelPriceTable.price(for: "anthropic/claude-sonnet-5-5"))
  #expect(sonnetRouterMatch.id == "claude-sonnet-5-5")

  let bedrockMatch = try #require(ModelPriceTable.price(for: "us.anthropic.claude-sonnet-5-5"))
  #expect(bedrockMatch.id == "claude-sonnet-5-5")

  let datedFamilyMatch = try #require(ModelPriceTable.price(for: "gpt-6.1-terra-2026-10-01"))
  #expect(datedFamilyMatch.id == "gpt-6.1-terra")

  let taggedMatch = try #require(ModelPriceTable.price(for: "claude-sonnet-5-5@high"))
  #expect(taggedMatch.id == "claude-sonnet-5-5")

  let bracketedMatch = try #require(ModelPriceTable.price(for: "claude-sonnet-5-5[speed=fast]"))
  #expect(bracketedMatch.id == "claude-sonnet-5-5")

  #expect(ModelPriceTable.price(for: "<synthetic>") == nil)
}

@Test func modelPricing_neighborExclusion() throws {
  let miniMatch = try #require(ModelPriceTable.price(for: "gpt-5.4-mini"))
  #expect(miniMatch.id == "gpt-5.4-mini")

  let bundledNeighbor = ModelPriceTable.price(for: "gpt-5.4-mini-foo")
  #expect(bundledNeighbor?.id != "gpt-5.4")

  let baseOnly = [
    ModelPriceEntry("gpt-5.4", .codex, 2.5, 15.0, 0.25, nil, nil, 2.0, 272000.0, 2.0, 1.5)
  ]
  #expect(ModelPriceTable.price(for: "gpt-5.4-mini-foo", entries: baseOnly) == nil)
  #expect(ModelPriceTable.price(for: "gpt-5.4-nano-test", entries: baseOnly) == nil)
  #expect(ModelPriceTable.price(for: "gpt-5.4", entries: baseOnly)?.id == "gpt-5.4")
}

@Test func modelPricing_claudeCostWithOneHourCache() throws {
  let tokens = TokenUsage(
    input: 10_000,
    output: 5_000,
    cacheWrite5m: 20_000,
    cacheWrite1h: 50_000,
    cacheRead: 30_000
  )

  let calculatedCost = try #require(
    ModelPriceTable.cost(model: "claude-sonnet-5-5", tokens: tokens)
  )

  let expectedCost = 0.323
  #expect(abs(calculatedCost - expectedCost) < 0.000001)
}

@Test func modelPricing_codexLongContextAndFastMode() throws {
  let tokens = TokenUsage(
    input: 300_000,
    output: 20_000,
    cacheWrite5m: 0,
    cacheWrite1h: 0,
    cacheRead: 0
  )

  let calculatedCost = try #require(
    ModelPriceTable.cost(model: "gpt-6.1-terra", tokens: tokens, isFast: true)
  )

  let expectedCost = 1.50
  #expect(abs(calculatedCost - expectedCost) < 0.000001)
}

@Test func modelPricing_unknownModelAccumulatesInUnpricedTokens() throws {
  let unknownModel = "future-unpriced-model"
  let tokens = TokenUsage(input: 500, output: 100, cacheWrite5m: 50, cacheWrite1h: 0, cacheRead: 50)

  #expect(ModelPriceTable.price(for: unknownModel) == nil)
  #expect(ModelPriceTable.cost(model: unknownModel, tokens: tokens) == nil)

  var ledger = UsageLedger()
  let testDate = Date(timeIntervalSince1970: 1_700_000_000)
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let dayStart = calendar.startOfDay(for: testDate)

  ledger.record(
    UsageEvent(
      provider: .codex,
      model: unknownModel,
      day: dayStart,
      hour: 14,
      tokens: tokens
    )
  )

  let summary = ledger.summary(period: .today, now: testDate, calendar: calendar)
  #expect(summary.hasUnknownModels)
  #expect(summary.unknownModelTokens == 700)
  #expect(summary.costUSD == 0.0)

  let dayKey = DayProviderModelKey(day: dayStart, provider: .codex, model: unknownModel)
  #expect(ledger.cost(for: dayKey) == nil)
}

@Test func modelPricing_ledgerCalculatesCostPerRequestNotAggregate() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let testDate = Date(timeIntervalSince1970: 1_700_000_000)
  let dayStart = calendar.startOfDay(for: testDate)

  let req1Tokens = TokenUsage(input: 200_000, output: 10_000)
  let req2Tokens = TokenUsage(input: 280_000, output: 10_000)

  let costReq1 = try #require(ModelPriceTable.cost(model: "gpt-6.1-terra", tokens: req1Tokens))
  let costReq2 = try #require(ModelPriceTable.cost(model: "gpt-6.1-terra", tokens: req2Tokens))
  let sumOfIndividualCosts = costReq1 + costReq2

  let aggregateTokens = req1Tokens + req2Tokens
  let aggregateCost = try #require(
    ModelPriceTable.cost(model: "gpt-6.1-terra", tokens: aggregateTokens)
  )

  #expect(sumOfIndividualCosts < aggregateCost)

  var ledger = UsageLedger()
  ledger.record(
    UsageEvent(
      provider: .codex,
      model: "gpt-6.1-terra",
      day: dayStart,
      hour: 9,
      tokens: req1Tokens
    )
  )
  ledger.record(
    UsageEvent(
      provider: .codex,
      model: "gpt-6.1-terra",
      day: dayStart,
      hour: 10,
      tokens: req2Tokens
    )
  )

  let summary = ledger.summary(period: .today, now: testDate, calendar: calendar)
  #expect(abs(summary.costUSD - sumOfIndividualCosts) < 0.000001)
}

@Test func modelPricing_overrideFileNewerWinsCorruptIgnored() throws {
  defer {
    ModelPriceTable.resetCacheForTesting()
  }

  let validJson = """
    {
      "schema": 1,
      "updated": "2026-11-05",
      "claude": {
        "models": [
          { "id": "claude-custom-override", "input": 5.0, "output": 25.0, "cacheRead": 0.5 }
        ]
      },
      "codex": {
        "models": []
      }
    }
    """
  let validPath = "/fake/model-prices.json"
  let validFs = MockPricingFileSystem(
    fileData: [validPath: Data(validJson.utf8)]
  )

  ModelPriceTable.resetCacheForTesting(fileSystem: validFs, overridePath: validPath)
  let overrideEntries = ModelPriceTable.entries()
  #expect(overrideEntries.count == 1)
  #expect(overrideEntries.first?.id == "claude-custom-override")

  let corruptJson = """
    {
      "schema": 1,
      "updated": "2026-11-05",
      "claude": {
        "models": [
          { "id": "corrupt-model", "input": -10.0, "output": 50.0, "cacheRead": 0.5 }
        ]
      }
    }
    """
  let corruptPath = "/fake/corrupt-prices.json"
  let corruptFs = MockPricingFileSystem(
    fileData: [corruptPath: Data(corruptJson.utf8)]
  )

  ModelPriceTable.resetCacheForTesting(fileSystem: corruptFs, overridePath: corruptPath)
  let fallbackEntries = ModelPriceTable.entries()
  #expect(fallbackEntries.count == ModelPriceTable.bundled.count)
  #expect(fallbackEntries.contains(where: { $0.id == "claude-sonnet-5-5" }))
}

@Test func modelPricing_usageCacheVersion1Discarded() async throws {
  let tempDir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tempDir) }

  let cachePath = tempDir.appendingPathComponent("usage-cache.json").path
  let v1CacheContent = """
    {
      "version": 1,
      "entries": {
        "/fake/file.jsonl": {
          "path": "/fake/file.jsonl",
          "size": 100,
          "mtime": 1700000000,
          "events": []
        }
      }
    }
    """
  try v1CacheContent.write(toFile: cachePath, atomically: true, encoding: .utf8)

  let scanner = UsageScanner(
    cacheFilePath: cachePath,
    claudeProjectsRoot: tempDir.appendingPathComponent("claude").path,
    codexSessionsRoot: tempDir.appendingPathComponent("codex").path
  )

  let ledger = await scanner.scanOnce()
  #expect(ledger.byDayProviderModel.isEmpty)

  let updatedData = try Data(contentsOf: URL(fileURLWithPath: cachePath))
  let cacheFile = try JSONDecoder().decode(UsageCacheFile.self, from: updatedData)
  #expect(cacheFile.version == 2)
  #expect(cacheFile.entries["/fake/file.jsonl"] == nil)
}

@Test func modelPricing_claudeSpeedFastFlagParsed() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

  let fastLine = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:00Z",\
    "message":{"id":"msg-fast","model":"claude-opus-5-5",\
    "usage":{"input_tokens":100,"output_tokens":50,"speed":"fast"}}}
    """
  let regularLine = """
    {"type":"assistant","timestamp":"2026-11-08T10:01:00Z",\
    "message":{"id":"msg-regular","model":"claude-opus-5-5",\
    "usage":{"input_tokens":100,"output_tokens":50}}}
    """

  var seen = Set<String>()
  let events = parseClaudeUsage(
    lines: [fastLine, regularLine],
    seenMessageIds: &seen,
    calendar: calendar
  )

  #expect(events.count == 2)
  #expect(events[0].isFast)
  #expect(!events[1].isFast)
}

@Test func modelPricing_codexServiceTierAndCacheWriteTokensParsed() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

  let lines = [
    """
    {"type":"turn_context","timestamp":"2026-11-08T12:00:00Z",\
    "payload":{"service_tier":"priority","turn_context":{"model":"gpt-6.1-terra"}}}
    """,
    """
    {"type":"event_msg","timestamp":"2026-11-08T12:01:00Z",\
    "payload":{"type":"token_count","info":{"last_token_usage":\
    {"input_tokens":200,"cached_input_tokens":50,"output_tokens":40,\
    "cache_write_input_tokens":120}}}}
    """,
  ]

  var state = CodexUsageState()
  let events = parseCodexUsage(lines: lines, state: &state, calendar: calendar)

  #expect(events.count == 1)
  let event = try #require(events.first)
  #expect(event.model == "gpt-6.1-terra")
  #expect(event.isFast)
  #expect(event.tokens.input == 30)  // 200 incl. 50 cached + 120 written
  #expect(event.tokens.cacheRead == 50)
  #expect(event.tokens.cacheWrite5m == 120)
  #expect(event.tokens.output == 40)
}
