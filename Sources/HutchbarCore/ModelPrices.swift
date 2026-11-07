// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// USD per 1M tokens. Source: Anthropic API pricing as cached in the Claude API
/// reference on 2026-10-06 (first-party rates). Cache writes are 1.25x input
/// (5-minute TTL) and 2x input (1-hour TTL); cache reads are model-specific.
/// Models missing here are shown with token counts only, never a guessed price.
public struct ModelPrice: Equatable, Sendable {
  public let input: Double
  public let output: Double
  public let cacheWrite5m: Double
  public let cacheWrite1h: Double
  public let cacheRead: Double

  public init(input: Double, output: Double, cacheRead: Double) {
    self.input = input
    self.output = output
    self.cacheWrite5m = input * 1.25
    self.cacheWrite1h = input * 2
    self.cacheRead = cacheRead
  }
}

public enum ModelPrices {
  public static let asOf = "2026-10-06"

  static let table: [String: ModelPrice] = [
    "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
    "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1.00),
    "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
    "claude-opus-5": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-8": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-7": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-6": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
    "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
    "claude-sonnet-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
    "claude-sonnet-4-6": ModelPrice(input: 3, output: 15, cacheRead: 0.30),
    // Haiku 5.5: prompts up to 100K tokens; longer prompts are billed higher.
    "claude-haiku-5-5": ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01),
    "claude-haiku-4-5": ModelPrice(input: 1, output: 5, cacheRead: 0.10),
  ]

  /// Exact id first, then the id with a trailing date suffix stripped
  /// (`claude-opus-4-5-20251101` style), else nil.
  public static func price(for model: String) -> ModelPrice? {
    if let exact = table[model] { return exact }
    let parts = model.split(separator: "-")
    if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
      return table[parts.dropLast().joined(separator: "-")]
    }
    return nil
  }
}
