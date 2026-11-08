// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which price list section a model belongs to.
public enum PriceProvider: String, Sendable, Codable {
  case claude
  case codex
}

/// One model's API list price, USD per 1M tokens (schema 1 of Resources/model-prices.json).
public struct ModelPriceEntry: Equatable, Sendable {
  public let id: String
  public let provider: PriceProvider
  public let input: Double
  public let output: Double
  public let cacheRead: Double
  /// Short-lived cache write (Claude 5 min, OpenAI 30 min); nil means `input` is charged.
  public let cacheWrite: Double?
  /// Claude 1-hour cache write; nil means `cacheWrite` is charged.
  public let cacheWriteLong: Double?
  /// Price multiplier for fast / priority requests; nil means fast is not offered.
  public let fastMultiplier: Double?
  /// Long-context premium: a request whose prompt (input + cache read + cache write)
  /// exceeds `longAbove` tokens costs `longInputMultiplier` × on input-side rates and
  /// `longOutputMultiplier` × on output.
  public let longAbove: Double?
  public let longInputMultiplier: Double?
  public let longOutputMultiplier: Double?

  public init(
    _ id: String, _ provider: PriceProvider, _ input: Double, _ output: Double,
    _ cacheRead: Double, _ cacheWrite: Double?, _ cacheWriteLong: Double?,
    _ fastMultiplier: Double?, _ longAbove: Double?, _ longInputMultiplier: Double?,
    _ longOutputMultiplier: Double?
  ) {
    self.id = id
    self.provider = provider
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.cacheWriteLong = cacheWriteLong
    self.fastMultiplier = fastMultiplier
    self.longAbove = longAbove
    self.longInputMultiplier = longInputMultiplier
    self.longOutputMultiplier = longOutputMultiplier
  }
}

/// The price list hutchbar uses: the bundled table (generated from
/// Resources/model-prices.json) unless a newer user override file exists.
public enum ModelPriceTable {}
