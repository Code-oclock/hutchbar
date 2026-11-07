// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Localization table supporting Russian and English without resource bundles.
// A flat string table: length grows with strings, not with logic.
// swiftlint:disable:next type_body_length
public enum L10n {
  /// Supported interface languages.
  public enum Language: String, Sendable, CaseIterable {
    case en
    case ru
  }

  // MARK: - Language Resolution & Override

  private static let overrideLock = NSLock()
  private static nonisolated(unsafe) var _overrideLanguage: Language?

  /// Test hook to override language resolution.
  public static var overrideLanguage: Language? {
    get {
      overrideLock.lock()
      defer { overrideLock.unlock() }
      return _overrideLanguage
    }
    set {
      overrideLock.lock()
      defer { overrideLock.unlock() }
      _overrideLanguage = newValue
    }
  }

  /// Detects the language from the preferred languages array, defaulting to English.
  public static func detectLanguage(
    from preferredLanguages: [String] = Locale.preferredLanguages
  ) -> Language {
    for identifier in preferredLanguages {
      let lower = identifier.lowercased()
      if lower.hasPrefix("ru") {
        return .ru
      }
      if lower.hasPrefix("en") {
        return .en
      }
    }
    return .en
  }

  /// Active language: either explicit override or detected from preferred languages.
  public static func currentLanguage(
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> Language {
    if let override = overrideLanguage {
      return override
    }
    return detectLanguage(from: preferredLanguages)
  }

  /// Executes an operation with a temporary language override.
  public static func withLanguage<T>(_ language: Language, operation: () throws -> T) rethrows -> T
  {
    overrideLock.lock()
    let previous = _overrideLanguage
    _overrideLanguage = language
    overrideLock.unlock()
    defer {
      overrideLock.lock()
      _overrideLanguage = previous
      overrideLock.unlock()
    }
    return try operation()
  }

  // MARK: - Section & Card Titles

  public static func quotasTitle(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Лимиты"
    case .en: return "Quotas"
    }
  }

  public static func spendingTitle(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Расходы"
    case .en: return "Spending"
    }
  }

  public static func trendTitle(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Динамика"
    case .en: return "Trend"
    }
  }

  public static func waitingTitle(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Очередь"
    case .en: return "Waiting for you"
    }
  }

  public static func workingTitle(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "В работе"
    case .en: return "Working"
    }
  }

  // MARK: - Reason Badges (Cause Labels)

  public static func needsApproval(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "нужно разрешение"
    case .en: return "needs approval"
    }
  }

  public static func yourTurn(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "твой ход"
    case .en: return "your turn"
    }
  }

  public static func working(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "работает"
    case .en: return "working"
    }
  }

  public static func reasonBadge(for state: SessionState, language: Language? = nil) -> String {
    switch state {
    case .waitingForApproval:
      return needsApproval(language: language)
    case .waitingForInput:
      return yourTurn(language: language)
    case .running:
      return working(language: language)
    case .finished:
      switch language ?? currentLanguage() {
      case .ru: return "завершено"
      case .en: return "finished"
      }
    }
  }

  // MARK: - Windows & Quota Labels

  public static func sessionWindowLabel(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Сессия"
    case .en: return "Session"
    }
  }

  public static func weekWindowLabel(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Неделя"
    case .en: return "Week"
    }
  }

  public static func quotaWindowName(minutes: Int, language: Language? = nil) -> String {
    let lang = language ?? currentLanguage()
    if minutes == 300 {
      return sessionWindowLabel(language: lang)
    }
    if minutes == 10080 {
      return weekWindowLabel(language: lang)
    }
    if minutes % 60 == 0 {
      let hours = minutes / 60
      switch lang {
      case .ru: return "\(hours)ч"
      case .en: return "\(hours)h"
      }
    }
    switch lang {
    case .ru: return "\(minutes) мин"
    case .en: return "\(minutes)m"
    }
  }

  public static func remainingPercent(_ percent: Int, language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Осталось \(percent) %"
    case .en: return "Remaining \(percent)%"
    }
  }

  // MARK: - Countdown Formatting

  public static func noFreshData(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "нет свежих данных"
    case .en: return "no fresh data"
    }
  }

  public static func countdown(seconds: TimeInterval, language: Language? = nil) -> String {
    guard seconds > 0 else {
      return noFreshData(language: language)
    }
    let totalSeconds = Int(seconds)
    let lang = language ?? currentLanguage()

    let days = totalSeconds / 86400
    let hours = (totalSeconds % 86400) / 3600
    let minutes = (totalSeconds % 3600) / 60

    if days >= 1 {
      switch lang {
      case .ru: return "\(days) д \(hours) ч"
      case .en: return "\(days)d \(hours)h"
      }
    }

    if hours >= 1 {
      switch lang {
      case .ru: return "\(hours) ч \(minutes) мин"
      case .en: return "\(hours)h \(minutes)m"
      }
    }

    switch lang {
    case .ru: return "\(minutes) мин"
    case .en: return "\(minutes)m"
    }
  }

  public static func countdown(from resetsAt: Date?, now: Date, language: Language? = nil) -> String
  {
    guard let resetsAt, resetsAt > now else {
      return noFreshData(language: language)
    }
    return countdown(seconds: resetsAt.timeIntervalSince(now), language: language)
  }

  // MARK: - Reset Date/Time Formatting

  public static func formatResetDate(
    _ date: Date?,
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian),
    timeZone: TimeZone = .current,
    language: Language? = nil
  ) -> String? {
    guard let date else { return nil }
    let lang = language ?? currentLanguage()
    var cal = calendar
    cal.timeZone = timeZone

    let formatter = DateFormatter()
    formatter.calendar = cal
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: lang == .ru ? "ru_RU" : "en_US_POSIX")

    if cal.isDate(date, inSameDayAs: now) {
      formatter.dateFormat = "HH:mm"
      return "↻ \(formatter.string(from: date))"
    }

    formatter.dateFormat = "EEE HH:mm"
    let formatted = formatter.string(from: date)
    let displayString = lang == .ru ? formatted.lowercased() : formatted
    return "↻ \(displayString)"
  }

  // MARK: - Spending & Prices

  public static func atApiPrices(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "по ценам API"
    case .en: return "at API prices"
    }
  }

  public static func periodToday(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Сегодня"
    case .en: return "Today"
    }
  }

  public static func periodWeek(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Неделя"
    case .en: return "Week"
    }
  }

  public static func periodMonth(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Месяц"
    case .en: return "Month"
    }
  }

  public static func tokens(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "токенов"
    case .en: return "tokens"
    }
  }

  public static func cache(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "кэш"
    case .en: return "cache"
    }
  }

  public static func unknownModels(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "неизвестные модели"
    case .en: return "unknown models"
    }
  }

  // MARK: - Agent Process & Navigation

  public static func agentProcessNotFound(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "процесс агента не найден"
    case .en: return "agent process not found"
    }
  }

  // MARK: - Empty States

  public static func emptySessions(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Нет активных агентов"
    case .en: return "No agent sessions yet"
    }
  }

  public static func emptyQuotas(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Нет данных о лимитах"
    case .en: return "No quota data"
    }
  }

  public static func emptySpending(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Нет данных о расходах"
    case .en: return "No spending data"
    }
  }

  // MARK: - Hooks Configuration & Hints

  public static func hooksNotInstalled(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Хуки не установлены"
    case .en: return "Hooks not installed"
    }
  }

  public static func copyHooks(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Скопировать"
    case .en: return "Copy"
    }
  }

  public static func copiedHooks(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Скопировано"
    case .en: return "Copied"
    }
  }

  public static func hooksSnippetHint(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Нажмите, чтобы скопировать конфигурацию хуков"
    case .en: return "Click to copy hooks configuration"
    }
  }
}
