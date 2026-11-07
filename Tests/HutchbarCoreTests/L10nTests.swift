// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func makeDate(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current
) -> Date {
  var components = DateComponents()
  components.year = year
  components.month = month
  components.day = day
  components.hour = hour
  components.minute = minute
  components.second = 0
  components.timeZone = timeZone

  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = timeZone
  return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
}

@Suite("L10nTests")
struct L10nTests {
  @Test func l10n_languageDetection() {
    #expect(L10n.detectLanguage(from: ["ru-RU", "en-US"]) == .ru)
    #expect(L10n.detectLanguage(from: ["RU"]) == .ru)
    #expect(L10n.detectLanguage(from: ["en-US", "ru-RU"]) == .en)
    #expect(L10n.detectLanguage(from: ["de-DE", "fr-FR"]) == .en)
    #expect(L10n.detectLanguage(from: []) == .en)
  }

  @Test func l10n_languageOverride() {
    let original = L10n.overrideLanguage
    defer { L10n.overrideLanguage = original }

    L10n.overrideLanguage = .ru
    #expect(L10n.currentLanguage() == .ru)
    #expect(L10n.sessionWindowLabel() == "Сессия")

    L10n.overrideLanguage = .en
    #expect(L10n.currentLanguage() == .en)
    #expect(L10n.sessionWindowLabel() == "Session")

    let result = L10n.withLanguage(.ru) {
      L10n.weekWindowLabel()
    }
    #expect(result == "Неделя")
  }

  @Test func l10n_sectionAndCardTitles() {
    #expect(L10n.quotasTitle(language: .ru) == "Лимиты")
    #expect(L10n.quotasTitle(language: .en) == "Quotas")

    #expect(L10n.spendingTitle(language: .ru) == "Расходы")
    #expect(L10n.spendingTitle(language: .en) == "Spending")

    #expect(L10n.trendTitle(language: .ru) == "Динамика")
    #expect(L10n.trendTitle(language: .en) == "Trend")

    #expect(L10n.waitingTitle(language: .ru) == "Очередь")
    #expect(L10n.waitingTitle(language: .en) == "Waiting for you")

    #expect(L10n.workingTitle(language: .ru) == "В работе")
    #expect(L10n.workingTitle(language: .en) == "Working")
  }

  @Test func l10n_reasonBadges() {
    #expect(L10n.needsApproval(language: .ru) == "нужно разрешение")
    #expect(L10n.needsApproval(language: .en) == "needs approval")

    #expect(L10n.yourTurn(language: .ru) == "твой ход")
    #expect(L10n.yourTurn(language: .en) == "your turn")

    #expect(L10n.working(language: .ru) == "работает")
    #expect(L10n.working(language: .en) == "working")

    #expect(L10n.reasonBadge(for: .waitingForApproval, language: .ru) == "нужно разрешение")
    #expect(L10n.reasonBadge(for: .waitingForApproval, language: .en) == "needs approval")
    #expect(L10n.reasonBadge(for: .waitingForInput, language: .ru) == "твой ход")
    #expect(L10n.reasonBadge(for: .waitingForInput, language: .en) == "your turn")
    #expect(L10n.reasonBadge(for: .running, language: .ru) == "работает")
    #expect(L10n.reasonBadge(for: .running, language: .en) == "working")
    #expect(L10n.reasonBadge(for: .finished, language: .ru) == "завершено")
    #expect(L10n.reasonBadge(for: .finished, language: .en) == "finished")
  }

  @Test func l10n_windowLabels() {
    #expect(L10n.sessionWindowLabel(language: .ru) == "Сессия")
    #expect(L10n.sessionWindowLabel(language: .en) == "Session")

    #expect(L10n.weekWindowLabel(language: .ru) == "Неделя")
    #expect(L10n.weekWindowLabel(language: .en) == "Week")

    #expect(L10n.quotaWindowName(minutes: 300, language: .ru) == "Сессия")
    #expect(L10n.quotaWindowName(minutes: 300, language: .en) == "Session")

    #expect(L10n.quotaWindowName(minutes: 10080, language: .ru) == "Неделя")
    #expect(L10n.quotaWindowName(minutes: 10080, language: .en) == "Week")

    #expect(L10n.quotaWindowName(minutes: 120, language: .ru) == "2ч")
    #expect(L10n.quotaWindowName(minutes: 120, language: .en) == "2h")

    #expect(L10n.quotaWindowName(minutes: 45, language: .ru) == "45 мин")
    #expect(L10n.quotaWindowName(minutes: 45, language: .en) == "45m")
  }

  @Test func l10n_remainingPercent() {
    #expect(L10n.remainingPercent(80, language: .ru) == "Осталось 80 %")
    #expect(L10n.remainingPercent(80, language: .en) == "Remaining 80%")
    #expect(L10n.remainingPercent(0, language: .ru) == "Осталось 0 %")
    #expect(L10n.remainingPercent(100, language: .en) == "Remaining 100%")
  }

  @Test func l10n_countdownFormatting_russian() {
    let twoDaysSevenHours: TimeInterval = (2 * 86400) + (7 * 3600)
    #expect(L10n.countdown(seconds: twoDaysSevenHours, language: .ru) == "2 д 7 ч")

    let fourHoursFiftyNineMin: TimeInterval = (4 * 3600) + (59 * 60)
    #expect(L10n.countdown(seconds: fourHoursFiftyNineMin, language: .ru) == "4 ч 59 мин")

    let twelveMinutes: TimeInterval = 12 * 60
    #expect(L10n.countdown(seconds: twelveMinutes, language: .ru) == "12 мин")

    #expect(L10n.countdown(seconds: 0, language: .ru) == "нет свежих данных")
    #expect(L10n.countdown(seconds: -10, language: .ru) == "нет свежих данных")
  }

  @Test func l10n_countdownFormatting_english() {
    let twoDaysSevenHours: TimeInterval = (2 * 86400) + (7 * 3600)
    #expect(L10n.countdown(seconds: twoDaysSevenHours, language: .en) == "2d 7h")

    let fourHoursFiftyNineMin: TimeInterval = (4 * 3600) + (59 * 60)
    #expect(L10n.countdown(seconds: fourHoursFiftyNineMin, language: .en) == "4h 59m")

    let twelveMinutes: TimeInterval = 12 * 60
    #expect(L10n.countdown(seconds: twelveMinutes, language: .en) == "12m")

    #expect(L10n.countdown(seconds: 0, language: .en) == "no fresh data")
    #expect(L10n.countdown(seconds: -50, language: .en) == "no fresh data")
  }

  @Test func l10n_countdownFromDates() {
    let now = makeDate(year: 2026, month: 11, day: 7, hour: 12, minute: 0)
    let resetsInFourHours = now.addingTimeInterval((4 * 3600) + (59 * 60))
    let pastReset = now.addingTimeInterval(-60)

    #expect(L10n.countdown(from: resetsInFourHours, now: now, language: .ru) == "4 ч 59 мин")
    #expect(L10n.countdown(from: pastReset, now: now, language: .ru) == "нет свежих данных")
    #expect(L10n.countdown(from: nil, now: now, language: .ru) == "нет свежих данных")

    #expect(L10n.countdown(from: resetsInFourHours, now: now, language: .en) == "4h 59m")
    #expect(L10n.countdown(from: pastReset, now: now, language: .en) == "no fresh data")
  }

  @Test func l10n_spendingAndPrices() {
    #expect(L10n.atApiPrices(language: .ru) == "по ценам API")
    #expect(L10n.atApiPrices(language: .en) == "at API prices")

    #expect(L10n.periodToday(language: .ru) == "Сегодня")
    #expect(L10n.periodToday(language: .en) == "Today")

    #expect(L10n.periodWeek(language: .ru) == "Неделя")
    #expect(L10n.periodWeek(language: .en) == "Week")

    #expect(L10n.periodMonth(language: .ru) == "Месяц")
    #expect(L10n.periodMonth(language: .en) == "Month")

    #expect(L10n.tokens(language: .ru) == "токенов")
    #expect(L10n.tokens(language: .en) == "tokens")

    #expect(L10n.cache(language: .ru) == "кэш")
    #expect(L10n.cache(language: .en) == "cache")

    #expect(L10n.unknownModels(language: .ru) == "неизвестные модели")
    #expect(L10n.unknownModels(language: .en) == "unknown models")
  }

  @Test func l10n_agentProcessNotFound() {
    #expect(L10n.agentProcessNotFound(language: .ru) == "процесс агента не найден")
    #expect(L10n.agentProcessNotFound(language: .en) == "agent process not found")
  }

  @Test func l10n_emptyStates() {
    #expect(L10n.emptySessions(language: .ru) == "Нет активных агентов")
    #expect(L10n.emptySessions(language: .en) == "No agent sessions yet")

    #expect(L10n.emptyQuotas(language: .ru) == "Нет данных о лимитах")
    #expect(L10n.emptyQuotas(language: .en) == "No quota data")

    #expect(L10n.emptySpending(language: .ru) == "Нет данных о расходах")
    #expect(L10n.emptySpending(language: .en) == "No spending data")
  }

  @Test func l10n_hooksHints() {
    #expect(L10n.hooksNotInstalled(language: .ru) == "Хуки не установлены")
    #expect(L10n.hooksNotInstalled(language: .en) == "Hooks not installed")

    #expect(L10n.copyHooks(language: .ru) == "Скопировать")
    #expect(L10n.copyHooks(language: .en) == "Copy")

    #expect(L10n.copiedHooks(language: .ru) == "Скопировано")
    #expect(L10n.copiedHooks(language: .en) == "Copied")

    #expect(L10n.hooksSnippetHint(language: .ru) == "Нажмите, чтобы скопировать конфигурацию хуков")
    #expect(L10n.hooksSnippetHint(language: .en) == "Click to copy hooks configuration")
  }

  @Test func l10n_formatResetDate() {
    guard let utc = TimeZone(secondsFromGMT: 0) else {
      Issue.record("Failed to create UTC timezone")
      return
    }

    let now = makeDate(year: 2026, month: 11, day: 7, hour: 12, minute: 0, timeZone: utc)
    let resetToday = makeDate(year: 2026, month: 11, day: 7, hour: 21, minute: 30, timeZone: utc)
    let resetLaterDay = makeDate(year: 2026, month: 11, day: 9, hour: 10, minute: 0, timeZone: utc)

    #expect(L10n.formatResetDate(nil, now: now) == nil)
    #expect(L10n.formatResetDate(resetToday, now: now, timeZone: utc, language: .ru) == "↻ 21:30")

    let formattedRu = L10n.formatResetDate(resetLaterDay, now: now, timeZone: utc, language: .ru)
    // 2026-11-09 is Monday -> "↻ пн 10:00"
    #expect(formattedRu == "↻ пн 10:00")

    let formattedEn = L10n.formatResetDate(resetLaterDay, now: now, timeZone: utc, language: .en)
    #expect(formattedEn == "↻ Mon 10:00")
  }
}
