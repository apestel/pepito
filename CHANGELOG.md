# Changelog

All notable changes to Pépito are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project is pre-1.0.

## [Unreleased]

### Added — killer features (calendar, notes, cross-meeting follow-up, export)

- **Action item persistence** — action plans and their statuses are now stored in SQLite and
  survive relaunch. Status is editable from a native menu on each action row (meeting detail +
  follow-up dashboard). Action ids are embedded as HTML comments in `action-plan.md` so the
  database stays reconstructible from the Vault.
- **Calendar integration (EventKit)** — on recording start, the current/imminent event pre-fills
  the meeting title and participants, and its agenda feeds the AI as `{{context}}`. New
  `CalendarProviding` seam (mockable). Participants are now persisted.
- **User notes + AI enrichment** — a notes editor in the live and naming windows; the AI
  *completes* your notes from the transcript instead of regenerating (default prompt updated).
  Exposed as `{{user_notes}}`.
- **Cross-meeting follow-up** — a pre-brief banner surfaces open action items from past meetings
  with the same participants; the AI can auto-resolve them via an `action_updates` block in its
  JSON response (matched by id), updating statuses automatically. Open items are passed as
  `{{open_actions}}`.
- **External export** — export open action items to Apple Reminders (EventKit), plus a pure
  Things URL-scheme builder. Summary/export lives in the follow-up dashboard.

### Added — native mail triage

- **`MailKit`** — new Kit: Mail.app extraction over AppleScript with an in-house MIME decoder
  (raw `source` instead of Mail's slow `content`, ~5× faster), thread grouping by normalised
  subject, compact digest (one entry per conversation) and deterministic Markdown rendering of the
  review. Ported from the `mail-triage` skill, self-tests included.
- **`MailPipeline`** — single-pass JSON triage mirroring `MeetingPipeline`: the digest goes to the
  AI, which returns bucket/importance/action/deadline per conversation; the app renders
  `mails/revue-<date>.md` into the Vault and creates the action items itself.
- **Unified backlog** — Répondre/Décider/Suivre items become regular `ActionItem`s (no
  `meetingID`), so they show up in the follow-up dashboard, the overdue list and the Reminders
  export alongside meeting actions. Action ids are derived from the thread's `Message-ID`
  (SHA-256), so re-running a triage updates instead of duplicating and preserves manual statuses.
- **UI** — a "Mails" section in the sidebar, one row per review (date, 🔴 and ⚑ counts), with the
  "Trier mes mails" trigger (today / last 7 days) in its header and live progress. The detail pane
  is native: collapsible 🔴/🟠/🟢 sections, one card per conversation (importance, deadline, why,
  summary), ⚪ grouped by sender, an envelope button opening the thread in Mail, and the action it
  produced editable right inside the card. Reviews are kept in SQLite (`mail_item`), so the
  history survives relaunch and re-triaging the same day replaces its row instead of stacking.
  An envelope button also appears on mail-born actions in the follow-up dashboard, and the admin
  screen gained a "Triage des mails" section (period, cap, prompt).

Read-only by design: Pépito never modifies, flags or sends mail. Only the digest (metadata +
300-character preview per conversation) reaches the AI endpoint — never full message bodies — and
mail content never lands in the logs.

### Fixed — 100 % CPU during long meetings

Net result, measured on a `release` build with the live transcript and the menu-bar popover both
open: **~100 % → 26 % CPU**, main thread 98 % → 21 % busy (78 % of its samples now parked in
`mach_msg2_trap`). No remaining hot spot above 1 %; what is left is AttributeGraph, `objc_msgSend`
and Metal — the inherent cost of a 30 Hz spectrogram plus a live-updating transcript.

- The live transcript view pinned the main thread at **100 % CPU** for the whole duration of a
  recording. `LiveTranscriptView` renders the entire live transcript as a single `Text`, which
  SwiftUI re-measures and CoreText fully re-typesets on every render pass — ~250 000 characters
  for a 3 h meeting. Profiling (`sample`) put ~80 % of the CPU in CoreText glyph encoding
  (`TASCIIEncoder::Encode`) and only 0.6 % in Pepito's own code.
  - The **displayed** live text is now capped to the last `MeetingCoordinator
    .liveDisplaySegmentCap` (200) turns per source. This also bounds `BleedFilter`, which was
    O(n·m) over the full history on every volatile speech hypothesis. The reference transcript is
    untouched: `liveTranscriptText` is display-only, `stopLive()` still returns every segment.
  - Auto-scroll no longer animates — `live` changes several times a second, so overlapping
    animated scrolls kept a 60 Hz render loop alive for the whole meeting.
  - That got it to 33 %, not to zero: re-profiling showed CoreText **shaping** (`OTL::GPOS`,
    kerning, variable-font axes) still burning ~80 % across three passes per frame — AppKit
    constraint update, SwiftUI layout, and draw — because `ScrollView { Text(…) }` has to measure
    the whole string to size its content. The transcript is now a `LazyVStack` of one `Text` per
    turn (`MeetingCoordinator.liveTranscriptLines`), so only visible lines are measured and drawn.
    Text selection becomes per-line instead of continuous — accepted.
- `symbolEffect(.variableColor)` on the recording indicator was profiled at **0.1 %**, not the
  suspected hot spot. Left alone.
- The spectrogram profiled at ~17 % while the menu-bar popover is open: 140 columns × 64 bands ×
  2 sources = 17 920 `ctx.fill` per frame at 30 Hz, each allocating a `Path`, a `CGRect` and a
  `Color`. `RecordingLevelsView` now composites both sources into one RGBA `CGImage` (one pixel
  per cell, premultiplied source-over, drawn with `.interpolation(.none)` to keep the cells
  crisp) and draws it in a single `ctx.draw`. This is the upgrade its `ponytail:` note named.
  New `PepitoTests` target covers the hand-rolled pixel math: row flip, threshold, source-over
  ordering, uneven column counts.

### Added — profiling

- **`./profile.py [seconds]`** — profiles the running app via `sample(1)`: prints instantaneous
  CPU, a per-thread active/total breakdown, self-time and Pepito-only inclusive tables, and writes
  a flamegraph SVG to `.build/`. No dependency, no Instruments. Reading guide in `CLAUDE.md` §10.

### Changed — UX pass

- Mail review: the whole section title toggles its `DisclosureGroup` (macOS only reacted to the
  chevron), and a conversation whose action is done/dropped leaves its urgency section — and its
  counter — for the ⚪ archive.
- The sidebar's 🔴 badge now counts what is *left* to handle: `mailReviews()` joins `action` and
  the counters are recomputed on every status change (`updateActionStatus` is the single funnel).
- Meeting summary is editable: double-click the body to switch to a Markdown editor, saved
  straight into `summary.md` (front-matter preserved, Vault stays the source of truth).
  `MarkdownText` lost `.textSelection` — it swallowed the double-click.

### Changed

- Default agentic prompt now leverages `{{context}}`, `{{user_notes}}` and `{{open_actions}}`.
- `MeetingPipeline.process` accepts `context` / `userNotes` / `openActions` and returns
  `actionUpdates`; `PipelineResult` gained an `actionUpdates` field.
- Info.plist: added `NSCalendarsFullAccessUsageDescription`,
  `NSRemindersFullAccessUsageDescription` and `NSAppleEventsUsageDescription` (Mail automation).
- Additive SQLite migrations (new `action` and `mail_item` tables; `participants` and `user_notes`
  columns on `meeting`; `source_url` column on `action`).
- `Settings` gained `mailPrompt` / `mailDays` / `mailLimit`; `ActionItem` gained `sourceURL`.

### Deferred

- **Vault semantic search / RAG** — deferred until macOS 27 ships a native vector database with
  Apple Intelligence, to avoid a throwaway home-grown embedding index.
- **Mail write-back** — AI-drafted replies, flagging, archiving and scheduled/automatic triage are
  out of scope for now (read-only integration).

### Notes

- 81 tests passing (`swift build` / `swift test`). Calendar, Reminders and Mail access is
  compile-verified only — it needs the `.app` bundle (`build-app.sh`) and a TCC grant on real
  hardware.
- Sandboxing caveat: sending Apple Events to Mail requires a temporary-exception entitlement that
  the Mac App Store rejects (fine for notarised Developer ID distribution). To be settled in
  Phase 8.
