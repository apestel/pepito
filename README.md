# Pépito

> A **native macOS** meeting assistant, powered by generative AI: records, transcribes,
> structures, and tracks action items — **local-first**.

Pépito starts from the menu bar (or a global shortcut), records the **microphone** and the
**system audio output** simultaneously (the other side of the call), transcribes **on-device** via
Apple SpeechAnalyzer, then runs an **agentic** pipeline that summarizes, extracts decisions, and
produces **hierarchical action plans** filed into a local Markdown Vault.

Raw audio never leaves the machine without an explicit action. The Cloud (planned) is an optional
extension, never a prerequisite.

## Requirements

- **macOS 26 (Tahoe)** minimum — required by SpeechAnalyzer / SpeechTranscriber.
- **Apple Silicon** — required by the on-device transcription models.
- **Xcode 26+**.
- An **OpenAI-compatible** AI endpoint (OpenAI, Azure, Ollama, vLLM, LM Studio, OpenRouter…) —
  or on-device Foundation Models for lightweight processing.

## Build & run

```bash
swift build              # build all modules + app
swift test               # unit tests (swift-testing) for all Kits
./build-app.sh           # assemble .build/Pepito.app (bundle required, see below)
open .build/Pepito.app   # launch the menu-bar app
```

> ⚠️ Launch the `.app` **bundle** (via `build-app.sh`), not the bare SPM binary
> (`.build/debug/Pepito`). Without an `Info.plist`, window management, activation, Settings, and
> macOS permissions (TCC: microphone, system capture, calendar, reminders) do not work.

To keep the *Screen Recording* permission (ScreenCaptureKit fallback) stable across builds, sign
with a fixed identity: `export PEPITO_SIGN_IDENTITY="Pepito Dev"` (see `build-app.sh`).

## Architecture

SwiftPM monorepo, one module (local Swift Package) per Kit. Dependency rule:
`AppUI`/`AdminUI` → `AppCore` → Kits. Kits depend neither on the UI nor on each other.

| Module | Role |
|--------|------|
| `CaptureKit` | Mic + system-output capture (Core Audio process taps, ScreenCaptureKit fallback), mixing, VU meter |
| `TranscriptionKit` | SpeechAnalyzer/SpeechTranscriber wrapper, segmentation |
| `AIKit` | OpenAI-compatible client, agentic loop, tool registry, prompts |
| `VaultKit` | Local document tree (Markdown + YAML front-matter), indexing |
| `ActionKit` | Action items: hierarchy, statuses, due dates, tracking |
| `MailKit` | Mail triage: Mail.app extraction (AppleScript + MIME decoding), compact digest, review rendering |
| `AppCore` | Domain models, persistence (SwiftData/SQLite), end-to-end coordination |
| `Pepito` | SwiftUI app shell: menu bar, main window, admin |

The **Vault** (a Markdown folder chosen by the user) is the source of truth for content; the
database is reconstructible from it.

## Configuration (admin screen)

- **Generative AI** — endpoint URL + token (stored in **Keychain**), model, connection test.
- **Vault folder** — root of the document tree (security-scoped bookmark).
- **Agentic prompt** — the system prompt driving post-transcript processing, with interpolable
  variables (`{{transcript}}`, `{{date}}`, `{{participants}}`, `{{vault_tree}}`, `{{context}}`,
  `{{user_notes}}`, `{{open_actions}}`).
- **Mail triage** — default period and message cap, plus the triage prompt (`{{date}}`, `{{days}}`,
  `{{open_actions}}`). Needs the Automation → Mail permission on first run.

## Status

Phases 0 → 7 implemented, plus the killer-feature set (60 tests passing). Tested business logic:
Vault, AI client (SSE + chunking), `MeetingPipeline`, action hierarchy/tracking + **SQLite
persistence**, settings/Keychain, `MeetingCoordinator` orchestration, prompt interpolation, and
cross-meeting **follow-up** (`action_updates`).

Recently added:

- **Calendar integration** — pre-fills title/participants and feeds the agenda to the AI as context.
- **User notes + AI enrichment** — the AI completes your notes instead of regenerating them.
- **Cross-meeting follow-up** — pre-brief of open items with the same participants; auto-resolution
  of past actions detected in a new transcript.
- **Action export** — open items to Apple Reminders (plus a Things URL-scheme builder).
- **Mail triage** — reads recent Mail.app messages and turns its Répondre/Décider/Suivre items into
  regular action items, side by side with meeting ones. Reviews are browsable in-app from the
  "Mails" sidebar section (history kept in SQLite): collapsible priority sections, one card per
  conversation, its action editable in place, and an envelope button opening the thread in Mail.
  A Markdown copy is still written to the Vault (`mails/revue-<date>.md`) for portability. Only a
  compact digest (metadata + 300-char preview per thread) ever reaches the AI endpoint. Read-only:
  Pépito never modifies or sends mail.

Real capture, SpeechAnalyzer transcription, and EventKit (calendar/reminders) are
**compile-verified** against the SDK 26 but still need hardware validation (TCC, live audio).
Vault **semantic search / RAG** is deferred until macOS 27 ships a native vector database.

Detailed roadmap: **[PLAN.md](PLAN.md)**. Changes: **[CHANGELOG.md](CHANGELOG.md)**. Vision, stack,
and conventions: **[CLAUDE.md](CLAUDE.md)**.
