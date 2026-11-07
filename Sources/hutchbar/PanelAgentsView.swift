// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Full-width agents block displaying active sessions sorted by attention priority.
struct PanelAgentsView: View {
  let sessions: [SessionSnapshot]
  let selectedSessionId: String?
  let onSelect: (SessionSnapshot) -> Void
  let onJump: (SessionSnapshot) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(sessions) { session in
        PanelAgentRowView(
          session: session,
          isSelected: selectedSessionId == session.id,
          onSelect: { onSelect(session) },
          onJump: { onJump(session) }
        )
      }
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

/// Single interactive row representing an agent session.
private struct PanelAgentRowView: View {
  let session: SessionSnapshot
  let isSelected: Bool
  let onSelect: () -> Void
  let onJump: () -> Void

  private var notFoundState = SwiftUI.State<Bool>(initialValue: false)
  private var notFoundTaskState = SwiftUI.State<Task<Void, Never>?>(initialValue: nil)

  private var notFound: Bool {
    get { notFoundState.wrappedValue }
    nonmutating set { notFoundState.wrappedValue = newValue }
  }

  private var notFoundTask: Task<Void, Never>? {
    get { notFoundTaskState.wrappedValue }
    nonmutating set { notFoundTaskState.wrappedValue = newValue }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: agentIcon)
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(agentColor)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(session.projectName)
              .font(.subheadline)
              .fontWeight(.semibold)
              .lineLimit(1)

            reasonBadgeView
          }

          if let title = session.title, !title.isEmpty {
            Text(title)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 8)

        if let waitingSince = session.waitingSince {
          Text(formatWaitingTime(since: waitingSince))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text(hostDisplay)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)
      }

      if notFound {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
          Text(L10n.agentProcessNotFound())
            .font(.caption2)
        }
        .foregroundStyle(.orange)
        .padding(.leading, 24)
        .padding(.top, 2)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      triggerJump()
    }
    .onDisappear {
      notFoundTask?.cancel()
      notFoundTask = nil
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
    .accessibilityAddTraits(.isButton)
  }

  private var agentIcon: String {
    switch session.agent {
    case .claudeCode:
      return "asterisk"
    case .codex:
      return "hexagon"
    }
  }

  private var agentColor: Color {
    PanelV2Logic.agentColor(for: session.agent).color
  }

  @ViewBuilder
  private var reasonBadgeView: some View {
    switch session.state {
    case .waitingForApproval:
      Text(L10n.needsApproval())
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .foregroundStyle(.orange)

    case .waitingForInput:
      Text(L10n.yourTurn())
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.blue.opacity(0.15)))
        .foregroundStyle(.blue)

    case .running:
      Text(L10n.working())
        .font(.caption)
        .foregroundStyle(.secondary)

    case .finished:
      Text(L10n.reasonBadge(for: .finished))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var hostDisplay: String {
    if let host = TerminalJumper.hostName(for: session), !host.isEmpty {
      return "\(host) ↗"
    }
    return "↗"
  }

  private func triggerJump() {
    onSelect()
    onJump()
    let result = TerminalJumper.jump(to: session)
    if result == .notFound {
      notFoundTask?.cancel()
      withAnimation { notFound = true }
      notFoundTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        withAnimation { notFound = false }
      }
    }
  }

  private var accessibilityDescription: String {
    var parts = [
      session.projectName,
      session.agent == .claudeCode ? "Claude Code" : "Codex",
      sessionStateDescription(session.state),
    ]
    if let title = session.title, !title.isEmpty {
      parts.append(title)
    }
    if let waitingSince = session.waitingSince {
      parts.append("waited \(formatWaitingTime(since: waitingSince))")
    }
    if let host = TerminalJumper.hostName(for: session) {
      parts.append(host)
    }
    return parts.joined(separator: ", ")
  }
}
