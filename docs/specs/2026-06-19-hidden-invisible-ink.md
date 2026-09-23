# Spec — Hidden capture + invisible-ink veil (iOS)

Status: proposed · 2026-06-19 · branch `feat/capture-enhancements`

## Goal

Let a capture (note / log / schedule) be marked **hidden**: it is created normally
but (a) renders under an animated **invisible-ink veil** in the app until revealed,
and (b) is **excluded from AI-agent reads by default**. Hidden is a *privacy veil*
against shoulder-surfing (the iMessage model), **not** encryption — the row is stored
in plaintext with a `hidden` flag.

Two independent controls, by design:
- **Visual reveal** — a picker in the profile (Account) governs the veil *locally*.
- **Agent visibility** — the server hides hidden items from the agent; the in-app
  assistant has a per-chat opt-in that **resets OFF every new chat**.

## Data model

Add `hidden` (SQLite `INTEGER NOT NULL DEFAULT 0`) to **notes, activities,
assignments**. New migration `server/.../migrations/0006_hidden.sql` (auto-applied by
the existing runner). Surface as `hidden: Bool` on the iOS `Note`/`Activity`/
`Assignment`/`Occurrence` models and `*CreateBody` request bodies (snake_case is
automatic — plain `hidden` field, no CodingKeys).

"Reveal all" lifts the veil **on-screen only**; it never clears `hidden`, so revealed
items stay excluded from the agent.

## Server

The choke point is **core read functions** — both the in-app agent (`core/agent/tools.py`)
and external MCP call the same `search`/`list_`/`calendar`/`summary`:

- Add `include_hidden: bool = False` to `notes.search`, `activities.search`/`summary`,
  `assignments.list_`/`search`/`calendar`. Default appends `hidden = 0` to the WHERE.
  → **Both AI surfaces exclude hidden automatically.**
- Add `hidden` to core models + `create()` (accept + persist + return).
- **REST** (`rest/notes|activities|assignments.py`) passes `include_hidden=True` so the
  iOS app keeps seeing everything; `*Create` bodies accept `hidden`.
- **In-app agent opt-in:** add `allow_hidden: bool = False` to `ChatRequest`
  (`rest/agent.py`) → thread through `runner.run/stream` → `AgentDeps.allow_hidden` →
  the 3 tool call-sites pass `include_hidden=ctx.deps.allow_hidden`. Not stored on the
  thread (per-request), so it can't leak across turns.
- **External MCP:** expose `include_hidden: bool = False` on the read tools
  (`notes_search`, `activities_search`/`summary`, `assignments_search`/`calendar`).
  Defaults to excluded (least privilege), but the authenticated MCP agent can opt in
  per-call — it's the same user, another interface into core. Could
  later be gated by a settings key if desired.

## iOS — capture ("Add Hidden")

Long-press the capture-dock **send button** (`CalendarView.sendButton`) → `contextMenu`
with one item **"Add Hidden"** (`eye.slash`). It runs the same `send()` path with
`hidden = true`, threaded through `saveDraft` / `logDraft` / `addToQueue`. Normal tap =
visible. The saved toast reads "Hidden" with a lock/eye-slash glyph.

## iOS — the veil (invisible ink)

Net-new (the app has no shader/particle effects today). Per research (WWDC24 §10151):

- **`InvisibleInk.metal`** — a `[[stitchable]]` **`colorEffect`** fragment shader: animated
  twinkling sparkle field, tintable, with soft circular "holes" punched around touch
  points (a `device const float2*` passed via `Shader.Argument.data`).
- **`InvisibleInk.swift`** — a `.invisibleInk(hidden:reveal:tint:)` modifier:
  `TimelineView(.animation(paused:))` feeds elapsed time; the veil is an **overlay on a
  redacted copy** of the content (`.redacted`/blur) so legible text never sits in the
  veil's layer. Masked to the content shape. Tint `Palette.ink` (+ `Palette.accent`
  sparkle). Pauses when revealed / off-screen.
- Applied to the four text sites: `NoteRow`, `ActivityRow` (covers Log list **and**
  calendar agenda), `OccurrenceRow`.

**Reveal modes** (drive the veil), stored on `AppState.hiddenRevealMode`
(`UserDefaults`-persisted, mirroring `serverURLString`):
- `keepHidden` — veil always on, no reveal interaction.
- `swipeToReveal` — **rub/swipe to reveal**: dragging clears a soft circle under the
  finger (content shows through), veil re-covers on lift. Matches iMessage invisible ink.
- `revealAll` (red in the picker) — veil off everywhere (data still `hidden`).

## iOS — profile picker + assistant toggle

- **Account view:** new "Hidden items" `Section` (`Picker` over the 3 modes), after Voice.
- **Assistant (`AgentChatView`):** add `allowHidden` to `AgentStore`, **reset to `false`
  in `newChat()`** (and `openThread`/`reset`). A capsule toggle button (`eye` ON /
  `eye.slash` OFF, accent-tinted when ON) in `inputBar`'s top row next to the model
  picker. Threads `allowHidden` → `streamAgentChat` → `AgentChatBody.allow_hidden`.

## Accessibility

- **Reduce Motion** → render a static redaction (no animated shimmer), still reveal per mode.
- **VoiceOver** must respect reveal state: veiled content is `accessibilityHidden`/labeled
  "Hidden — swipe to reveal"; exposed only when revealed. (The veil is presentation, not
  security — text still lives in the view tree.)

## Out of scope (deliberate)

- Hiding people / goals (only note / log / schedule, per ask).
- Encryption / at-rest protection (it's a veil, like iMessage).
- Persisting per-item reveals (reveal is ephemeral; re-covers on lift / mode change /
  relaunch).

## Verification

- Server: pytest/`curl` — create hidden note; `/api/notes` returns it (hidden:true);
  agent `search_notes` excludes it with `allow_hidden=false`, includes with `true`;
  MCP `notes_search` never returns it.
- iOS sim: long-press send → Add Hidden → item shows veiled; swipe reveals under finger;
  Account picker modes; assistant toggle shows symbol + resets each new chat.
