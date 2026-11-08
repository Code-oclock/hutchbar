// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension L10n {
  // MARK: - Sessions v3 Tree & Sections

  public static func waitingSectionTitle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Ждут тебя" : "Waiting for you"
  }

  public static func workingSectionTitle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Работают" : "Working"
  }

  public static func subagent(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "сабагент" : "subagent"
  }

  public static func childDone(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "готово" : "done"
  }

  public static func quietRow(
    count: Int,
    thresholdMinutes: Int,
    isExpanded: Bool,
    language: Language? = nil
  ) -> String {
    let isRu = (language ?? currentLanguage()) == .ru
    let action = isExpanded ? (isRu ? "скрыть" : "hide") : (isRu ? "показать" : "show")
    if isRu {
      let duration: String
      switch thresholdMinutes {
      case 15: duration = "15 минут"
      case 30: duration = "30 минут"
      case 60: duration = "часа"
      case 120: duration = "2 часов"
      default: duration = "\(thresholdMinutes) минут"
      }
      return "Ещё \(count) молчат дольше \(duration) — \(action)"
    } else {
      let duration: String
      switch thresholdMinutes {
      case 15: duration = "15 minutes"
      case 30: duration = "30 minutes"
      case 60: duration = "an hour"
      case 120: duration = "2 hours"
      default: duration = "\(thresholdMinutes) minutes"
      }
      return "\(count) more quiet for over \(duration) — \(action)"
    }
  }
}
