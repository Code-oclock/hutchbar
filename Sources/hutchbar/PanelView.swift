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

  private let scrollable: Bool

  private var selectedSessionIdState = SwiftUI.State<String?>(initialValue: nil)
  private var copiedHooksState = SwiftUI.State<Bool>(initialValue: false)
  private var copyTaskState = SwiftUI.State<Task<Void, Never>?>(initialValue: nil)
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

  init(
    store: SessionStore,
    usage: UsageViewModel = UsageViewModel(),
    onJump: @escaping @MainActor (SessionSnapshot) -> Void,
    onClose: (@MainActor () -> Void)? = nil,
    scrollable: Bool = true
  ) {
    self.store = store
    self.usage = usage
    self.onJump = onJump
    self.onClose = onClose
    self.scrollable = scrollable
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

      let hooksInstalled = store.sourceStatus[.claudeHooks] == true
      let showClaudeLogin = store.sourceStatus[.claudeUsage] == false && !hasOtherClaudeData
      let showCodexLogin = store.sourceStatus[.codexUsage] == false && !hasOtherCodexData

      if !hooksInstalled || showClaudeLogin || showCodexLogin {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
          if !hooksInstalled {
            PanelFooterView(
              hooksInstalled: hooksInstalled,
              onCopyHooks: copyHooksConfiguration,
              copied: copiedHooks
            )
          }
          if showClaudeLogin {
            footerHintRow(text: L10n.claudeLoginHint())
          }
          if showCodexLogin {
            footerHintRow(text: L10n.codexLoginHint())
          }
        }
        .padding(8)
      }
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
        selectedSessionId = sortedSessions.first?.id
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

      if !sortedSessions.isEmpty {
        PanelAgentsView(
          sessions: sortedSessions,
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

  private var visibleSessions: [SessionSnapshot] {
    var sessions = store.waiting
    sessions.append(contentsOf: store.working)
    if store.showFinished {
      sessions.append(contentsOf: store.finished)
    }
    return sessions
  }

  private var sortedSessions: [SessionSnapshot] {
    PanelV2Logic.sortSessions(visibleSessions)
  }

  private func selectPrevious() {
    let sessions = sortedSessions
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
    let sessions = sortedSessions
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
    let sessions = sortedSessions
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
