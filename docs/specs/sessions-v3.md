# Sessions v3: quiet sessions, dead processes, nesting

Decisions (2026-11-08): the agents block answers "who waits for me" and "who works, and who called whom". A session left open for a day must not count as waiting; a closed process must disappear at once; a child call (Claude → Codex in a terminal, Claude/Codex subagents, Claude → `agy` Flash) is shown under its parent and never asks for attention itself. Mock-up: `mac-projects-plan/mockup/panel-v3.html` (blocks 1 and 2).

## 1. Quiet sessions

- A session in `waitingForInput` or `waitingForApproval` whose `waitingSince` is older than `quietAfter` is **quiet**. Default 60 min; setting «Молчащие сессии через» 15 / 30 / 60 / 120 min / never (`hutchbar.quietAfterMinutes`, 0 = never).
- Quiet sessions are not in `waiting`, not in `waitingCount`, never trigger the attention pill or the menu bar counter. `SessionStore.quiet` lists them (oldest activity last); the panel shows one collapsed line «Ещё N молчат дольше часа — показать».
- Any new activity (hook event, transcript record, live status `busy`) makes the session non-quiet again (its `waitingSince` restarts when it next waits).

## 2. Exited processes

- Claude Code: the live registry (`~/.claude/sessions/<pid>.json`) already reports `finished` when the pid is gone; keep it.
- Codex: every 10 s the coordinator checks non-finished Codex sessions that have a `cwd`: if no process named `codex` with the same resolved `cwd` exists for two consecutive checks, the session becomes `finished`. Uses the existing `ProcessTable` (no shelling out).
- A Claude session without a registry entry and a Codex session without `cwd` keep the old rule (no record for 30 min → finished).

## 3. Nesting

`SessionSnapshot.parentKey: SessionKey?` and `SessionSnapshot.childKind: ChildKind?` (`subagent`, `process`). A session with a parent is a **child**: never in `waiting`/`quiet`/`waitingCount`, shown indented under the parent while it runs and for 10 min after it ends.

Sources of nesting:
1. **Claude subagents**: transcripts `~/.claude/projects/<dir>/<session-id>/subagents/*.jsonl`. Parent = `<session-id>`. A subagent file modified in the last 2 min is running, otherwise done. Title: the subagent's description if the first record has one (`message.content` is never read; only explicit metadata fields such as `agentType`/`description` if present), else «сабагент». Records inside the parent file with `isSidechain: true` keep updating only `lastActivity`.
2. **Codex subagents**: `session_meta.payload.source.subagent` (or `source.internal`) marks a child; parent = the session whose id equals `payload.parent_thread_id` (or `payload.session_id` when it differs from `payload.id`).
3. **Process tree**: an agent process (`claude`, `codex`, `agy`, `gemini`, `qwen`, `opencode`, `cursor-agent`, `copilot`, `amp`, `droid`, `aider`) whose ancestor chain contains the pid of a tracked session is a child of that session. If the child is itself a tracked session (e.g. a Codex session started by Claude), that session gets the parent; otherwise an **ephemeral child** row is made from the process alone: name (`agy` → «Flash (agy)», others by executable name), elapsed time since process start, state running; it disappears with the process.

## 4. Panel

«Ждут тебя» (approval first, then your turn) → «Работают» (tree: children indented under parents) → collapsed quiet line. Child rows: agent mark, title, «работает» / «готово», elapsed; no jump target of their own (clicking jumps to the parent's window).
