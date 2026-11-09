// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Configuration Defaults for Copilot and OpenCode

extension SourceCoordinator.Configuration {
  public static var defaultCopilotSessionRoot: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".copilot/session-state").path
  }

  public static var defaultOpenCodeDatabasePath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/opencode/opencode.db").path
  }
}
