// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Foundation

/// Lightweight representation of a process from the system process table.
public struct ProcessInfoLite: Sendable, Equatable {
  public let pid: pid_t
  public let ppid: pid_t
  public let executableName: String
  public let cwd: String?
  public let tty: String?
  public let startTime: Date

  public init(
    pid: pid_t,
    ppid: pid_t,
    executableName: String,
    cwd: String? = nil,
    tty: String? = nil,
    startTime: Date = Date()
  ) {
    self.pid = pid
    self.ppid = ppid
    self.executableName = executableName
    self.cwd = cwd
    self.tty = tty
    self.startTime = startTime
  }
}

/// Abstract process table interface to allow test doubles.
public protocol ProcessTable: Sendable {
  func allProcesses() -> [ProcessInfoLite]
}

/// Host terminal or IDE application containing the agent process.
public struct HostApp: Sendable, Equatable {
  public let bundleId: String
  public let name: String

  public init(bundleId: String, name: String) {
    self.bundleId = bundleId
    self.name = name
  }
}

/// Discovered location and metadata for an agent process.
public struct AgentLocation: Sendable, Equatable {
  public let pid: pid_t
  public let tty: String?
  public let hostBundleId: String?
  public let hostName: String?
  public let hostPid: pid_t?

  public init(
    pid: pid_t,
    tty: String? = nil,
    hostBundleId: String? = nil,
    hostName: String? = nil,
    hostPid: pid_t? = nil
  ) {
    self.pid = pid
    self.tty = tty
    self.hostBundleId = hostBundleId
    self.hostName = hostName
    self.hostPid = hostPid
  }
}

/// Validates terminal device names against dangerous characters to prevent script injection.
public enum TTYValidator {
  private static let pattern: String = "^/dev/ttys[0-9]{3,4}\\z"
  private static let regex: NSRegularExpression? = {
    try? NSRegularExpression(pattern: pattern)
  }()

  public static func isValid(_ tty: String) -> Bool {
    guard !tty.contains("\n"), !tty.contains("\r"), let regex else { return false }
    let range = NSRange(tty.startIndex..<tty.endIndex, in: tty)
    guard let match = regex.firstMatch(in: tty, options: [], range: range) else { return false }
    return match.range.location == 0 && match.range.length == range.length
  }
}

/// Real Darwin process table reader implemented via libproc and devname.
public struct DarwinProcessTable: ProcessTable, Sendable {
  public init() {}

  public func allProcesses() -> [ProcessInfoLite] {
    var count = proc_listallpids(nil, 0)
    if count <= 0 { count = 1024 }
    var pids = [pid_t](repeating: 0, count: Int(count) + 256)
    let bytesRead = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
    guard bytesRead > 0 else { return [] }
    let actualCount = Int(bytesRead) / MemoryLayout<pid_t>.stride

    var processes: [ProcessInfoLite] = []
    processes.reserveCapacity(actualCount)

    for index in 0..<actualCount {
      let pid = pids[index]
      guard pid > 0 else { continue }

      var bsdInfo = proc_bsdinfo()
      let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
      let bsdResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize)
      guard bsdResult == bsdSize else { continue }

      var pathBuffer = [CChar](repeating: 0, count: 4096)
      let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
      let executableName: String
      if pathLen > 0 {
        let fullPath = pathBuffer.withUnsafeBufferPointer { ptr in
          ptr.baseAddress.map(String.init(cString:)) ?? ""
        }
        executableName = URL(fileURLWithPath: fullPath).lastPathComponent
      } else {
        executableName = withUnsafePointer(to: &bsdInfo.pbi_name) { ptr in
          ptr.withMemoryRebound(to: CChar.self, capacity: 32) { cStr in
            String(cString: cStr)
          }
        }
      }
      guard !executableName.isEmpty else { continue }

      var vnodeInfo = proc_vnodepathinfo()
      let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
      let vnodeResult = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, vnodeSize)

      let cwd: String? = {
        guard vnodeResult == vnodeSize else { return nil }
        return withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr in
          ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
            guard cStr.pointee != 0 else { return nil }
            return String(cString: cStr)
          }
        }
      }()

      let tty: String? = {
        let dev = bsdInfo.e_tdev
        guard dev != 0, dev != UInt32(bitPattern: -1) else { return nil }
        guard let namePtr = devname(dev_t(bitPattern: dev), mode_t(S_IFCHR)) else { return nil }
        let devName = String(cString: namePtr)
        guard !devName.isEmpty, devName != "??" else { return nil }
        return devName.hasPrefix("/") ? devName : "/dev/\(devName)"
      }()

      let startTime = Date(
        timeIntervalSince1970: Double(bsdInfo.pbi_start_tvsec)
          + Double(bsdInfo.pbi_start_tvusec) / 1_000_000.0
      )

      processes.append(
        ProcessInfoLite(
          pid: pid,
          ppid: pid_t(bsdInfo.pbi_ppid),
          executableName: executableName,
          cwd: cwd,
          tty: tty,
          startTime: startTime
        )
      )
    }

    return processes
  }
}

public func defaultResolveApp(pid: pid_t) -> HostApp? {
  guard let app = NSRunningApplication(processIdentifier: pid),
    let bundleId = app.bundleIdentifier,
    !bundleId.isEmpty
  else {
    return nil
  }
  let name = app.localizedName ?? bundleId
  return HostApp(bundleId: bundleId, name: name)
}

/// Matches an agent session to its running process and host terminal.
public struct AgentLocator: Sendable {
  public init() {}

  public static func isValidTTY(_ tty: String) -> Bool {
    TTYValidator.isValid(tty)
  }

  public static func canonicalizePath(_ path: String) -> String {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    if realpath(path, &resolved) != nil {
      var str = resolved.withUnsafeBufferPointer { ptr in
        ptr.baseAddress.map(String.init(cString:)) ?? ""
      }
      while str.count > 1 && str.hasSuffix("/") {
        str.removeLast()
      }
      return str
    }
    var standardized = URL(fileURLWithPath: path).standardized.path
    while standardized.count > 1 && standardized.hasSuffix("/") {
      standardized.removeLast()
    }
    return standardized
  }

  public static func isAgentProcess(executableName: String, agent: AgentKind) -> Bool {
    let base = URL(fileURLWithPath: executableName).lastPathComponent
    switch agent {
    case .claudeCode:
      return base == "claude"
    case .codex:
      return base == "codex"
    }
  }

  public static func locate(
    session: SessionSnapshot,
    table: ProcessTable = DarwinProcessTable(),
    resolveApp: (pid_t) -> HostApp? = defaultResolveApp
  ) -> AgentLocation? {
    guard let sessionCwd = session.cwd, !sessionCwd.isEmpty else {
      return nil
    }

    let targetPath = canonicalizePath(sessionCwd)
    let processes = table.allProcesses()

    let matching = processes.filter { proc in
      guard isAgentProcess(executableName: proc.executableName, agent: session.agent) else {
        return false
      }
      guard let procCwd = proc.cwd, !procCwd.isEmpty else {
        return false
      }
      return canonicalizePath(procCwd) == targetPath
    }

    guard
      let chosen = matching.max(by: { lhs, rhs in
        if lhs.startTime != rhs.startTime {
          return lhs.startTime < rhs.startTime
        }
        return lhs.pid < rhs.pid
      })
    else {
      return nil
    }

    var processMap: [pid_t: ProcessInfoLite] = [:]
    processMap.reserveCapacity(processes.count)
    for proc in processes {
      processMap[proc.pid] = proc
    }

    var currentPid = chosen.ppid
    var visited: Set<pid_t> = [chosen.pid]
    var resolvedHost: HostApp?
    var resolvedHostPid: pid_t?

    while currentPid > 1 && !visited.contains(currentPid) {
      visited.insert(currentPid)
      if let app = resolveApp(currentPid) {
        resolvedHost = app
        resolvedHostPid = currentPid
        break
      }
      guard let parent = processMap[currentPid] else { break }
      currentPid = parent.ppid
    }

    return AgentLocation(
      pid: chosen.pid,
      tty: chosen.tty,
      hostBundleId: resolvedHost?.bundleId,
      hostName: resolvedHost?.name,
      hostPid: resolvedHostPid
    )
  }

  public func locate(
    session: SessionSnapshot,
    table: ProcessTable = DarwinProcessTable(),
    resolveApp: (pid_t) -> HostApp? = defaultResolveApp
  ) -> AgentLocation? {
    Self.locate(session: session, table: table, resolveApp: resolveApp)
  }
}

/// In-memory cache for agent locations with configurable TTL and clock.
public final class AgentLocationCache: @unchecked Sendable {
  public static let defaultTTL: TimeInterval = 10.0

  private let ttl: TimeInterval
  private let clock: @Sendable () -> Date
  private let lock = NSLock()
  private var storage: [String: CacheEntry] = [:]

  private struct CacheEntry {
    let location: AgentLocation
    let cachedAt: Date
  }

  public init(
    ttl: TimeInterval = defaultTTL,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.ttl = ttl
    self.clock = clock
  }

  public func location(for sessionId: String) -> AgentLocation? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = storage[sessionId] else { return nil }
    let now = clock()
    if now.timeIntervalSince(entry.cachedAt) < ttl {
      return entry.location
    }
    storage.removeValue(forKey: sessionId)
    return nil
  }

  public func setLocation(_ location: AgentLocation, for sessionId: String) {
    lock.lock()
    defer { lock.unlock() }
    storage[sessionId] = CacheEntry(location: location, cachedAt: clock())
  }

  public func invalidate(sessionId: String) {
    lock.lock()
    defer { lock.unlock() }
    storage.removeValue(forKey: sessionId)
  }

  public func invalidateAll() {
    lock.lock()
    defer { lock.unlock() }
    storage.removeAll()
  }
}
