// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension L10n {
  /// Formats the notification title combining the agent's display name and waiting reason.
  public static func notificationTitle(
    agentName: String,
    state: SessionState,
    language: Language? = nil
  ) -> String {
    let lang = language ?? currentLanguage()
    switch state {
    case .waitingForApproval:
      return lang == .ru ? "\(agentName) ждёт разрешения" : "\(agentName) needs approval"
    case .waitingForInput:
      return lang == .ru ? "\(agentName): твой ход" : "\(agentName): your turn"
    case .running, .finished:
      return agentName
    }
  }

  /// Title for the system notifications toggle in settings.
  public static func systemNotificationsToggle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Системные уведомления" : "System notifications"
  }

  /// Warning text displayed when notifications are denied in macOS System Settings.
  public static func notificationsDisabledInSystemSettings(
    language: Language? = nil
  ) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Уведомления запрещены в Системных настройках"
      : "Notifications disabled in System Settings"
  }
}
