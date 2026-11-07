# UI v0.1

Decision (2026-11-07): the primary UI is a **menu bar item + popover panel + attention pill**. A **notch island** is an optional second view (Settings → Appearance), planned for v0.2. One core (`SessionStore`), several views; views never read files or parse anything.

Why not island-first: the notch space is crowded by agent monitors already (Claude Island / Vibe Notch, CodeIsland, coucou, MioIsland), it does not exist on external monitors or Macs without a notch, and the core idea of hutchbar is the **attention queue**, which a menu bar panel shows just as well.

## Architecture

```
sources (parsers, hook events, quota readers)
        │  value types only (Models.swift)
        ▼
SessionStore  (@MainActor, @Observable) — merged sessions, attention queue, quotas, settings
        │
        ├── MenuBarController (NSStatusItem + icon renderer)
        ├── PanelView (SwiftUI in NSPopover)
        ├── AttentionPill (NSPanel, non-activating, top-center)
        └── NotchView (v0.2, same store)
```

- File watching and polling live in a `SourceCoordinator` actor off the main thread; it publishes snapshots to the store at most 2×/s.
- Every observer, timer, `DispatchSource` and FSEvents stream has an owner and an explicit `stop()`. Closing the panel releases its view tree (lifecycle tests with `weak` references, as for `JSONLTailReader`).

## Menu bar item

- Template icon (monochrome, adapts to light/dark/tinted menu bars).
- Badge: number of sessions waiting for a human (approval + input). Hidden when 0.
- Small ring = highest 5-hour quota usage across accounts; turns orange ≥ 80 %, red ≥ 95 %. Hidden if no quota source.
- Click → panel. Right click → menu: Settings…, Print hooks snippet, Quit.

## Panel (popover, ~340 pt wide)

1. **Waiting for you** — sessions in `waitingForApproval` first, then `waitingForInput`, sorted by `waitingSince` (longest first). Row: state dot, project name, title (if any), agent glyph, waiting time ("4 min"), jump button.
2. **Working** — `running`, sorted by `lastActivity`.
3. **Quotas** — one row per account and window: bar, percent, reset time ("↻ 21:30" today, "↻ Wed" later).
4. Footer: "Hooks not installed" hint with a copy button when no hook events were ever seen; sources status (which sources are found).

Finished sessions are hidden by default (toggle in settings). Empty state: "No agent sessions yet".

## Attention pill

- Small non-activating floating panel at the top center of the screen with the menu bar under the pointer (falls back to main screen).
- Appears when a session has been waiting longer than the threshold (default 60 s; settings: 30 s / 60 s / 2 min / 5 min / off). Shows the longest-waiting session: "● hutch waiting for approval · 2m".
- Click → jump to the session's terminal. Hover → stays. Otherwise auto-hides 8 s after appearing and reappears only when a *different* session crosses the threshold or the same one waits 5 more minutes.
- Never steals focus, never appears over full-screen apps (respects `NSWorkspace.activeSpace` full-screen state), hidden while screen sharing if the user enables "hide during screen sharing".
- Optional system notification instead of / in addition to the pill (setting).

## Jump to terminal (v0.1 best effort)

Order: iTerm2 (AppleScript by tty / session), Terminal.app (AppleScript by tty), Ghostty / others (activate app only). The tty comes from the process tree of the agent whose cwd matches; if unknown, activate the most recent terminal app. Requires the Automation permission only when first used; explained in a one-line prompt.

## Settings

Appearance (menu bar + pill | notch island — v0.2), pill threshold, notifications, show finished sessions, launch at login (`SMAppService`), sources on/off (Claude Code, Codex, ccr), quota warning levels. Stored in `UserDefaults` under the app's suite; nothing else is persisted.

## Accessibility and polish

VoiceOver labels on every row and button, Dynamic Type in the panel, reduced motion respected for pill animation, keyboard: ↑/↓ to select, Return to jump, Esc to close.
