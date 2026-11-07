# Architecture

## Current modules

- **HutchbarCore**: Swift 6 models (`SessionState`, version), JSONL byte framing,
  filesystem/clock protocols, and a POSIX filesystem adapter. No AppKit, UI, networking,
  persistence, external dependencies, or concurrency escape hatches.
- **hutchbar**: MainActor AppKit lifecycle, NSStatusItem with a system symbol, About/Quit.
  `--selftest` loads core models and exercises construction/stop without starting AppKit;
  `--version` prints the source version. It does not open a menu, access logs, or contact a service.
- **HutchbarCoreTests**: standard Swift Testing with fake files/clocks and a small real-file
  adapter test. No XCTest or generated/custom test runner.

Future modules: agent-specific adapters (Claude Code/Codex JSON event schemas), state
store, UI panels/notifications, terminal navigation, subscription sources, and a reviewed
hutch control client. Every process, clock, filesystem, and notification boundary must
be behind an interface; only adapters use platform APIs.

## JSONL reader contract

One serial owner calls `poll()` explicitly; the reader is intentionally not Sendable.
There is no timer, queue, task, observer, or watcher to keep alive. Each poll securely
opens a regular file, obtains device/inode/size from that descriptor, reads at the saved
byte offset, and closes the descriptor even on error. It follows append-only streams from
the beginning. `maximumReadBytes` defaults to 64 KiB per poll. Scheduling/backoff is a
future adapter responsibility; do not busy-poll from the main thread.

Lines are LF-delimited bytes; CR and invalid UTF-8 are preserved. Empty lines are emitted.
JSON validation and schema interpretation are deliberately outside the framer. The 1 MiB
default line limit excludes LF and includes any CR. Exactly-at-limit lines are accepted;
once exceeded, the reader drops the prefix, increments its lifetime counter once, and
ignores bytes until LF. An unfinished last line is retained and never emitted prematurely.
TailBatch reports newly skipped lines plus an injected clock timestamp. Memory is bounded
by a pending line, one read chunk, and records from that chunk (subject to per-record overhead).
Consumers must not retain batches indefinitely. Limits are configurable positive integers;
callers must not raise them based on untrusted log contents.

Device/inode changes or an observed size below the consumed offset reset partial bytes
and oversize discard state. A missing/unreadable file reports a sanitized error and resets
the cursor; recovery may replay records. Truncate-and-regrow past the saved offset between
polls, in-place writes of unchanged size, and same-inode rewrites are not reliably detected
by size/inode checks. A downstream adapter must tolerate replay and prefer rename-based rotation.
The old file's unread tail is abandoned on replacement. `stop()` is final and idempotent,
clears buffered data and cursor, and rejects later polls. Reader release does not require
stop to close a descriptor, but owners should always call it at the end of a session.

The POSIX adapter walks path components using openat, directory descriptors, O_NOFOLLOW,
O_CLOEXEC, and a nonblocking final open. It rejects symlinks at every component, `..`, NUL,
and nonregular files. Callers must supply a physical path (e.g. `/private/tmp`, not macOS's
`/tmp` symlink). Descriptor-relative traversal avoids symlink check/open races. Hard links
and concurrent modification by the same user do not establish trusted provenance.

Errors are fixed TailError cases without paths or payloads. Arbitrary adapter errors are
replaced. Reader, batch, and line descriptions/debug descriptions/custom mirrors expose
counts only. The explicit `JSONLLine.bytes` property is sensitive; never interpolate it
into diagnostics. Swift Testing failures must use synthetic input. No crash telemetry is
collected; local OS crash dumps/process memory can still contain buffered bytes, so this
is not a guarantee of memory secrecy or secure erasure.

## Ownership and cancellation rules

Each descriptor, source, stream, and observer has exactly one documented owner. Use
`[weak self]` in long-lived closures capturing that owner; avoid owner-to-closure cycles.
Every DispatchSource, FSEvents stream, Timer, NotificationCenter observer, and asynchronous
task must have explicit cancellation/invalidation in the owner's stop/close path. Cancellation
must be idempotent and drop callback references; deinit is a fallback, not the lifecycle API.
Close descriptors on every path. UI belongs to MainActor; future I/O belongs to a serial
executor/actor. Do not add `@unchecked Sendable` to silence an ownership problem.

AppDelegate owns the status item; NSApplication's weak delegate is kept alive with
withExtendedLifetime. Termination removes the status item. The reader owns only a bounded
partial buffer and injected dependencies; each short-lived TailFile closes on defer/deinit.
Weak-reference tests prove release after stop; leaks --atExit is a headless core smoke test,
not coverage of future windows/watchers or the interactive AppKit lifecycle. Hardened
processes need get-task-allow for leaks to obtain a task port: --leaks temporarily re-signs
the built app with a generated diagnostic entitlement, runs the exact app selftest, and
restores the original signed bundle on success/failure before any packaging. Production
Resources/hutchbar.entitlements stays empty; the diagnostic entitlement must never ship.
The analyzer has a 45-second timeout and must report zero leaks; denied task ports, timeouts,
and missing analysis all fail. A regular report file avoids inherited-pipe hangs on failed
attachment. The sandbox can deny attachment even with the diagnostic entitlement.
Tools/verify-app.sh rejects any nonempty entitlements or a missing hardened-runtime flag
before distribution; restoration replaces the bundle rather than relying on ditto's
same-size/timestamp overwrite behavior.

## Signing and entitlements

Info.plist sets LSUIElement and macOS 14 minimum. Release and dev bundles have different
identifiers to keep local builds separate. The source version and plist short version must
match; CFBundleVersion is a separate increasing build number.

The entitlements dictionary is empty. We do not claim App Sandbox confinement: future
monitoring needs user-selected agent logs and terminal integration, and the sandbox/TCC
permission design has not been implemented. Hardened runtime is enabled by codesign's
`--options runtime`, not an entitlement. No library-validation bypass, JIT, or sandbox
exception is enabled. Ad-hoc signing provides neither publisher identity nor notarization.
A local self-signed identity can stabilize designated requirements/TCC behavior across
rebuilds, subject to macOS policy; it is not authenticated Developer ID.

## Resource goals and validation

Idle goals for v0.1: below 0.5% CPU and 60 MiB resident memory on a documented reference
Mac; bound queues, log history, and callbacks. These are goals, not hard CI thresholds:
shared runner load and a selftest's short lifetime cannot measure an idle app reliably.
Before v0.1, record idle/sample duration, hardware/OS, memory and CPU with multiple live
synthetic sessions, slow consumers, rapid rotations, and large/malformed inputs. CI checks
behavior, ASan, TSan, and leak freedom; it does not enforce invented performance limits.
