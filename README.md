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
> macOS permissions (TCC: microphone, system capture) do not work.

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
| `AppCore` | Domain models, persistence (SwiftData/SQLite), end-to-end coordination |
| `Pepito` | SwiftUI app shell: menu bar, main window, admin |

The **Vault** (a Markdown folder chosen by the user) is the source of truth for content; the
database is reconstructible from it.

## Configuration (admin screen)

- **Generative AI** — endpoint URL + token (stored in **Keychain**), model, connection test.
- **Vault folder** — root of the document tree (security-scoped bookmark).
- **Agentic prompt** — the system prompt driving post-transcript processing, with interpolable
  variables (`{{transcript}}`, `{{date}}`, `{{participants}}`, `{{vault_tree}}`).

## Status

Phases 0 → 7 implemented (55 tests passing). Tested business logic: Vault, AI client (SSE +
chunking), agentic loop + `MeetingPipeline`, action hierarchy/tracking, settings/Keychain,
`MeetingStore`, `MeetingCoordinator` orchestration. Real capture + SpeechAnalyzer transcription are
**compile-verified** against the SDK 26 but still need hardware validation (TCC, live audio).

Detailed roadmap: **[PLAN.md](PLAN.md)**. Vision, stack, and conventions: **[CLAUDE.md](CLAUDE.md)**.
