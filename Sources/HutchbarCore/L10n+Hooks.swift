// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension L10n {
  // MARK: - Hooks Status Labels

  public static func hooksStale(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Хуки Claude указывают на старый путь"
      : "Claude hooks point to old path"
  }

  public static func hooksUnreadable(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Не удалось прочитать settings.json"
      : "Could not read settings.json"
  }

  // MARK: - Action Buttons and Menu Items

  public static func installHooks(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Установить" : "Install"
  }

  public static func uninstallHooks(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Удалить" : "Remove"
  }

  public static func removeHooksMenuItem(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Удалить хуки Claude…" : "Remove Claude hooks…"
  }

  public static func cancel(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "Отмена" : "Cancel"
  }

  public static func ok(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru ? "ОК" : "OK"
  }

  // MARK: - Install Confirmation & Reports

  public static func installHooksConfirmationTitle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Установка хуков Claude Code"
      : "Install Claude Code Hooks"
  }

  public static func installHooksConfirmationMessage(
    profiles: [String],
    command: String,
    language: Language? = nil
  ) -> String {
    let isRussian = (language ?? currentLanguage()) == .ru
    let profileList = profiles.map { "• \($0)/settings.json" }.joined(separator: "\n")

    if isRussian {
      return """
        Будут добавлены хуки hutchbar в конфигурацию Claude Code:
        \(profileList)

        События:
        • Notification (matcher: permission_prompt|idle_prompt)
        • Stop
        • UserPromptSubmit
        • SessionEnd

        Команда:
        \(command)

        Резервная копия:
        Перед изменением рядом будет создана копия settings.json.hutchbar-backup-<дата>.
        Порядок ключей в файле настроек может измениться.

        Безопасность:
        Хуки запускают hutchbar при событиях Claude Code для обновления статуса. \
        Hutchbar только пишет метки событий в свой локальный журнал events.jsonl \
        и ничего никуда не отправляет.
        """
    } else {
      return """
        Hutchbar hooks will be added to Claude Code configuration:
        \(profileList)

        Events:
        • Notification (matcher: permission_prompt|idle_prompt)
        • Stop
        • UserPromptSubmit
        • SessionEnd

        Command:
        \(command)

        Backup:
        A backup copy settings.json.hutchbar-backup-<date> will be created next to it.
        Key ordering in the settings file may change.

        Privacy:
        Hooks run hutchbar on Claude Code events to update status. \
        Hutchbar only records event timestamps into its local events.jsonl log \
        and never sends any data anywhere.
        """
    }
  }

  public static func installHooksSuccessTitle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Хуки Claude успешно установлены"
      : "Claude Hooks Successfully Installed"
  }

  public static func installHooksSuccessMessage(
    reports: [InstallReport],
    language: Language? = nil
  ) -> String {
    let isRussian = (language ?? currentLanguage()) == .ru
    var lines: [String] = []
    lines.append(
      isRussian
        ? "Хуки успешно добавлены в конфигурацию Claude Code:"
        : "Hooks successfully added to Claude Code configuration:"
    )
    for report in reports {
      lines.append("• \(report.filePath)")
      if let backup = report.backupPath {
        lines.append(
          isRussian
            ? "  (резервная копия: \(backup))"
            : "  (backup: \(backup))"
        )
      }
    }
    return lines.joined(separator: "\n")
  }

  public static func installHooksErrorTitle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Ошибка установки хуков Claude"
      : "Failed to Install Claude Hooks"
  }

  public static func installHooksErrorMessage(
    errors: [String],
    language: Language? = nil
  ) -> String {
    let isRussian = (language ?? currentLanguage()) == .ru
    let header =
      isRussian
      ? "Не удалось установить хуки для следующих профилей:"
      : "Failed to install hooks for the following profiles:"
    return header + "\n\n" + errors.joined(separator: "\n")
  }

  // MARK: - Uninstall Confirmation & Reports

  public static func uninstallHooksConfirmationTitle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Удаление хуков Claude Code"
      : "Remove Claude Code Hooks"
  }

  public static func uninstallHooksConfirmationMessage(
    profiles: [String],
    language: Language? = nil
  ) -> String {
    let isRussian = (language ?? currentLanguage()) == .ru
    let profileList = profiles.map { "• \($0)/settings.json" }.joined(separator: "\n")

    if isRussian {
      return """
        Записи хуков hutchbar будут удалены из конфигурации Claude Code:
        \(profileList)

        Все остальные настройки и чужие хуки останутся без изменений.
        Перед изменением рядом будет создана копия settings.json.hutchbar-backup-<дата>.
        """
    } else {
      return """
        Hutchbar hook entries will be removed from Claude Code configuration:
        \(profileList)

        All other settings and foreign hooks will be preserved.
        A backup copy settings.json.hutchbar-backup-<date> will be created next to it.
        """
    }
  }

  public static func uninstallHooksSuccessTitle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Хуки Claude удалены"
      : "Claude Hooks Removed"
  }

  public static func uninstallHooksSuccessMessage(
    reports: [InstallReport],
    language: Language? = nil
  ) -> String {
    let isRussian = (language ?? currentLanguage()) == .ru
    var lines: [String] = []
    lines.append(
      isRussian
        ? "Хуки hutchbar успешно удалены:"
        : "Hutchbar hooks successfully removed:"
    )
    for report in reports {
      lines.append("• \(report.filePath)")
      if let backup = report.backupPath {
        lines.append(
          isRussian
            ? "  (резервная копия: \(backup))"
            : "  (backup: \(backup))"
        )
      }
    }
    return lines.joined(separator: "\n")
  }

  public static func uninstallHooksErrorTitle(language: Language? = nil) -> String {
    (language ?? currentLanguage()) == .ru
      ? "Ошибка удаления хуков Claude"
      : "Failed to Remove Claude Hooks"
  }

  public static func uninstallHooksErrorMessage(
    errors: [String],
    language: Language? = nil
  ) -> String {
    let isRussian = (language ?? currentLanguage()) == .ru
    let header =
      isRussian
      ? "Не удалось удалить хуки для следующих профилей:"
      : "Failed to remove hooks for the following profiles:"
    return header + "\n\n" + errors.joined(separator: "\n")
  }
}
