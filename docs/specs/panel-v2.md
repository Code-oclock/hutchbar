# Panel v2

Decisions (2026-11-08, after the first live run): the menu bar item shows **two mini bars + a waiting counter**; the panel is **two-column cards** (~560 pt), Vorssaint-style; UI language follows the system (Russian and English). Replaces the panel/menu-bar parts of `ui-v0.1.md`; the architecture there stays.

Feedback that drove it: "Waiting for you" mixed two different situations without saying which; jump did nothing (the user runs Warp, which the bundle-id list missed); quota resets showed weekdays instead of time left; no spending view.

## 1. Menu bar item

> Superseded 2026-11-09 (`mockup/panel-v3.html`): the menu bar shows only the logo and the waiting count; quotas live in the panel.

- The monochrome hutch logo (a house, 16×16 pt, 1.6 pt stroke), template image.
- Someone waiting: the count to the right of the logo. Only "your turn": a plain number, still a template image. Any session needs approval: the number in an orange pill (then the image is not template). Above 99 it reads "99+".
- `hutchbar --render-icon <dir>` writes every state as 4× PNG on a light and a dark menu bar.
- Model: `StatusIconModel` in core (pure, tested); `StatusIconRenderer` draws it.

## 2. Agents block (full width, top)

Only shown when there are sessions. One row per session, sorted: needs approval → your turn → working (then by waiting time / last activity).

Row: agent mark (Claude: orange ✳-like glyph `asterisk`; Codex: blue `hexagon` — generic SF Symbols, no brand logos), project name, title (secondary), **reason badge**:
- `нужно разрешение` / `needs approval` (orange) — `waitingForApproval`;
- `твой ход` / `your turn` (blue) — `waitingForInput`;
- `работает` / `working` (secondary text, no badge) — `running`;
then waiting time ("4 мин" / "4 min"), and on the right the **host app name** with ↗ ("Warp ↗", "Cursor ↗"). The whole row is the jump target.

## 3. Jump to the agent (`AgentLocator` + `TerminalJumper`)

`SessionSnapshot` gains `cwd: String?` — the full working directory, kept **in memory only** for matching; it is never displayed, logged or written anywhere (privacy rule in `sources-v0.1.md` amended accordingly; `projectName` stays the only displayed path part).

`AgentLocator` (core, behind a `ProcessTable` protocol so tests use fakes):
1. List processes (`proc_listallpids` + `proc_pidinfo`/`proc_pidpath`; no shelling out). Agent processes: executable name `claude` for Claude Code, `codex` for Codex (any path).
2. For each agent process read its cwd (`proc_pidinfo(PROC_PIDVNODEPATHINFO)`), its controlling tty (`proc_pidinfo(PROC_PIDTBSDINFO).e_tdev` → `/dev/ttysNNN`), parent pid and start time.
3. Match a session by `cwd` equality (resolved, symlinks expanded). Several matches → the most recently started process.
4. Walk parents up to pid 1; the first ancestor that `NSRunningApplication(processIdentifier:)` resolves to an app with a bundle id is the **host app** (Warp, Cursor, iTerm2, Terminal, Ghostty, VS Code, …).
5. Result: `AgentLocation { pid, tty?, hostBundleId?, hostName? }`. Cached per session for 10 s.

`TerminalJumper.jump(session)`:
- iTerm2 / Terminal.app with a known tty: select the window/tab whose tty matches via `NSAppleScript` (needs `NSAppleEventsUsageDescription` in Info.plist and the `com.apple.security.automation.apple-events` entitlement); if scripting is denied, fall back to activation.
- Any other host app: `NSRunningApplication.activate()`.
- No location found: show a short inline message in the row ("процесс агента не найден").

## 4. Quota cards (two columns: Claude | Codex)

Core model `QuotaPresentation` (pure, tested), built from `store.quotas` and `now`:
- Group by provider (`AgentKind`). Within Claude, the **primary account** = the one with the most recent `observedAt` (that is the account in use); others are listed compactly below.
- Per window: `remainingPercent = 100 - used` (clamped 0…100), `resetsIn` countdown, `pace` = elapsed fraction of the window (`1 - (resetsAt - now) / windowLength`) for the "even pace" tick, `isStale` when `resetsAt < now` or `observedAt` older than the window length.
- Labels: window 300 min → «Сессия» / "Session", 10080 min → «Неделя» / "Week", other → "Nч".
- Countdown format: ≥ 1 day «2 д 7 ч» / "2d 7h"; ≥ 1 hour «4 ч 59 мин» / "4h 59m"; else «12 мин» / "12m"; stale → «нет свежих данных» / "no fresh data".
- Card: header (mark, provider, primary account name, plan badge if known — Codex `plan_type`), two big rows (label, ↻ countdown, «Осталось 80 %» right-aligned, bar of remaining with a thin tick at the pace position; bar orange < 20 %, red < 10 %), then compact secondary accounts: «pro-1 · неделя 0 % · ↻ пн 10:00».

## 5. Spending (`UsageLedger`)

Data (numbers only, no content):
- Claude transcripts, `type: assistant`: `message.id`, `message.model`, `message.usage.{input_tokens, output_tokens, cache_creation.ephemeral_5m_input_tokens, cache_creation.ephemeral_1h_input_tokens, cache_read_input_tokens}` (fallback: `cache_creation_input_tokens` counted as 5m), `timestamp`. **Deduplicate by `message.id`** — one API response is written as several records with the same id and usage. Skip `model == "<synthetic>"`.
- Codex sessions: `token_count.info.last_token_usage` per event if present, else the delta of `total_token_usage` between consecutive events of the same session (`input_tokens`, `cached_input_tokens`, `output_tokens`); model from the latest `turn_context.model`.
- Cost = Σ tokens × `ModelPrices` (`Sources/HutchbarCore/ModelPrices.swift`); unknown model → tokens counted, cost marked unknown (UI: "≈ $X + неизвестные модели").

Aggregation: per local calendar day × provider × model: tokens by kind, cost, cached share = cacheRead / (input + cacheRead + cacheWrite).

Scanning: a separate `UsageScanner` actor (not the 2 s session poller) scans transcripts modified in the last 35 days on start, then rescans changed files every 60 s. Per-file results are cached by `(path, size, mtime)` in `~/Library/Application Support/hutchbar/usage-cache.json` (0600; numbers and file paths only — paths are local and already known to the user, never sent anywhere). Budget: initial scan in the background with low priority; steady state < 0.2 % CPU.

Card «Расходы» / "Spending": period switch Сегодня / Неделя / Месяц (panel header), big "$6,54" with «по ценам API» / "at API prices" caption, split per provider (✳ $5,10 · ⬡ $1,44), «12M токенов · кэш 94 %». Card «Динамика» / "Trend": bars per day for the selected period (hours for «Сегодня»), drawn with SwiftUI shapes (no chart library), tooltips with the exact value.

## 6. Localization

A small `L10n` table in code (Russian and English, chosen from `Locale.preferredLanguages`), no resource bundles (the app is assembled by `build.sh` without SwiftPM resources). All user-visible strings go through it.
