// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

@Suite("LocalAgentProcessRunnerTests")
struct LocalAgentProcessRunnerTests {
  @Test func localAgentProcessRunner_catEchoAndClose() async throws {
    let runner = LocalAgentProcessRunner()
    let spec = AgentProcessSpec(
      executable: "/bin/cat",
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: 5.0
    )

    let session = try await runner.start(spec)

    try await session.send("first message")
    let line1 = try await session.nextLine()
    #expect(line1 == "first message")

    try await session.send("second message")
    let line2 = try await session.nextLine()
    #expect(line2 == "second message")

    await session.close()
  }

  @Test func localAgentProcessRunner_sleepTimesOut() async throws {
    let runner = LocalAgentProcessRunner()
    let spec = AgentProcessSpec(
      executable: "/bin/sleep",
      arguments: ["10"],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: 0.3
    )

    let session = try await runner.start(spec)

    await #expect(throws: AgentProcessError.timeout) {
      _ = try await session.nextLine()
    }

    await session.close()
  }

  @Test func localAgentProcessRunner_repeatedCloseIsSafe() async throws {
    let runner = LocalAgentProcessRunner()
    let spec = AgentProcessSpec(
      executable: "/bin/cat",
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: 2.0
    )

    let session = try await runner.start(spec)
    await session.close()
    await session.close()

    await #expect(throws: AgentProcessError.closed) {
      try await session.send("should fail")
    }
  }

  @Test func localAgentProcessRunner_oversizedLineTriggersClosedError() async throws {
    let runner = LocalAgentProcessRunner()
    let spec = AgentProcessSpec(
      executable: "/bin/cat",
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: 3.0
    )

    let session = try await runner.start(spec)
    let giantLine = String(repeating: "a", count: 1024 * 1024 + 10)
    try await session.send(giantLine)

    await #expect(throws: AgentProcessError.closed) {
      _ = try await session.nextLine()
    }

    await session.close()
  }
}
