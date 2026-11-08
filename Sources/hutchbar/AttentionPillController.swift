// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import HutchbarCore
import SwiftUI

/// Owns the attention pill panel. See docs/specs/ui-v0.1.md, "Attention pill".
@MainActor
final class AttentionPillController {
  private let store: SessionStore
  private let onJump: @MainActor (SessionSnapshot) -> Void

  private var panel: NSPanel?
  private var autoHideTimer: Timer?
  private var policyState = AttentionPolicy.State()
  private var isHovered = false
  private var currentSession: SessionSnapshot?

  init(store: SessionStore, onJump: @escaping @MainActor (SessionSnapshot) -> Void) {
    self.store = store
    self.onJump = onJump
  }

  /// Re-evaluates AttentionPolicy; called by the app after each store update and on a 5 s timer.
  func evaluate(now: Date = Date(), thresholdSeconds: TimeInterval?) {
    let decision = AttentionPolicy.decide(
      waiting: store.waiting(now: now),
      now: now,
      threshold: thresholdSeconds,
      state: policyState
    )
    policyState = decision.newState

    if let session = decision.sessionToShow {
      show(session: session, now: now)
    } else if let activeSession = currentSession {
      let isStillWaiting = store.waiting(now: now).contains {
        $0.sessionKey == activeSession.sessionKey
      }
      if !isStillWaiting {
        hide()
      }
    }
  }

  /// Hides the pill and releases its window.
  func stop() {
    cancelAutoHideTimer()
    if let panel {
      panel.orderOut(nil)
      panel.contentViewController = nil
    }
    panel = nil
    currentSession = nil
    isHovered = false
  }

  private func show(session: SessionSnapshot, now: Date) {
    currentSession = session
    let targetPanel = ensurePanel()

    let pillView = AttentionPillView(
      session: session,
      now: now,
      onJump: { [weak self] in
        guard let self else { return }
        self.handleJump(session: session)
      },
      onHover: { [weak self] hovered in
        guard let self else { return }
        self.handleHover(hovered)
      }
    )

    let hostingController = NSHostingController(rootView: pillView)
    targetPanel.contentViewController = hostingController

    let fittingSize = hostingController.view.fittingSize
    targetPanel.setContentSize(fittingSize)
    position(panel: targetPanel)

    displayPanel(targetPanel)
    scheduleAutoHide()
  }

  private func hide() {
    cancelAutoHideTimer()
    guard let panel, panel.isVisible else {
      currentSession = nil
      return
    }

    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel.alphaValue = 0.0
      panel.orderOut(nil)
      self.currentSession = nil
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        panel.animator().alphaValue = 0.0
      } completionHandler: { [weak self, weak panel] in
        Task { @MainActor in
          panel?.orderOut(nil)
          self?.currentSession = nil
        }
      }
    }
  }

  private func displayPanel(_ panel: NSPanel) {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel.alphaValue = 1.0
      panel.orderFront(nil)
    } else {
      panel.alphaValue = 0.0
      panel.orderFront(nil)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        panel.animator().alphaValue = 1.0
      }
    }
  }

  private func handleJump(session: SessionSnapshot) {
    hide()
    onJump(session)
  }

  private func handleHover(_ hovered: Bool) {
    isHovered = hovered
    if hovered {
      cancelAutoHideTimer()
    } else {
      scheduleAutoHide()
    }
  }

  private func scheduleAutoHide() {
    cancelAutoHideTimer()
    guard !isHovered else { return }
    autoHideTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.isHovered else { return }
        self.hide()
      }
    }
  }

  private func cancelAutoHideTimer() {
    autoHideTimer?.invalidate()
    autoHideTimer = nil
  }

  private func position(panel: NSPanel) {
    let mouseLocation = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
      ?? NSScreen.main
      ?? NSScreen.screens.first

    guard let screen else { return }

    let panelSize = panel.frame.size
    let screenFrame = screen.frame
    let visibleFrame = screen.visibleFrame

    let xPosition = screenFrame.origin.x + (screenFrame.width - panelSize.width) / 2.0
    let yPosition = visibleFrame.maxY - panelSize.height - 4.0
    panel.setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
  }

  private func ensurePanel() -> NSPanel {
    if let panel {
      return panel
    }

    let createdPanel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 36),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    createdPanel.level = .statusBar
    createdPanel.collectionBehavior = [.canJoinAllSpaces]
    createdPanel.isOpaque = false
    createdPanel.backgroundColor = .clear
    createdPanel.hasShadow = true
    createdPanel.isMovable = false
    createdPanel.isReleasedWhenClosed = false
    createdPanel.hidesOnDeactivate = false

    panel = createdPanel
    return createdPanel
  }
}

/// Floating capsule view displayed inside the attention pill.
private struct AttentionPillView: View {
  let session: SessionSnapshot
  let now: Date
  let onJump: () -> Void
  let onHover: (Bool) -> Void

  var body: some View {
    Button(action: onJump) {
      HStack(spacing: 7) {
        Circle()
          .fill(statusDotColor)
          .frame(width: 8, height: 8)

        Text(session.projectName)
          .font(.system(size: 13, weight: .semibold))

        Text(sessionStateDescription(session.state))
          .font(.system(size: 13, weight: .regular))

        if let waitingSince = session.waitingSince {
          Text("·")
            .foregroundStyle(.secondary)
          Text(formatPillDuration(since: waitingSince, now: now))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay(
        Capsule()
          .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
      )
    }
    .buttonStyle(.plain)
    .onHover(perform: onHover)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityTitle)
    .accessibilityHint("Click to jump to terminal")
  }

  private var statusDotColor: Color {
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

  private var accessibilityTitle: String {
    var components = [
      session.projectName,
      sessionStateDescription(session.state),
    ]
    if let waitingSince = session.waitingSince {
      components.append(formatPillDuration(since: waitingSince, now: now))
    }
    return components.joined(separator: ", ")
  }
}
