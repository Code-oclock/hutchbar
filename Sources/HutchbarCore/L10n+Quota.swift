// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension L10n {
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

  public static func monthWindowLabel(language: Language? = nil) -> String {
    switch language ?? currentLanguage() {
    case .ru: return "Месяц"
    case .en: return "Month"
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
    if minutes == 43200 {
      return monthWindowLabel(language: lang)
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
      if minutes == 43200 { return "месяц исчерпан" }
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
}
