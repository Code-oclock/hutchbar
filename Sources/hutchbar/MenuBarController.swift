// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import HutchbarCore
import Observation
import SwiftUI

/// Manages the menu bar status item, status icon updates, and click actions.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
  public static var onPanelVisibilityChange: (@MainActor (Bool) -> Void)?
  public var onPanelVisibilityChange: (@MainActor (Bool) -> Void)?

  private let store: SessionStore
  private let usage: UsageViewModel
  private let settings: Settings
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var isStopped = false

  public init(
    store: SessionStore,
    usage: UsageViewModel = UsageViewModel(),
    settings: Settings,
    onPanelVisibilityChange: (@MainActor (Bool) -> Void)? = nil
  ) {
    self.store = store
    self.usage = usage
    self.settings = settings
    self.onPanelVisibilityChange = onPanelVisibilityChange
    L10n.preference = settings.language
    super.init()

    setupStatusItem()
    setupPopover()
    startObserving()
  }

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.target = self
      button.action = #selector(handleButtonClick(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    self.statusItem = item
  }

  private func setupPopover() {
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    popover.contentSize = NSSize(width: 560, height: 480)
  }

  private func startObserving() {
    guard !isStopped else { return }

    withObservationTracking {
      let iconModel = StatusIconModel(
        quotas: store.quotas,
        waitingSessions: store.waiting
      )
      updateIcon(model: iconModel)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.isStopped else { return }
        self.startObserving()
      }
    }
  }

  private func updateIcon(model: StatusIconModel) {
    guard let button = statusItem?.button else { return }
    let icon = StatusIconRenderer.image(for: model)
    button.image = icon
  }

  @objc private func handleButtonClick(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else {
      togglePopover(sender)
      return
    }

    let isRightClick =
      event.type == .rightMouseUp
      || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

    if isRightClick {
      showContextMenu(for: sender)
    } else {
      togglePopover(sender)
    }
  }

  private func togglePopover(_ button: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      L10n.preference = settings.language
      let panel = PanelView(
        store: store,
        usage: usage,
        onJump: { session in
          TerminalJumper.jump(to: session)
        },
        onClose: { [weak self] in
          self?.popover.performClose(nil)
        },
        onOpenSettings: { [weak self] in
          self?.popover.performClose(nil)
          self?.openSettings()
        }
      )
      let hostingController = NSHostingController(rootView: panel)
      hostingController.preferredContentSize = NSSize(width: 560, height: 480)
      popover.contentViewController = hostingController
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
      notifyPanelVisibility(true)
    }
  }

  private func showContextMenu(for button: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(nil)
    }

    let menu = NSMenu()

    let settingsItem = NSMenuItem(
      title: "Settings…",
      action: #selector(openSettings),
      keyEquivalent: ","
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

    let copyHooksItem = NSMenuItem(
      title: "Copy hooks snippet",
      action: #selector(copyHooksSnippet),
      keyEquivalent: ""
    )
    copyHooksItem.target = self
    menu.addItem(copyHooksItem)

    menu.addItem(.separator())

    let aboutItem = NSMenuItem(
      title: "About",
      action: #selector(showAbout),
      keyEquivalent: ""
    )
    aboutItem.target = self
    menu.addItem(aboutItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quit",
      action: #selector(quitApp),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)

    button.isHighlighted = true
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    button.isHighlighted = false
  }

  @objc private func openSettings() {
    SettingsWindowController.shared.show(settings: settings)
  }

  @objc private func copyHooksSnippet() {
    let executable = HutchbarApp.currentExecutablePath()
    let snippet = generateHooksConfiguration(binaryPath: executable)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(snippet, forType: .string)
  }

  @objc private func showAbout() {
    NSApp.orderFrontStandardAboutPanel(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  // MARK: - NSPopoverDelegate

  func popoverDidClose(_ notification: Notification) {
    popover.contentViewController = nil
    notifyPanelVisibility(false)
  }

  private func notifyPanelVisibility(_ visible: Bool) {
    onPanelVisibilityChange?(visible)
    Self.onPanelVisibilityChange?(visible)
  }

  public func stop() {
    guard !isStopped else { return }
    isStopped = true

    if popover.isShown {
      popover.performClose(nil)
      notifyPanelVisibility(false)
    }
    popover.contentViewController = nil

    if let statusItem {
      statusItem.button?.target = nil
      statusItem.button?.action = nil
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    self.statusItem = nil
  }
}
