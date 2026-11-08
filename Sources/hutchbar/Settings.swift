// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Observation
import ServiceManagement
import SwiftUI

/// Predefined attention pill waiting duration thresholds.
public enum PillThreshold: Int, CaseIterable, Identifiable, Sendable {
  case thirty = 30
  case sixty = 60
  case twoMinutes = 120
  case fiveMinutes = 300
  case off = 0

  public var id: Int { rawValue }

  public var seconds: TimeInterval? {
    switch self {
    case .thirty: return 30
    case .sixty: return 60
    case .twoMinutes: return 120
    case .fiveMinutes: return 300
    case .off: return nil
    }
  }

  public var title: String {
    switch self {
    case .thirty: return "30 seconds"
    case .sixty: return "60 seconds (default)"
    case .twoMinutes: return "2 minutes"
    case .fiveMinutes: return "5 minutes"
    case .off: return "Off"
    }
  }
}

/// Predefined quiet session duration thresholds in minutes.
public enum QuietThreshold: Int, CaseIterable, Identifiable, Sendable {
  case fifteen = 15
  case thirty = 30
  case sixty = 60
  case twoHours = 120
  case never = 0

  public var id: Int { rawValue }

  public var seconds: TimeInterval? {
    switch self {
    case .fifteen: return 15 * 60
    case .thirty: return 30 * 60
    case .sixty: return 60 * 60
    case .twoHours: return 120 * 60
    case .never: return nil
    }
  }

  public var title: String {
    L10n.quietThresholdOption(minutes: rawValue)
  }
}

extension SourceKind {
  public var displayName: String {
    switch self {
    case .claudeTranscripts:
      return "Claude Code transcripts"
    case .claudeHooks:
      return "Claude Code hooks"
    case .codexSessions:
      return "Codex sessions"
    case .ccrQuotas:
      return "Claude Code quotas (ccr)"
    case .claudeLive:
      return "Claude Code live sessions"
    case .claudeUsage:
      return "Claude Code usage"
    case .codexUsage:
      return "Codex usage"
    case .antigravityUsage:
      return "Antigravity usage"
    }
  }
}

/// Observable application settings backed by UserDefaults and SMAppService.
@MainActor
@Observable
public final class Settings {
  private enum Keys {
    static let pillThreshold = "hutchbar.pillThreshold"
    static let quietAfterMinutes = "hutchbar.quietAfterMinutes"
    static let showFinished = "hutchbar.showFinished"
    static let notifications = "hutchbar.notifications"
    static let enabledSources = "hutchbar.enabledSources"
    static let usagePeriod = "hutchbar.usagePeriod"
    static let language = "hutchbar.language"
  }

  private let userDefaults: UserDefaults

  public var onShowFinishedChange: ((Bool) -> Void)?
  public var onQuietAfterChange: ((TimeInterval?) -> Void)?
  public var onEnabledSourcesChange: ((Set<SourceKind>) -> Void)?
  public var onUsagePeriodChange: ((UsagePeriod) -> Void)?

  public var language: L10n.InterfaceLanguage {
    didSet {
      userDefaults.set(language.rawValue, forKey: Keys.language)
      L10n.preference = language
    }
  }

  public var usagePeriod: UsagePeriod {
    didSet {
      userDefaults.set(usagePeriod.rawValue, forKey: Keys.usagePeriod)
      onUsagePeriodChange?(usagePeriod)
    }
  }

  public var pillThreshold: PillThreshold {
    didSet {
      userDefaults.set(pillThreshold.rawValue, forKey: Keys.pillThreshold)
    }
  }

  public var pillThresholdSeconds: TimeInterval? {
    pillThreshold.seconds
  }

  public var quietThreshold: QuietThreshold {
    didSet {
      userDefaults.set(quietThreshold.rawValue, forKey: Keys.quietAfterMinutes)
      onQuietAfterChange?(quietThreshold.seconds)
    }
  }

  public var quietAfterMinutes: Int {
    get { quietThreshold.rawValue }
    set {
      quietThreshold = QuietThreshold(rawValue: newValue) ?? (newValue == 0 ? .never : .sixty)
    }
  }

  public var quietAfterSeconds: TimeInterval? {
    quietThreshold.seconds
  }

  public var showFinished: Bool {
    didSet {
      userDefaults.set(showFinished, forKey: Keys.showFinished)
      onShowFinishedChange?(showFinished)
    }
  }

  public var notifications: Bool {
    didSet {
      userDefaults.set(notifications, forKey: Keys.notifications)
    }
  }

  public var enabledSources: Set<SourceKind> {
    didSet {
      let rawValues = enabledSources.map(\.rawValue)
      userDefaults.set(rawValues, forKey: Keys.enabledSources)
      onEnabledSourcesChange?(enabledSources)
    }
  }

  public var launchAtLoginError: String?

  public var launchAtLogin: Bool {
    get {
      SMAppService.mainApp.status == .enabled
    }
    set {
      launchAtLoginError = nil
      do {
        if newValue {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      } catch {
        launchAtLoginError = error.localizedDescription
      }
    }
  }

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults

    let resolvedLanguage: L10n.InterfaceLanguage
    if let storedLang = userDefaults.string(forKey: Keys.language),
      let lang = L10n.InterfaceLanguage(rawValue: storedLang)
    {
      resolvedLanguage = lang
    } else {
      resolvedLanguage = .system
    }
    self.language = resolvedLanguage
    // Property setters do not run during init; apply the stored choice explicitly.
    L10n.preference = resolvedLanguage

    if let storedThreshold = userDefaults.object(forKey: Keys.pillThreshold) as? Int,
      let threshold = PillThreshold(rawValue: storedThreshold)
    {
      self.pillThreshold = threshold
    } else {
      self.pillThreshold = .sixty
    }

    if let storedQuiet = userDefaults.object(forKey: Keys.quietAfterMinutes) as? Int,
      let threshold = QuietThreshold(rawValue: storedQuiet)
    {
      self.quietThreshold = threshold
    } else {
      self.quietThreshold = .sixty
    }

    self.showFinished = userDefaults.bool(forKey: Keys.showFinished)
    self.notifications = userDefaults.bool(forKey: Keys.notifications)

    if let storedPeriod = userDefaults.string(forKey: Keys.usagePeriod),
      let period = UsagePeriod(rawValue: storedPeriod)
    {
      self.usagePeriod = period
    } else {
      self.usagePeriod = .today
    }

    if let rawSources = userDefaults.stringArray(forKey: Keys.enabledSources) {
      let decoded = rawSources.compactMap { SourceKind(rawValue: $0) }
      self.enabledSources = Set(decoded)
    } else {
      self.enabledSources = Set(SourceKind.allCases)
    }

    L10n.preference = resolvedLanguage
  }

  public func isSourceEnabled(_ source: SourceKind) -> Bool {
    enabledSources.contains(source)
  }

  public func setSource(_ source: SourceKind, enabled: Bool) {
    if enabled {
      enabledSources.insert(source)
    } else {
      enabledSources.remove(source)
    }
  }
}

/// SwiftUI Settings form displayed inside the settings window.
struct SettingsView: View {
  @Bindable var settings: Settings

  var body: some View {
    Form {
      Section("Language") {
        Picker("Interface language", selection: $settings.language) {
          ForEach(L10n.InterfaceLanguage.allCases) { lang in
            Text(lang.title).tag(lang)
          }
        }
      }

      Section("Attention Pill") {
        Picker("Waiting threshold", selection: $settings.pillThreshold) {
          ForEach(PillThreshold.allCases) { threshold in
            Text(threshold.title).tag(threshold)
          }
        }
        Toggle("System notifications", isOn: $settings.notifications)
      }

      Section("Sessions") {
        Picker(L10n.quietSessionsAfter(), selection: $settings.quietThreshold) {
          ForEach(QuietThreshold.allCases) { threshold in
            Text(threshold.title).tag(threshold)
          }
        }
        Toggle("Show finished sessions", isOn: $settings.showFinished)
      }

      Section("Startup") {
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { settings.launchAtLogin },
            set: { settings.launchAtLogin = $0 }
          )
        )
        if let error = settings.launchAtLoginError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section("Sources") {
        ForEach(SourceKind.allCases, id: \.self) { source in
          Toggle(
            source.displayName,
            isOn: Binding(
              get: { settings.isSourceEnabled(source) },
              set: { settings.setSource(source, enabled: $0) }
            )
          )
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 440)
    .padding()
  }
}

/// Controller managing a single reused settings window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()

  private var window: NSWindow?

  func show(settings: Settings) {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hostingController = NSHostingController(rootView: SettingsView(settings: settings))
    let newWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    newWindow.title = "Settings"
    newWindow.contentViewController = hostingController
    newWindow.center()
    newWindow.isReleasedWhenClosed = false
    newWindow.delegate = self
    self.window = newWindow

    newWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() {
    window?.close()
  }
}
