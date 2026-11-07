// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import HutchbarCore

/// Result of attempting to switch to an agent's terminal or window.
public enum JumpResult: Sendable, Equatable {
  case activated
  case selectedTab
  case notFound
  case scriptingDenied
}

/// Brings the terminal or window hosting an agent session to the front.
@MainActor
enum TerminalJumper {
  private static let locationCache = AgentLocationCache()

  /// Optional hook to look up live process ID for a session.
  public static var pidLookup: ((SessionSnapshot) -> Int?)?

  private static let terminalBundleId = "com.apple.Terminal"
  private static let itermBundleId = "com.googlecode.iterm2"

  private static let terminalScriptTemplate = """
    tell application id "com.apple.Terminal"
      activate
      set targetTTY to "%TTY%"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is targetTTY then
            set selected of t to true
            set index of w to 1
            return true
          end if
        end repeat
      end repeat
      return false
    end tell
    """

  private static let itermScriptTemplate = """
    tell application id "com.googlecode.iterm2"
      activate
      set targetTTY to "%TTY%"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if tty of s is targetTTY then
              select s
              select t
              return true
            end if
          end repeat
        end repeat
      end repeat
      return false
    end tell
    """

  /// Returns the display name of the host application running this session (e.g. "Warp", "Terminal").
  public static func hostName(for session: SessionSnapshot, pid: Int? = nil) -> String? {
    if let cached = locationCache.location(for: session.id) {
      return cached.hostName
    }
    let effectivePid = pid ?? pidLookup?(session)
    guard let location = AgentLocator.locate(session: session, pid: effectivePid) else {
      return nil
    }
    locationCache.setLocation(location, for: session.id)
    return location.hostName
  }

  /// Locates the session's host process and switches focus or selects the matching tab.
  @discardableResult
  public static func jump(to session: SessionSnapshot, pid: Int? = nil) -> JumpResult {
    let location: AgentLocation
    if let cached = locationCache.location(for: session.id) {
      location = cached
    } else {
      let effectivePid = pid ?? pidLookup?(session)
      if let found = AgentLocator.locate(session: session, pid: effectivePid) {
        locationCache.setLocation(found, for: session.id)
        location = found
      } else {
        return .notFound
      }
    }

    let bundleId = location.hostBundleId

    if let tty = location.tty,
      AgentLocator.isValidTTY(tty),
      let bundleId,
      (bundleId == terminalBundleId || bundleId == itermBundleId)
    {
      let template =
        (bundleId == terminalBundleId)
        ? terminalScriptTemplate
        : itermScriptTemplate
      let scriptSource = template.replacingOccurrences(of: "%TTY%", with: tty)

      var errorInfo: NSDictionary?
      let script = NSAppleScript(source: scriptSource)
      let resultDescriptor = script?.executeAndReturnError(&errorInfo)

      if let errorInfo {
        let errNum = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        if errNum == -1743 {
          _ = activateApp(location: location)
          return .scriptingDenied
        }
      } else if resultDescriptor?.booleanValue == true {
        return .selectedTab
      }
    }

    if activateApp(location: location) {
      return .activated
    }
    return .notFound
  }

  @discardableResult
  private static func activateApp(location: AgentLocation) -> Bool {
    if let hostPid = location.hostPid,
      let app = NSRunningApplication(processIdentifier: hostPid),
      !app.isTerminated
    {
      app.activate()
      return true
    }
    if let bundleId = location.hostBundleId {
      let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
      if let app = apps.first(where: { !$0.isTerminated }) {
        app.activate()
        return true
      }
    }
    if let app = NSRunningApplication(processIdentifier: location.pid),
      !app.isTerminated
    {
      app.activate()
      return true
    }
    return false
  }
}
