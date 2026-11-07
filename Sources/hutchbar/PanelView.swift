// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import HutchbarCore
import SwiftUI

/// Popover content: waiting queue, working sessions, quotas. See docs/specs/ui-v0.1.md.
struct PanelView: View {
  let store: SessionStore
  let onJump: @MainActor (SessionSnapshot) -> Void
  var onClose: (@MainActor () -> Void)?

  private var selectedSessionIdState = SwiftUI.State<String?>(initialValue: nil)
  private var copiedHooksState = SwiftUI.State<Bool>(initialValue: false)
  @FocusState private var isFocused: Bool

  private var selectedSessionId: String? {
    get { selectedSessionIdState.wrappedValue }
    nonmutating set { selectedSessionIdState.wrappedValue = newValue }
  }

  private var copiedHooks: Bool {
    get { copiedHooksState.wrappedValue }
    nonmutating set { copiedHooksState.wrappedValue = newValue }
  }

  init(
    store: SessionStore,
    onJump: @escaping @MainActor (SessionSnapshot) -> Void,
    onClose: (@MainActor () -> Void)? = nil
  ) {
    self.store = store
    self.onJump = onJump
    self.onClose = onClose
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if !store.waiting.isEmpty {
            SectionHeaderView(title: "Waiting for you", count: store.waiting.count)
            ForEach(store.waiting) { session in
              SessionRowView(
                session: session,
                isSelected: selectedSessionId == session.id,
                onSelect: { selectedSessionId = session.id },
                onJump: { onJump(session) }
              )
            }
          }

          if !store.working.isEmpty {
            SectionHeaderView(title: "Working", count: store.working.count)
            ForEach(store.working) { session in
              SessionRowView(
                session: session,
                isSelected: selectedSessionId == session.id,
                onSelect: { selectedSessionId = session.id },
                onJump: { onJump(session) }
              )
            }
          }

          if store.waiting.isEmpty && store.working.isEmpty {
            EmptySessionsView()
          }

          if !store.quotas.isEmpty {
            SectionHeaderView(title: "Quotas", count: nil)
            let sortedQuotas = store.quotas.values.sorted { $0.id < $1.id }
            ForEach(sortedQuotas) { quota in
              ForEach(quota.windows.indices, id: \.self) { index in
                QuotaRowView(quota: quota, window: quota.windows[index])
              }
            }
          }
        }
        .padding(10)
      }
      .frame(maxHeight: 480)

      let hooksInstalled = store.sourceStatus[.claudeHooks] == true
      if !hooksInstalled {
        Divider()
        PanelFooterView(
          hooksInstalled: hooksInstalled,
          onCopyHooks: copyHooksConfiguration,
          copied: copiedHooks
        )
        .padding(8)
      }
    }
    .frame(width: 340)
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
        selectedSessionId = visibleSessions.first?.id
      }
    }
  }

  private var visibleSessions: [SessionSnapshot] {
    var sessions = store.waiting
    sessions.append(contentsOf: store.working)
    if store.showFinished {
      sessions.append(contentsOf: store.finished)
    }
    return sessions
  }

  private func selectPrevious() {
    let sessions = visibleSessions
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
    let sessions = visibleSessions
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
    let sessions = visibleSessions
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
    let executable = Bundle.main.executablePath ?? "hutchbar"
    let snippet = generateHooksConfiguration(binaryPath: executable)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(snippet, forType: .string)
    copiedHooks = true

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      copiedHooks = false
    }
  }
}

/// One row representing an agent session.
private struct SessionRowView: View {
  let session: SessionSnapshot
  let isSelected: Bool
  let onSelect: () -> Void
  let onJump: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)

      VStack(alignment: .leading, spacing: 1) {
        Text(session.projectName)
          .font(.subheadline)
          .fontWeight(.medium)
          .lineLimit(1)

        if let title = session.title, !title.isEmpty {
          Text(title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 4)

      Image(systemName: agentSymbol)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(agentAccessibilityName)

      if let waitingSince = session.waitingSince {
        Text(formatWaitingTime(since: waitingSince))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button(action: onJump) {
        Image(systemName: "arrow.up.forward.app")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Jump to terminal")
      .accessibilityLabel("Jump to terminal for \(session.projectName)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect()
      onJump()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(rowAccessibilityLabel)
  }

  private var statusColor: Color {
    switch session.state {
    case .waitingForApproval:
      return .orange
    case .waitingForInput:
      return .blue
    case .running:
      return .green
    case .finished:
      return .secondary
    }
  }

  private var agentSymbol: String {
    switch session.agent {
    case .claudeCode:
      return "sparkles"
    case .codex:
      return "chevron.left.forwardslash.chevron.right"
    }
  }

  private var agentAccessibilityName: String {
    switch session.agent {
    case .claudeCode:
      return "Claude Code"
    case .codex:
      return "Codex"
    }
  }

  private var rowAccessibilityLabel: String {
    var parts = [
      session.projectName,
      agentAccessibilityName,
      sessionStateDescription(session.state),
    ]
    if let title = session.title, !title.isEmpty {
      parts.append(title)
    }
    if let waitingSince = session.waitingSince {
      parts.append("waited \(formatWaitingTime(since: waitingSince))")
    }
    return parts.joined(separator: ", ")
  }
}

/// One row representing an account quota window.
private struct QuotaRowView: View {
  let quota: AccountQuota
  let window: QuotaWindow

  var body: some View {
    HStack(spacing: 8) {
      Text("\(quota.accountName) · \(formatQuotaWindowDuration(window.windowMinutes))")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(minWidth: 80, alignment: .leading)

      Spacer(minLength: 4)

      QuotaBarView(percent: window.usedPercent)
        .frame(width: 70, height: 6)

      Text(formatPercent(window.usedPercent))
        .font(.caption.monospacedDigit())
        .frame(minWidth: 36, alignment: .trailing)

      if let resetText = formatQuotaReset(resetsAt: window.resetsAt) {
        Text(resetText)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(minWidth: 50, alignment: .trailing)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }

  private var accessibilityDescription: String {
    let windowName = formatQuotaWindowDuration(window.windowMinutes)
    let percentText = formatPercent(window.usedPercent)
    let reset = formatQuotaReset(resetsAt: window.resetsAt) ?? ""
    return "\(quota.accountName) \(windowName), \(percentText) used"
      + (reset.isEmpty ? "" : ", reset \(reset)")
  }
}

/// Horizontal bar visualizing quota utilization.
private struct QuotaBarView: View {
  let percent: Double

  var body: some View {
    GeometryReader { geometry in
      let clamped = min(max(percent, 0.0), 100.0) / 100.0
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.2))

        Capsule()
          .fill(barColor)
          .frame(width: max(0, geometry.size.width * CGFloat(clamped)))
      }
    }
  }

  private var barColor: Color {
    if percent >= 95.0 {
      return .red
    }
    if percent >= 80.0 {
      return .orange
    }
    return .accentColor
  }
}

/// Footer displaying hooks warning and copy snippet button.
private struct PanelFooterView: View {
  let hooksInstalled: Bool
  let onCopyHooks: () -> Void
  let copied: Bool

  var body: some View {
    VStack(spacing: 6) {
      if !hooksInstalled {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.caption)

          Text("Hooks not installed")
            .font(.caption)
            .foregroundStyle(.secondary)

          Spacer()

          Button(action: onCopyHooks) {
            HStack(spacing: 4) {
              Image(systemName: copied ? "checkmark" : "doc.on.doc")
              Text(copied ? "Copied" : "Copy")
            }
            .font(.caption)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityLabel("Copy hooks configuration")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.orange.opacity(0.1))
        )
      }
    }
  }
}

/// Header for panel sections.
private struct SectionHeaderView: View {
  let title: String
  let count: Int?

  var body: some View {
    HStack {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)

      if let count {
        Text("\(count)")
          .font(.caption2)
          .fontWeight(.bold)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.secondary.opacity(0.2)))
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(.horizontal, 8)
    .padding(.top, 4)
  }
}

/// Empty state message displayed when no sessions exist.
private struct EmptySessionsView: View {
  var body: some View {
    VStack(spacing: 6) {
      Text("No agent sessions yet")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }
}
