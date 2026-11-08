// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Full-width agents block displaying active sessions organized into waiting,
/// working, and quiet sections with nested children.

/// Recursive view representing a child node (subagent session or ephemeral process).
struct PanelChildNodeView: View {
  let node: AgentNode
  let rootSession: SessionSnapshot
  let level: Int
  let onJumpRoot: () -> Void

  init(
    node: AgentNode,
    rootSession: SessionSnapshot,
    level: Int = 1,
    onJumpRoot: @escaping () -> Void
  ) {
    self.node = node
    self.rootSession = rootSession
    self.level = level
    self.onJumpRoot = onJumpRoot
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      PanelChildRowView(
        node: node,
        level: level,
        onTap: {
          onJumpRoot()
          _ = TerminalJumper.jump(to: rootSession)
        }
      )

      if !node.children.isEmpty {
        ForEach(node.children) { grandChild in
          PanelChildNodeView(
            node: grandChild,
            rootSession: rootSession,
            level: level + 1,
            onJumpRoot: onJumpRoot
          )
        }
      }
    }
  }
}

/// Single indented row for a child agent process or subagent session.
struct PanelChildRowView: View {
  let node: AgentNode
  let level: Int
  let onTap: () -> Void

  init(
    node: AgentNode,
    level: Int = 1,
    onTap: @escaping () -> Void
  ) {
    self.node = node
    self.level = level
    self.onTap = onTap
  }

  var body: some View {
    HStack(spacing: 0) {
      indentationGuide

      HStack(spacing: 8) {
        agentMarkView

        titleView

        Spacer(minLength: 8)

        statusAndElapsedView
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture {
      onTap()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
    .accessibilityAddTraits(.isButton)
  }

  private var indentationGuide: some View {
    let indentWidth = CGFloat(level) * 22.0
    return ZStack(alignment: .leading) {
      Color.clear.frame(width: indentWidth, height: 18)
      Rectangle()
        .fill(Color.primary.opacity(0.18))
        .frame(width: 1)
        .padding(.leading, indentWidth - 12.0)
    }
  }

  @ViewBuilder
  private var agentMarkView: some View {
    if let eph = node.ephemeral {
      ephemeralMark(for: eph.executableName)
    } else if let session = node.session {
      sessionMark(for: session.agent)
    }
  }

  @ViewBuilder
  private func ephemeralMark(for name: String) -> some View {
    if let agent = AgentKind.forExecutable(name) {
      Image(systemName: agent.info.symbol)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(agent.info.color.color)
        .frame(width: 14)
    } else {
      Image(systemName: "circle.fill")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(Color.secondary)
        .frame(width: 14)
    }
  }

  @ViewBuilder
  private func sessionMark(for agent: AgentKind) -> some View {
    Image(systemName: agent.info.symbol)
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(agent.info.color.color)
      .frame(width: 14)
  }

  @ViewBuilder
  private var titleView: some View {
    if let eph = node.ephemeral {
      Text(eph.displayName)
        .font(.subheadline)
        .lineLimit(1)
    } else if let session = node.session {
      let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let title, !title.isEmpty {
        Text(title)
          .font(.subheadline)
          .lineLimit(1)
      } else {
        Text(L10n.subagent())
          .font(.subheadline)
          .lineLimit(1)
      }
    }
  }

  @ViewBuilder
  private var statusAndElapsedView: some View {
    HStack(spacing: 6) {
      if isFinished {
        Text(L10n.childDone())
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text(L10n.working())
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let startTime = childStartTime {
        Text(formatWaitingTime(since: startTime))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var isFinished: Bool {
    node.session?.state == .finished
  }

  private var childStartTime: Date? {
    if let eph = node.ephemeral {
      return eph.startedAt
    }
    if let session = node.session {
      return session.waitingSince ?? session.lastActivity
    }
    return nil
  }

  private var accessibilityText: String {
    let name: String
    if let eph = node.ephemeral {
      name = eph.displayName
    } else if let title = node.session?.title, !title.isEmpty {
      name = title
    } else {
      name = L10n.subagent()
    }
    let status = isFinished ? L10n.childDone() : L10n.working()
    return "\(name), \(status)"
  }
}
