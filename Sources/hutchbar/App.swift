// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Foundation
import HutchbarCore
import MachO

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var appController: AppController?
  private var menuBarController: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let settings = Settings()
    let controller = AppController(settings: settings)
    let menuBar = MenuBarController(
      store: controller.store,
      settings: settings
    )
    self.appController = controller
    self.menuBarController = menuBar
  }

  func applicationWillTerminate(_ notification: Notification) {
    menuBarController?.stop()
    menuBarController = nil
    appController?.stop()
    appController = nil
  }
}

@main
struct HutchbarApp {
  @MainActor static func main() {
    let arguments = CommandLine.arguments.dropFirst()
    if arguments.contains("--version") {
      print(HutchbarVersion.current)
      return
    }
    if arguments.contains("--hook") {
      runHook()
      exit(0)
    }
    if arguments.contains("--print-hooks") {
      let executable = currentExecutablePath()
      print(generateHooksConfiguration(binaryPath: executable))
      return
    }
    if let index = arguments.firstIndex(of: "--render-panel"),
      arguments.index(after: index) < arguments.endIndex
    {
      let path = arguments[arguments.index(after: index)]
      Task { @MainActor in
        exit(await PanelRenderer.render(to: path) ? 0 : 1)
      }
      RunLoop.main.run()
    }
    if arguments.contains("--selftest") {
      // Touch core models and the real filesystem adapter without starting AppKit.
      do {
        guard SessionState.allCases.count == 4,
          SessionState(rawValue: "waitingForApproval") == .waitingForApproval
        else { exit(1) }
        let reader = try JSONLTailReader(path: "/dev/null")
        reader.stop()
        print("hutchbar core selftest passed (\(HutchbarVersion.current))")
        return
      } catch {
        fputs("hutchbar core selftest failed\n", stderr)
        exit(1)
      }
    }
    guard arguments.isEmpty else {
      fputs("Usage: hutchbar [--hook | --print-hooks | --selftest | --version]\n", stderr)
      exit(64)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }

  private static func runHook() {
    let maxBytes = 65_536
    var stdinData = Data()
    let handle = FileHandle.standardInput
    while stdinData.count <= maxBytes {
      let chunk = handle.readData(ofLength: 4096)
      if chunk.isEmpty { break }
      stdinData.append(chunk)
    }
    guard stdinData.count <= maxBytes,
      let event = makeHookEvent(stdin: stdinData, now: Date())
    else {
      return
    }
    _ = HookEventWriter.write(event: event, to: HookEventWriter.defaultEventsPath)
  }

  static func currentExecutablePath() -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    var size = UInt32(buffer.count)
    if _NSGetExecutablePath(&buffer, &size) == 0 {
      var realBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      if realpath(buffer, &realBuffer) != nil {
        let resolved = realBuffer.withUnsafeBufferPointer { ptr in
          ptr.baseAddress.map(String.init(cString:)) ?? ""
        }
        if !resolved.isEmpty { return resolved }
      }
      let fallback = buffer.withUnsafeBufferPointer { ptr in
        ptr.baseAddress.map(String.init(cString:)) ?? ""
      }
      if !fallback.isEmpty { return fallback }
    }
    if let bundlePath = Bundle.main.executablePath, !bundlePath.isEmpty {
      return bundlePath
    }
    let arg0 = CommandLine.arguments.first ?? "hutchbar"
    return URL(fileURLWithPath: arg0).standardized.path
  }
}
