// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let quotaGatewayUTC = TimeZone(secondsFromGMT: 0) ?? .current

private func quotaGatewayDate(day: Int, hour: Int, minute: Int) -> Date {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = quotaGatewayUTC
  let components = DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)
  return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
}

@Test func quotaGateway_onlyCcrIsAGateway() {
  #expect(QuotaSource.ccr.gatewayName == "ccr")
  for source in QuotaSource.allCases where source != .ccr {
    #expect(source.gatewayName == nil)
  }
}

@Test func quotaGateway_staleReadingNamesItsDayWhenNotToday() {
  let now = quotaGatewayDate(day: 9, hour: 12, minute: 0)
  let today = QuotaPresentation.asOfMoment(
    quotaGatewayDate(day: 9, hour: 7, minute: 5), now: now, timeZone: quotaGatewayUTC,
    language: .ru)
  #expect(today == "07:05")
  let older = QuotaPresentation.asOfMoment(
    quotaGatewayDate(day: 4, hour: 19, minute: 2), now: now, timeZone: quotaGatewayUTC,
    language: .en)
  #expect(older == "4 Nov 19:02")
}

/// Without gateways the only direct account may still be shown as "now" (old behaviour).
@Test func quotaGateway_directAccountGuessedCurrentWithoutGateways() {
  let now = quotaGatewayDate(day: 9, hour: 12, minute: 0)
  let quota = AccountQuota(
    agent: .claudeCode,
    accountName: "solo",
    windows: [QuotaWindow(windowMinutes: 300, usedPercent: 10, resetsAt: now + 3600)],
    observedAt: now,
    source: .agentCLI
  )
  let card = QuotaPresentation(quotas: [quota], now: now, language: .en).card(for: .claudeCode)
  #expect(card?.accounts.first?.isCurrent == true)
  #expect(card?.gateways.isEmpty == true)
}
