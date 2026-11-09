// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import HutchbarCore
import SwiftUI

/// Popover panel v2: header with period switcher, full-width agents block,
/// two-column quota cards, spending and trend cards, and hooks status footer.
struct PanelView: View {
  let store: SessionStore
  let usage: UsageViewModel
  let onJump: @MainActor (SessionSnapshot) -> Void
  var onClose: (@MainActor () -> Void)?
  var onOpenSettings: (@MainActor () -> Void)?

  private let scrollable: Bool
  private let initialHooksStatus: HooksStatus?

  private var selectedSessionIdState = SwiftUI.State<String?>(initialValue: nil)
  private var copiedHooksState = SwiftUI.State<Bool>(initialValue: false)
  private var copyTaskState = SwiftUI.State<Task<Void, Never>?>(initialValue: nil)
  private var hooksStatusState = SwiftUI.State<HooksStatus>(initialValue: .notInstalled)
  private var lastHooksCheckState = SwiftUI.State<Date?>(initialValue: nil)
  @FocusState private var isFocused: Bool

  private var selectedSessionId: String? {
    get { selectedSessionIdState.wrappedValue }
    nonmutating set { selectedSessionIdState.wrappedValue = newValue }
  }

  private var copiedHooks: Bool {
    get { copiedHooksState.wrappedValue }
    nonmutating set { copiedHooksState.wrappedValue = newValue }
  }

  private var copyTask: Task<Void, Never>? {
    get { copyTaskState.wrappedValue }
    nonmutating set { copyTaskState.wrappedValue = newValue }
  }

  fileprivate var hooksStatus: HooksStatus {
    get { hooksStatusState.wrappedValue }
    nonmutating set { hooksStatusState.wrappedValue = newValue }
  }

  fileprivate var lastHooksCheck: Date? {
    get { lastHooksCheckState.wrappedValue }
    nonmutating set { lastHooksCheckState.wrappedValue = newValue }
  }

  init(
    store: SessionStore,
    usage: UsageViewModel = UsageViewModel(),
    onJump: @escaping @MainActor (SessionSnapshot) -> Void,
    onClose: (@MainActor () -> Void)? = nil,
    onOpenSettings: (@MainActor () -> Void)? = nil,
    scrollable: Bool = true,
    initialHooksStatus: HooksStatus? = nil
  ) {
    self.store = store
    self.usage = usage
    self.onJump = onJump
    self.onClose = onClose
    self.onOpenSettings = onOpenSettings
    self.scrollable = scrollable
    self.initialHooksStatus = initialHooksStatus
    if let initialHooksStatus {
      self.hooksStatusState = SwiftUI.State(initialValue: initialHooksStatus)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if scrollable {
        ScrollView {
          panelContent
        }
        .frame(maxHeight: 520)
      } else {
        panelContent
      }

      let showClaudeLogin = store.sourceStatus[.claudeUsage] == false && !hasOtherClaudeData
      let showCodexLogin = store.sourceStatus[.codexUsage] == false && !hasOtherCodexData

      if showClaudeLogin || showCodexLogin {
        VStack(alignment: .leading, spacing: 6) {
          if showClaudeLogin {
            footerHintRow(text: L10n.claudeLoginHint())
          }
          if showCodexLogin {
            footerHintRow(text: L10n.codexLoginHint())
          }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
      }

      Divider()
      PanelFooterView(
        hooksStatus: hooksStatus,
        onInstallHooks: installHooksWithConfirmation,
        onCopyHooks: copyHooksConfiguration,
        copied: copiedHooks,
        onOpenSettings: onOpenSettings
      )
    }
    .frame(width: 560)
    .background(.regularMaterial)
    .focusable()
    .focused($isFocused)
    .onKeyPress(.upArrow) {
      selectPrevious()
      return .handled
    }
    .onKeyPress(.downArrow) {
      selectNext()
      return .handled
    }
    .onKeyPress(.return) {
      jumpToSelected()
      return .handled
    }
    .onKeyPress(.escape) {
      closePanel()
      return .handled
    }
    .onAppear {
      isFocused = true
      if selectedSessionId == nil {
        selectedSessionId = selectableSessions.first?.id
      }
      if initialHooksStatus == nil {
        refreshHooksStatus(force: false)
      }
    }
    .onDisappear {
      copyTask?.cancel()
      copyTask = nil
    }
  }

  private var panelContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      PanelHeaderView(usage: usage, onClose: closePanel)

      let tree = store.agentTree(now: Date())
      if !tree.isEmpty {
        PanelAgentsView(
          tree: tree,
          quietThresholdMinutes: quietThresholdMinutes,
          selectedSessionId: selectedSessionId,
          onSelect: { session in selectedSessionId = session.id },
          onJump: onJump
        )
      }

      PanelQuotasView(presentation: QuotaPresentation(quotas: store.quotas, now: Date()))

      HStack(alignment: .top, spacing: 10) {
        PanelSpendingView(usage: usage)
        PanelTrendView(usage: usage)
      }
    }
    .padding(12)
  }

  private var quietThresholdMinutes: Int {
    if let quietAfter = store.quietAfter {
      return max(1, Int(quietAfter / 60.0))
    }
    return 60
  }

  private var selectableSessions: [SessionSnapshot] {
    let tree = store.agentTree(now: Date())
    var result: [SessionSnapshot] = []
    for node in tree.waiting {
      if let session = node.session { result.append(session) }
    }
    for node in tree.working {
      if let session = node.session { result.append(session) }
    }
    for node in tree.quiet {
      if let session = node.session { result.append(session) }
    }
    return result
  }

  private func selectPrevious() {
    let sessions = selectableSessions
    guard !sessions.isEmpty else { return }
    guard let selectedSessionId,
      let index = sessions.firstIndex(where: { $0.id == selectedSessionId })
    else {
      self.selectedSessionId = sessions.first?.id
      return
    }
    if index > 0 {
      self.selectedSessionId = sessions[index - 1].id
    }
  }

  private func selectNext() {
    let sessions = selectableSessions
    guard !sessions.isEmpty else { return }
    guard let selectedSessionId,
      let index = sessions.firstIndex(where: { $0.id == selectedSessionId })
    else {
      self.selectedSessionId = sessions.first?.id
      return
    }
    if index + 1 < sessions.count {
      self.selectedSessionId = sessions[index + 1].id
    }
  }

  private func jumpToSelected() {
    let sessions = selectableSessions
    guard let selectedSessionId,
      let session = sessions.first(where: { $0.id == selectedSessionId })
    else {
      if let first = sessions.first {
        onJump(first)
      }
      return
    }
    onJump(session)
  }

  private func closePanel() {
    if let onClose {
      onClose()
    } else {
      NSApp.keyWindow?.performClose(nil)
    }
  }

  private func copyHooksConfiguration() {
    let executable = HutchbarApp.currentExecutablePath()
    let snippet = generateHooksConfiguration(binaryPath: executable)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(snippet, forType: .string)

    copyTask?.cancel()
    copiedHooks = true
    copyTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }
      copiedHooks = false
    }
  }

  private var hasOtherClaudeData: Bool {
    store.quotas.values.contains { $0.agent == .claudeCode }
      || store.waiting.contains { $0.agent == .claudeCode }
      || store.working.contains { $0.agent == .claudeCode }
  }

  private var hasOtherCodexData: Bool {
    store.quotas.values.contains { $0.agent == .codex }
      || store.waiting.contains { $0.agent == .codex }
      || store.working.contains { $0.agent == .codex }
  }

  private func footerHintRow(text: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
        .font(.caption)

      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.secondary.opacity(0.1))
    )
  }
}

// MARK: - Hooks Management Extension

extension PanelView {
  fileprivate func refreshHooksStatus(force: Bool = false) {
    let now = Date()
    if !force, let lastCheck = lastHooksCheck, now.timeIntervalSince(lastCheck) < 3.0 {
      return
    }
    let defaultDir = ClaudeHooksInstaller.defaultSettingsDirectory()
    hooksStatus = ClaudeHooksInstaller.status(at: defaultDir)
    lastHooksCheck = now
  }

  fileprivate func installHooksWithConfirmation() {
    let profileDirs = ClaudeHooksInstaller.discoveredProfileDirectories()
    let binaryPath = HutchbarApp.currentExecutablePath()
    let command =
      "\(ClaudeHooksInstaller.shellQuoted(binaryPath))\(ClaudeHooksInstaller.hookSuffix)"

    let alert = NSAlert()
    alert.messageText = L10n.installHooksConfirmationTitle()
    alert.informativeText = L10n.installHooksConfirmationMessage(
      profiles: profileDirs,
      command: command
    )
    alert.addButton(withTitle: L10n.installHooks())
    alert.addButton(withTitle: L10n.cancel())
    alert.alertStyle = .informational

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    var reports: [InstallReport] = []
    var errors: [String] = []

    for dir in profileDirs {
      do {
        let report = try ClaudeHooksInstaller.install(at: dir, binaryPath: binaryPath)
        reports.append(report)
      } catch {
        errors.append("\(dir): \(error.localizedDescription)")
      }
    }

    refreshHooksStatus(force: true)

    let summaryAlert = NSAlert()
    if errors.isEmpty {
      summaryAlert.alertStyle = .informational
      summaryAlert.messageText = L10n.installHooksSuccessTitle()
      summaryAlert.informativeText = L10n.installHooksSuccessMessage(reports: reports)
    } else {
      summaryAlert.alertStyle = .warning
      summaryAlert.messageText = L10n.installHooksErrorTitle()
      summaryAlert.informativeText = L10n.installHooksErrorMessage(errors: errors)
    }
    summaryAlert.addButton(withTitle: L10n.ok())
    summaryAlert.runModal()
  }
}
