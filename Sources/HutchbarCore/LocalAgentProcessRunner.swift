// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Runs agent CLI processes locally using Foundation.Process and pipes.
public struct LocalAgentProcessRunner: AgentProcessRunner, Sendable {
  public init() {}

  public func start(_ spec: AgentProcessSpec) async throws -> any AgentProcessSession {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: spec.executable)
    process.arguments = spec.arguments
    process.environment = spec.environment

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice
    // A write after the child exited must fail with EPIPE, not kill the app with SIGPIPE.
    _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    do {
      try process.run()
    } catch {
      throw AgentProcessError.launchFailed
    }

    return LocalAgentProcessSession(
      process: process,
      stdinPipe: stdinPipe,
      stdoutPipe: stdoutPipe,
      timeout: spec.timeout
    )
  }
}

actor LocalAgentProcessSession: AgentProcessSession {
  private let process: Process
  private let stdinPipe: Pipe
  private let stdoutPipe: Pipe
  private let deadline: ContinuousClock.Instant
  private let maxLineBytes = 1024 * 1024

  private var isClosed = false
  private var isStdoutClosed = false
  private var terminalError: AgentProcessError?
  private var buffer = Data()
  private var queuedLines: [String] = []
  private var waitingContinuation: CheckedContinuation<String?, any Error>?
  private var timeoutTask: Task<Void, Never>?
  private var streamContinuation: AsyncStream<Data>.Continuation?

  init(
    process: Process,
    stdinPipe: Pipe,
    stdoutPipe: Pipe,
    timeout: TimeInterval
  ) {
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    let effectiveTimeout = timeout > 0 ? timeout : 0
    self.deadline = ContinuousClock.now + .seconds(effectiveTimeout)

    let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    self.streamContinuation = continuation

    let readingHandle = stdoutPipe.fileHandleForReading
    readingHandle.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        readingHandle.readabilityHandler = nil
        continuation.finish()
      } else {
        continuation.yield(chunk)
      }
    }

    Task { [weak self] in
      for await chunk in stream {
        guard let self else { break }
        await self.appendChunk(chunk)
      }
      await self?.finishStdout()
    }
  }

  deinit {
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    if process.isRunning {
      process.terminate()
    }
  }

  public func send(_ line: String) async throws {
    guard !isClosed, terminalError == nil else {
      throw AgentProcessError.closed
    }
    let payload = Data((line + "\n").utf8)
    do {
      try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
    } catch {
      throw AgentProcessError.closed
    }
  }

  public func nextLine() async throws -> String? {
    if isClosed { throw AgentProcessError.closed }
    if let terminalError { throw terminalError }

    let now = ContinuousClock.now
    if now >= deadline {
      throw AgentProcessError.timeout
    }

    if !queuedLines.isEmpty {
      return queuedLines.removeFirst()
    }

    if isStdoutClosed {
      return nil
    }

    let remainingDuration = deadline - now
    return try await withCheckedThrowingContinuation { continuation in
      self.waitingContinuation = continuation
      self.timeoutTask = Task { [weak self] in
        do {
          try await Task.sleep(for: remainingDuration)
          await self?.handleTimeout()
        } catch {
          // Sleep was cancelled when line arrived or session closed.
        }
      }
    }
  }

  public func close() async {
    guard !isClosed else { return }
    isClosed = true

    timeoutTask?.cancel()
    timeoutTask = nil

    if let continuation = waitingContinuation {
      waitingContinuation = nil
      continuation.resume(throwing: AgentProcessError.closed)
    }

    streamContinuation?.finish()
    streamContinuation = nil

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    try? stdinPipe.fileHandleForWriting.close()
    try? stdoutPipe.fileHandleForReading.close()

    if process.isRunning {
      let processId = process.processIdentifier
      process.terminate()
      Task { [process] in
        try? await Task.sleep(for: .seconds(1))
        if process.isRunning, processId > 0 {
          kill(processId, SIGKILL)
        }
      }
    }
  }

  private func appendChunk(_ chunk: Data) {
    guard !isClosed, terminalError == nil else { return }
    buffer.append(chunk)

    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      let lineData = buffer.prefix(upTo: newlineIndex)
      buffer.removeSubrange(...newlineIndex)

      if lineData.count > maxLineBytes {
        failWithClosed()
        return
      }

      let line = String(decoding: lineData, as: UTF8.self)
      deliverLine(line)
    }

    if buffer.count > maxLineBytes {
      failWithClosed()
    }
  }

  private func deliverLine(_ line: String) {
    if let continuation = waitingContinuation {
      waitingContinuation = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      continuation.resume(returning: line)
    } else {
      queuedLines.append(line)
    }
  }

  private func finishStdout() {
    isStdoutClosed = true
    guard terminalError == nil else { return }

    if !buffer.isEmpty {
      if buffer.count > maxLineBytes {
        failWithClosed()
        return
      }
      let trailingLine = String(decoding: buffer, as: UTF8.self)
      buffer.removeAll()
      deliverLine(trailingLine)
    }

    if let continuation = waitingContinuation {
      waitingContinuation = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      continuation.resume(returning: nil)
    }
  }

  private func handleTimeout() {
    guard let continuation = waitingContinuation else { return }
    waitingContinuation = nil
    timeoutTask = nil
    continuation.resume(throwing: AgentProcessError.timeout)
  }

  private func failWithClosed() {
    terminalError = .closed
    if let continuation = waitingContinuation {
      waitingContinuation = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      continuation.resume(throwing: AgentProcessError.closed)
    }
  }
}
