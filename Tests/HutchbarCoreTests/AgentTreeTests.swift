// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let treeTestBaseDate = Date(timeIntervalSince1970: 1_794_000_000)

@MainActor
@Test func agentTree_childSubagentNotInWaitingEvenIfWaiting() throws {
  let store = SessionStore()
  let parent = SessionSnapshot(
    id: "parent-session-1",
    agent: .claudeCode,
    state: .running,
    projectName: "main-project",
    lastActivity: treeTestBaseDate
  )
  let subagent = SessionSnapshot(
    id: "subagent-session-1",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "main-project",
    lastActivity: treeTestBaseDate,
    waitingSince: treeTestBaseDate,
    parentKey: parent.sessionKey,
    childKind: .subagent
  )

  store.apply(.session(parent), now: treeTestBaseDate)
  store.apply(.session(subagent), now: treeTestBaseDate)

  // Subagent must not be in waiting, quiet, or waitingCount
  #expect(store.waiting(now: treeTestBaseDate).isEmpty)
  #expect(store.waitingCount(now: treeTestBaseDate) == 0)
  #expect(store.quiet(now: treeTestBaseDate).isEmpty)

  // In agent tree: parent is in working, subagent is in parent's children
  let tree = store.agentTree(now: treeTestBaseDate)
  #expect(tree.waiting.isEmpty)
  #expect(tree.quiet.isEmpty)
  #expect(tree.working.count == 1)

  let rootNode = try #require(tree.working.first)
  #expect(rootNode.session?.id == "parent-session-1")
  #expect(rootNode.children.count == 1)

  let childNode = try #require(rootNode.children.first)
  #expect(childNode.session?.id == "subagent-session-1")
}

@MainActor
@Test func agentTree_parentByChildMovesCodexUnderClaude() throws {
  let store = SessionStore()
  let claude = SessionSnapshot(
    id: "claude-proc-parent",
    agent: .claudeCode,
    state: .running,
    projectName: "shared-app",
    lastActivity: treeTestBaseDate
  )
  let codex = SessionSnapshot(
    id: "codex-proc-child",
    agent: .codex,
    state: .running,
    projectName: "shared-app",
    lastActivity: treeTestBaseDate
  )

  store.apply(.session(claude), now: treeTestBaseDate)
  store.apply(.session(codex), now: treeTestBaseDate)

  // Before nesting: both are roots in working
  let treeBefore = store.agentTree(now: treeTestBaseDate)
  #expect(treeBefore.working.count == 2)

  // Apply nesting linking codex to claude
  let nestingResult = ProcessNestingResult(
    parentByChild: [codex.sessionKey: claude.sessionKey],
    ephemeral: []
  )
  store.applyNesting(nestingResult)

  // After nesting: codex is moved under claude
  let treeAfter = store.agentTree(now: treeTestBaseDate)
  #expect(treeAfter.working.count == 1)

  let root = try #require(treeAfter.working.first)
  #expect(root.session?.id == "claude-proc-parent")
  #expect(root.children.count == 1)
  #expect(root.children.first?.session?.id == "codex-proc-child")

  // When nesting is cleared, codex returns to parentKey from snapshot (nil)
  store.applyNesting(ProcessNestingResult(parentByChild: [:], ephemeral: []))
  let treeRestored = store.agentTree(now: treeTestBaseDate)
  #expect(treeRestored.working.count == 2)
}

@MainActor
@Test func agentTree_ephemeralChildAttachesToParent() throws {
  let store = SessionStore()
  let claude = SessionSnapshot(
    id: "claude-host",
    agent: .claudeCode,
    state: .running,
    projectName: "flash-tool",
    lastActivity: treeTestBaseDate
  )
  store.apply(.session(claude), now: treeTestBaseDate)

  let ephemeral = EphemeralChild(
    id: "proc:5001",
    parentKey: claude.sessionKey,
    executableName: "agy",
    displayName: "Flash (agy)",
    startedAt: treeTestBaseDate.addingTimeInterval(15)
  )
  let nesting = ProcessNestingResult(
    parentByChild: [:],
    ephemeral: [ephemeral]
  )
  store.applyNesting(nesting)

  let tree = store.agentTree(now: treeTestBaseDate)
  #expect(tree.working.count == 1)

  let root = try #require(tree.working.first)
  #expect(root.session?.id == "claude-host")
  #expect(root.children.count == 1)

  let childNode = try #require(root.children.first)
  #expect(childNode.session == nil)
  #expect(childNode.ephemeral?.id == "proc:5001")
  #expect(childNode.ephemeral?.displayName == "Flash (agy)")
}

@MainActor
@Test func agentTree_finishedChildDisappearsAfterTenMinutes() throws {
  let store = SessionStore()
  let parent = SessionSnapshot(
    id: "parent-root",
    agent: .claudeCode,
    state: .running,
    projectName: "project",
    lastActivity: treeTestBaseDate
  )
  let child = SessionSnapshot(
    id: "child-finished",
    agent: .claudeCode,
    state: .finished,
    projectName: "project",
    lastActivity: treeTestBaseDate,
    parentKey: parent.sessionKey
  )

  store.apply(.session(parent), now: treeTestBaseDate)
  store.apply(.session(child), now: treeTestBaseDate)

  // At 5 minutes: child is visible under parent
  let treeAt5m = store.agentTree(now: treeTestBaseDate.addingTimeInterval(5 * 60))
  let rootAt5m = try #require(treeAt5m.working.first)
  #expect(rootAt5m.children.count == 1)
  #expect(rootAt5m.children.first?.session?.id == "child-finished")

  // At exactly 10 minutes (600 s): child is still visible
  let treeAt10m = store.agentTree(now: treeTestBaseDate.addingTimeInterval(10 * 60))
  let rootAt10m = try #require(treeAt10m.working.first)
  #expect(rootAt10m.children.count == 1)

  // At 10 minutes and 1 second: child disappears from tree
  let treeAt10m1s = store.agentTree(now: treeTestBaseDate.addingTimeInterval(10 * 60 + 1))
  let rootAt10m1s = try #require(treeAt10m1s.working.first)
  #expect(rootAt10m1s.children.isEmpty)
}

@MainActor
@Test func agentTree_quietParentKeepsChildrenUnderQuiet() throws {
  let store = SessionStore(quietAfter: 3600)
  let quietSince = treeTestBaseDate.addingTimeInterval(-70 * 60)
  let parent = SessionSnapshot(
    id: "quiet-parent",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "quiet-proj",
    lastActivity: quietSince,
    waitingSince: quietSince
  )
  let child = SessionSnapshot(
    id: "active-child",
    agent: .claudeCode,
    state: .running,
    projectName: "quiet-proj",
    lastActivity: treeTestBaseDate,
    parentKey: parent.sessionKey
  )

  store.apply(.session(parent), now: treeTestBaseDate)
  store.apply(.session(child), now: treeTestBaseDate)

  #expect(store.waiting(now: treeTestBaseDate).isEmpty)
  #expect(store.quiet(now: treeTestBaseDate).map(\.id) == ["quiet-parent"])

  let tree = store.agentTree(now: treeTestBaseDate)
  #expect(tree.waiting.isEmpty)
  #expect(tree.working.isEmpty)
  #expect(tree.quiet.count == 1)

  let quietRoot = try #require(tree.quiet.first)
  #expect(quietRoot.session?.id == "quiet-parent")
  #expect(quietRoot.children.count == 1)
  #expect(quietRoot.children.first?.session?.id == "active-child")
}

@MainActor
@Test func agentTree_parentCycleDoesNotInfiniteLoop() throws {
  let store = SessionStore()
  let sessionA = SessionSnapshot(
    id: "cycle-sess-a",
    agent: .claudeCode,
    state: .running,
    projectName: "loop-project",
    lastActivity: treeTestBaseDate,
    parentKey: SessionKey(agent: .codex, id: "cycle-sess-b")
  )
  let sessionB = SessionSnapshot(
    id: "cycle-sess-b",
    agent: .codex,
    state: .running,
    projectName: "loop-project",
    lastActivity: treeTestBaseDate,
    parentKey: SessionKey(agent: .claudeCode, id: "cycle-sess-a")
  )

  store.apply(.session(sessionA), now: treeTestBaseDate)
  store.apply(.session(sessionB), now: treeTestBaseDate)

  // Mutual parent cycle: terminates safely without crashing
  let directTree = store.agentTree(now: treeTestBaseDate)
  #expect(directTree.working.isEmpty)

  // Legitimate root with circular descendant nesting
  let root = SessionSnapshot(
    id: "legit-root",
    agent: .claudeCode,
    state: .running,
    projectName: "loop-project",
    lastActivity: treeTestBaseDate
  )
  let childOne = SessionSnapshot(
    id: "descendant-1",
    agent: .codex,
    state: .running,
    projectName: "loop-project",
    lastActivity: treeTestBaseDate,
    parentKey: root.sessionKey
  )
  let childTwo = SessionSnapshot(
    id: "descendant-2",
    agent: .codex,
    state: .running,
    projectName: "loop-project",
    lastActivity: treeTestBaseDate,
    parentKey: childOne.sessionKey
  )

  store.apply(.session(root), now: treeTestBaseDate)
  store.apply(.session(childOne), now: treeTestBaseDate)
  store.apply(.session(childTwo), now: treeTestBaseDate)

  // Introduce cycle between childOne and childTwo via parentByChild override
  store.applyNesting(
    ProcessNestingResult(
      parentByChild: [childOne.sessionKey: childTwo.sessionKey],
      ephemeral: []
    )
  )

  let cyclicTree = store.agentTree(now: treeTestBaseDate)
  #expect(cyclicTree.working.count == 1)
  let rootNode = try #require(cyclicTree.working.first)
  #expect(rootNode.session?.id == "legit-root")
}
