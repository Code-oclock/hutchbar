// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Agents block: active sessions organized into waiting (with quiet ones under it)
/// and working cards, children nested under their parents.
struct PanelAgentsView: View {
  let tree: AgentTree
  let quietThresholdMinutes: Int
  let selectedSessionId: String?
  let onSelect: (SessionSnapshot) -> Void
  let onJump: (SessionSnapshot) -> Void

  private var isQuietExpandedState = SwiftUI.State<Bool>(initialValue: false)

  private var isQuietExpanded: Bool {
    get { isQuietExpandedState.wrappedValue }
    nonmutating set { isQuietExpandedState.wrappedValue = newValue }
  }

  init(
    tree: AgentTree,
    quietThresholdMinutes: Int = 60,
    selectedSessionId: String?,
    onSelect: @escaping (SessionSnapshot) -> Void,
    onJump: @escaping (SessionSnapshot) -> Void
  ) {
    self.tree = tree
    self.quietThresholdMinutes = quietThresholdMinutes
    self.selectedSessionId = selectedSessionId
    self.onSelect = onSelect
    self.onJump = onJump
  }

  /// Two cards, as in `mockup/panel-v3.html`: «Ждут тебя» (with the quiet row under it)
  /// and «Работают» (nested calls as a tree).
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !tree.waiting.isEmpty || !tree.quiet.isEmpty {
        sectionCard(title: L10n.waitingSectionTitle(), hint: L10n.waitingSectionHint()) {
          nodeList(tree.waiting)
          if !tree.quiet.isEmpty {
            quietSection
          }
        }
      }

      if !tree.working.isEmpty {
        sectionCard(title: L10n.workingSectionTitle(), hint: L10n.workingSectionHint()) {
          nodeList(tree.working)
        }
      }
    }
  }

  private func sectionCard<Content: View>(
    title: String,
    hint: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text(title.uppercased())
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        Spacer()
        Text(hint)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 6)
      .padding(.top, 2)

      content()
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }

  private func nodeList(_ nodes: [AgentNode]) -> some View {
    ForEach(nodes) { node in
      PanelRootNodeView(
        node: node,
        selectedSessionId: selectedSessionId,
        onSelect: onSelect,
        onJump: onJump
      )
    }
  }

  private var quietSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Button(action: { isQuietExpanded.toggle() }) {
        HStack {
          Text(
            L10n.quietRow(
              count: tree.quiet.count,
              thresholdMinutes: quietThresholdMinutes,
              isExpanded: isQuietExpanded
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isQuietExpanded {
        nodeList(tree.quiet)
      }
    }
  }
}

/// Interactive row representing a root session with its nested child hierarchy.
private struct PanelRootNodeView: View {
  let node: AgentNode
  let selectedSessionId: String?
  let onSelect: (SessionSnapshot) -> Void
  let onJump: (SessionSnapshot) -> Void

  init(
    node: AgentNode,
    selectedSessionId: String?,
    onSelect: @escaping (SessionSnapshot) -> Void,
    onJump: @escaping (SessionSnapshot) -> Void
  ) {
    self.node = node
    self.selectedSessionId = selectedSessionId
    self.onSelect = onSelect
    self.onJump = onJump
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let session = node.session {
        PanelAgentRowView(
          session: session,
          isSelected: selectedSessionId == session.id,
          onSelect: { onSelect(session) },
          onJump: { onJump(session) }
        )

        if !node.children.isEmpty {
          ForEach(node.children) { childNode in
            PanelChildNodeView(
              node: childNode,
              rootSession: session,
              level: 1,
              onJumpRoot: { onJump(session) }
            )
          }
        }
      }
    }
  }
}

/// Single interactive row representing an agent session.
private struct PanelAgentRowView: View {
  let session: SessionSnapshot
  let isSelected: Bool
  let onSelect: () -> Void
  let onJump: () -> Void

  init(
    session: SessionSnapshot,
    isSelected: Bool,
    onSelect: @escaping () -> Void,
    onJump: @escaping () -> Void
  ) {
    self.session = session
    self.isSelected = isSelected
    self.onSelect = onSelect
    self.onJump = onJump
  }

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
    session.agent.info.symbol
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
      session.agent.info.displayName,
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
