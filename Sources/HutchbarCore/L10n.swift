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

  /// Interface language preference: system (default), Russian, or English.
  public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case ru
    case en

    public var id: String { rawValue }

    public var title: String {
      switch self {
      case .system: return "Системный"
      case .ru: return "Русский"
      case .en: return "English"
      }
    }
  }

  // MARK: - Language Resolution & Override

  private static let overrideLock = NSLock()
  private static nonisolated(unsafe) var _overrideLanguage: Language?
  private static nonisolated(unsafe) var _preference: InterfaceLanguage = .system

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

  /// Configured interface language preference from settings.
  public static var preference: InterfaceLanguage {
    get {
      overrideLock.lock()
      defer { overrideLock.unlock() }
      return _preference
    }
    set {
      overrideLock.lock()
      defer { overrideLock.unlock() }
      _preference = newValue
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

  /// Active language: explicit override, user preference, or detected from preferred languages.
  public static func currentLanguage(
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> Language {
    if let override = overrideLanguage {
      return override
    }
    switch preference {
    case .ru:
      return .ru
    case .en:
      return .en
    case .system:
      return detectLanguage(from: preferredLanguages)
    }
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

  public static func windowUsedUp(
    windowName: String,
    minutes: Int,
    language: Language? = nil
  ) -> String {
    let lang = language ?? currentLanguage()
    switch lang {
    case .ru:
      if minutes == 10080 { return "неделя исчерпана" }
      if minutes == 300 { return "сессия исчерпана" }
      return "\(windowName.lowercased()) исчерпано"
    case .en:
      return "\(windowName.lowercased()) used up"
    }
  }

  public static func secondaryRemaining(
    windowName: String,
    percent: Int,
    language: Language? = nil
  ) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "\(windowName.lowercased()): осталось \(percent) %"
    case .en: return "\(windowName.lowercased()): remaining \(percent)%"
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
      return lang == .ru ? "\(days) д \(hours) ч" : "\(days)d \(hours)h"
    }

    if hours >= 1 {
      return lang == .ru ? "\(hours) ч \(minutes) мин" : "\(hours)h \(minutes)m"
    }

    return lang == .ru ? "\(minutes) мин" : "\(minutes)m"
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
    isUntil: Bool = false,
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

    let prefix = isUntil ? (lang == .ru ? "до " : "until ") : "↻ "

    if cal.isDate(date, inSameDayAs: now) {
      formatter.dateFormat = "HH:mm"
      return "\(prefix)\(formatter.string(from: date))"
    }

    formatter.dateFormat = "EEE HH:mm"
    let formatted = formatter.string(from: date)
    let displayString = lang == .ru ? formatted.lowercased() : formatted
    return "\(prefix)\(displayString)"
  }

  // MARK: - Spending & Prices

  public static func noPrice(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "нет цены"
    case .en: return "no price"
    }
  }

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
    (language ?? currentLanguage()) == .ru ? "Нет данных о расходах" : "No spending data"
  }

  // MARK: - Hooks Configuration & Hints

  public static func hooksNotInstalled(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Хуки не установлены" : "Hooks not installed"
  }

  public static func copyHooks(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Скопировать" : "Copy"
  }

  public static func copiedHooks(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Скопировано" : "Copied"
  }

  public static func hooksSnippetHint(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Нажмите, чтобы скопировать конфигурацию хуков"
    case .en: return "Click to copy hooks configuration"
    }
  }

  // MARK: - Quotas v3 & Limits

  public static func updatesOnNextRequest(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "обновится при запросе" : "updates on next request"
  }

  public static func notStarted(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "не начато" : "not started"
  }

  public static func dataAsOf(_ time: String, language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "данные от \(time)" : "as of \(time)"
  }

  public static func currentAccountNow(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "● сейчас" : "● now"
  }

  public static func resetCredits(_ count: Int, language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .en:
      return count == 1 ? "1 reset" : "\(count) resets"
    case .ru:
      let mod10 = count % 10
      let mod100 = count % 100
      if mod10 == 1 && mod100 != 11 {
        return "\(count) сброс"
      } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
        return "\(count) сброса"
      }
      return "\(count) сбросов"
    }
  }

  public static func claudeLoginHint(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Войдите в Claude Code: claude /login" : "Sign in to Claude Code: claude /login"
  }

  public static func codexLoginHint(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Войдите в Codex: codex login" : "Sign in to Codex: codex login"
  }
}
